// VoltBar.app — graphics switching on dual-GPU MacBook Pros (integrated only / dynamic / discrete only),
// the functionality of gSwitch (MIT, Cody Schrank), itself based on gfxCardStatus (Cody Krieger).
//
// Talks to the AppleGraphicsControl user client (the GPU multiplexer). This runs in the app, not the
// root daemon: keeping "integrated only" requires reacting to display reconfiguration events, which
// only exist inside a user's window-server session.

import AppKit
import Combine
import IOKit
import UserNotifications

enum GPUMode: String, Codable, CaseIterable {
    case integrated, dynamic, discrete

    var title: String {
        switch self {
        case .integrated: return "Integrated"
        case .dynamic: return "Dynamic"
        case .discrete: return "Discrete"
        }
    }
}

struct GPUSettings: Codable, Equatable {
    var mode: GPUMode = .dynamic
    var notifyOnChange = false
    var menuBarDot = true

    static let key = "gpuSettings"
    static func load() -> GPUSettings {
        guard let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(GPUSettings.self, from: d) else { return GPUSettings() }
        return s
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) } }
}

struct GPUProcess: Identifiable, Equatable {
    let pid: Int32
    let name: String
    var id: String { "\(pid)-\(name)" }
}

final class GPUSwitcher: ObservableObject {
    /// Dual-GPU Mac with a working multiplexer.
    @Published private(set) var available = false
    @Published private(set) var integratedName = "Integrated GPU"
    @Published private(set) var discreteName = "Discrete GPU"
    @Published private(set) var usingIntegrated = true
    /// Processes that use (or, in integrated-only mode, ask for) the discrete GPU.
    @Published private(set) var dependents: [GPUProcess] = []
    @Published private(set) var externalDisplay = false
    @Published private(set) var message: String? = nil
    @Published var settings = GPUSettings.load() { didSet { if settings != oldValue { settings.save() } } }

    var activeName: String { usingIntegrated ? integratedName : discreteName }

    private var connect: io_connect_t = 0
    private let q = DispatchQueue(label: "com.voltbar.gpu")
    private var enabled = false
    private var refreshTimer: Timer? = nil

    // AppleGraphicsControl selectors and mux states (from gfxCardStatus / gSwitch).
    private enum Sel: UInt32 { case open = 0, close = 1, setMuxState = 2, getMuxState = 3 }
    private enum Mux: UInt64 {
        case disableFeature = 0, enableFeature = 1, forceSwitch = 2, gpuSelect = 4, switchPolicy = 5, graphicsCard = 7
    }
    private static let featurePolicy: UInt64 = 1 << 0

    init() {
        detectGPUs()
        guard available else { return }
        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            guard let ctx = ctx else { return }
            let me = Unmanaged<GPUSwitcher>.fromOpaque(ctx).takeUnretainedValue()
            me.displayChanged(flags)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: Lifecycle (the GPU module can be switched off in General)

    func start() {
        guard available, !enabled else { return }
        enabled = true
        openMux()
        refresh()
        if settings.mode != .dynamic { apply(settings.mode, confirmed: true) }
    }

    func stop() {
        guard enabled else { return }
        if settings.mode != .dynamic { q.async { self.setDynamic() } }
        enabled = false
        setVisible(false)
        q.async { self.closeMux() }
    }

    /// Faster refresh of the process list while a GPU view is on screen.
    func setVisible(_ visible: Bool) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard enabled, visible else { return }
        refresh()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    // MARK: Mode

    /// Returns the apps that would lose the discrete GPU, if switching to integrated needs a confirmation.
    func appsAtRisk(for mode: GPUMode) -> [GPUProcess] {
        guard mode == .integrated, !usingIntegrated else { return [] }
        return dependents.filter { $0.pid > 0 }
    }

    func apply(_ mode: GPUMode, confirmed: Bool = false) {
        guard available, enabled else { return }
        if mode == .integrated && externalDisplay {
            message = "An external display needs the discrete GPU — integrated only isn't possible while it's connected."
            return
        }
        settings.mode = mode
        message = nil
        q.async {
            switch mode {
            case .integrated: self.forceIntegrated()
            case .discrete: self.forceDiscrete()
            case .dynamic: self.setDynamic()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
        }
    }

    private func forceIntegrated() {
        guard !queryIntegrated() else { return }
        _ = setMux(.gpuSelect, 0)          // dynamic switching off
        sleep(1)
        _ = setMux(.forceSwitch, 0)        // switch to the other (integrated) GPU
    }

    private func forceDiscrete() {
        // Same as ticking and unticking "Automatic graphics switching": that leaves the discrete GPU on.
        _ = setMux(.enableFeature, Self.featurePolicy)
        _ = setMux(.switchPolicy, 0)
        _ = setMux(.gpuSelect, 1)
        sleep(1)
        _ = setMux(.gpuSelect, 0)
    }

    private func setDynamic() {
        _ = setMux(.enableFeature, Self.featurePolicy)
        _ = setMux(.switchPolicy, 0)
        _ = setMux(.gpuSelect, 1)
    }

    // MARK: State

    func refresh() {
        guard available, enabled else { return }
        q.async {
            let integrated = self.queryIntegrated()
            let procs = self.gpuProcesses()
            let external = Self.hasExternalDisplay()
            DispatchQueue.main.async {
                let changed = integrated != self.usingIntegrated
                if changed { self.usingIntegrated = integrated }
                if procs != self.dependents { self.dependents = procs }
                if external != self.externalDisplay { self.externalDisplay = external }
                if changed { self.notifyChange() }
            }
        }
    }

    private func displayChanged(_ flags: CGDisplayChangeSummaryFlags) {
        guard enabled else { return }
        DispatchQueue.main.async { self.refresh() }
        // An app woke the discrete GPU up: in integrated-only mode, switch back once it settles.
        guard flags.contains(.setModeFlag) || flags.contains(.addFlag) else { return }
        q.asyncAfter(deadline: .now() + 1) {
            guard self.settings.mode == .integrated, !self.queryIntegrated() else { return }
            if Self.hasExternalDisplay() {
                DispatchQueue.main.async {
                    self.settings.mode = .dynamic
                    self.message = "External display connected — switched to dynamic graphics."
                    self.post("Switched to dynamic graphics", "An external display needs the discrete GPU.")
                }
                self.setDynamic()
            } else {
                self.forceIntegrated()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
        }
    }

    private func notifyChange() {
        guard settings.notifyOnChange else { return }
        post("Graphics switched", "Now using \(activeName).")
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func post(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: Hardware access

    private func detectGPUs() {
        var names: [String] = []
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPCIDevice"), &it) == KERN_SUCCESS else { return }
        var s = IOIteratorNext(it)
        while s != 0 {
            if let n = IORegistryEntryCreateCFProperty(s, "IOName" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               n == "display",
               let m = IORegistryEntryCreateCFProperty(s, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
                names.append(String(decoding: m.filter { $0 != 0 }, as: UTF8.self))
            }
            IOObjectRelease(s)
            s = IOIteratorNext(it)
        }
        IOObjectRelease(it)
        guard names.count >= 2 else { return }
        integratedName = names.first { $0.hasPrefix("Intel") } ?? names[0]
        discreteName = names.first { !$0.hasPrefix("Intel") } ?? names[1]
        let agc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleGraphicsControl"))
        available = agc != 0
        if agc != 0 { IOObjectRelease(agc) }
    }

    private func openMux() {
        q.sync {
            guard connect == 0 else { return }
            let agc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleGraphicsControl"))
            guard agc != 0 else { return }
            defer { IOObjectRelease(agc) }
            var c: io_connect_t = 0
            guard IOServiceOpen(agc, mach_task_self_, 0, &c) == KERN_SUCCESS else { return }
            if IOConnectCallScalarMethod(c, Sel.open.rawValue, nil, 0, nil, nil) == KERN_SUCCESS {
                connect = c
            } else {
                IOServiceClose(c)
            }
        }
    }

    private func closeMux() {
        guard connect != 0 else { return }
        _ = IOConnectCallScalarMethod(connect, Sel.close.rawValue, nil, 0, nil, nil)
        IOServiceClose(connect)
        connect = 0
    }

    @discardableResult
    private func setMux(_ state: Mux, _ arg: UInt64) -> Bool {
        guard connect != 0 else { return false }
        var input: [UInt64] = [1, state.rawValue, arg]
        return IOConnectCallScalarMethod(connect, Sel.setMuxState.rawValue, &input, 3, nil, nil) == KERN_SUCCESS
    }

    private func getMux(_ state: Mux) -> UInt64? {
        guard connect != 0 else { return nil }
        var input: [UInt64] = [1, state.rawValue]
        var out: UInt64 = 0
        var n: UInt32 = 1
        return IOConnectCallScalarMethod(connect, Sel.getMuxState.rawValue, &input, 2, &out, &n) == KERN_SUCCESS ? out : nil
    }

    /// GraphicsCard state: 0 = discrete, 1 = integrated.
    private func queryIntegrated() -> Bool { (getMux(.graphicsCard) ?? 1) != 0 }

    /// Processes registered with the multiplexer as needing the discrete GPU, plus external displays.
    private func gpuProcesses() -> [GPUProcess] {
        var out: [GPUProcess] = []
        let agc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleGraphicsControl"))
        if agc != 0 {
            if let list = IORegistryEntryCreateCFProperty(agc, "task-list" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [NSNumber] {
                for pid in Set(list.map { $0.int32Value }) {
                    let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? Self.processName(pid)
                    if let name = name { out.append(GPUProcess(pid: pid, name: name)) }
                }
            }
            IOObjectRelease(agc)
        }
        if Self.hasExternalDisplay() { out.append(GPUProcess(pid: 0, name: "External display")) }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func processName(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 1024)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    private static func hasExternalDisplay() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(8, &ids, &n) == .success else { return false }
        return ids.prefix(Int(n)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}
