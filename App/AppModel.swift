// VoltBar.app — model: polls the daemon, holds the draft settings, save/reset.

import Foundation
import ServiceManagement
import SwiftUI

/// Values that change every poll (temperature, clocks, power, countdown). Kept apart from AppModel so that
/// a new reading re-renders only the few views that show it, not the whole menu with its sliders.
final class LiveMetrics: ObservableObject {
    @Published var tempC: Int? = nil
    @Published var freqGHz: Double? = nil
    @Published var packageW: Double? = nil
    @Published var pendingConfirmSeconds: Int? = nil
    @Published var fans: [FanInfo] = []
    @Published var sensors: [SensorInfo] = []

    func update(from s: Status) {
        let f = (s.fans ?? []).map { fan -> FanInfo in var x = fan; x.rpm = (x.rpm / 10).rounded() * 10; return x }
        if fans != f { fans = f }
        let sn = (s.sensors ?? []).map { x -> SensorInfo in var y = x; y.value = y.value.map { ($0 * 2).rounded() / 2 }; return y }
        if sensors != sn { sensors = sn }
        if tempC != s.tempC { tempC = s.tempC }
        if freqGHz != s.freqGHz { freqGHz = s.freqGHz }
        if packageW != s.packageW { packageW = s.packageW }
        if pendingConfirmSeconds != s.pendingConfirmSeconds { pendingConfirmSeconds = s.pendingConfirmSeconds }
    }
}

/// Which parts of VoltBar are in use. A module that's off disappears from the menu and Settings and
/// does nothing in the background (undervolting off = factory voltages, fans off = macOS control,
/// monitoring off = no sampling, no charts, menu bar shows only the icon).
struct FeatureFlags: Codable, Equatable {
    var undervolting = true
    var fans = true
    var monitoring = true
    var gpu = true          // graphics switching (dual-GPU Macs only)
    var autoProfiles = true // switch profiles on power adapter connect/disconnect

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        undervolting = try c.decodeIfPresent(Bool.self, forKey: .undervolting) ?? true
        fans = try c.decodeIfPresent(Bool.self, forKey: .fans) ?? true
        monitoring = try c.decodeIfPresent(Bool.self, forKey: .monitoring) ?? true
        gpu = try c.decodeIfPresent(Bool.self, forKey: .gpu) ?? true
        autoProfiles = try c.decodeIfPresent(Bool.self, forKey: .autoProfiles) ?? true
    }

    static let defaultsKey = "features"
    static func load() -> FeatureFlags {
        guard let d = UserDefaults.standard.data(forKey: defaultsKey),
              let f = try? JSONDecoder().decode(FeatureFlags.self, from: d) else { return FeatureFlags() }
        return f
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.defaultsKey) } }
}

/// Which sections the menu (popover) shows. Hiding one only hides it — the module keeps working.
struct MenuSections: Codable, Equatable {
    var metrics = true
    var profile = true
    var undervolting = true
    var fans = true
    var graphics = true
    var monitorButton = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metrics = try c.decodeIfPresent(Bool.self, forKey: .metrics) ?? true
        profile = try c.decodeIfPresent(Bool.self, forKey: .profile) ?? true
        undervolting = try c.decodeIfPresent(Bool.self, forKey: .undervolting) ?? true
        fans = try c.decodeIfPresent(Bool.self, forKey: .fans) ?? true
        graphics = try c.decodeIfPresent(Bool.self, forKey: .graphics) ?? true
        monitorButton = try c.decodeIfPresent(Bool.self, forKey: .monitorButton) ?? true
    }

    static let key = "menuSections"
    static func load() -> MenuSections {
        guard let d = UserDefaults.standard.data(forKey: key), let m = try? JSONDecoder().decode(MenuSections.self, from: d) else { return MenuSections() }
        return m
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) } }
}

final class AppModel: ObservableObject {
    /// The app's single model — also reached by Shortcuts actions and voltbar:// URLs.
    static private(set) weak var shared: AppModel?

    let live = LiveMetrics()
    let gpu = GPUSwitcher()
    let profiles = ProfileStore()
    let power = PowerSourceWatcher()

    @Published var features = FeatureFlags.load() {
        didSet {
            guard features != oldValue else { return }
            features.save()
            // Turning a module off also stops what it was doing.
            if oldValue.undervolting && !features.undervolting && (status?.enforcing ?? false) { setUndervolting(false) }
            if oldValue.fans && !features.fans && fanDraft.enabled { updateFans(immediate: true) { $0.enabled = false } }
            if oldValue.gpu != features.gpu { features.gpu ? gpu.start() : gpu.stop() }
            if oldValue.autoProfiles != features.autoProfiles {
                features.autoProfiles ? startAutoProfiles(atLaunch: false) : power.stop()
            }
            updatePolling()
        }
    }
    @Published private(set) var status: Status? = nil
    @Published private(set) var connected = true
    @Published private(set) var connectionError: String? = nil
    @Published var draft = VBSettings()
    @Published private(set) var busy = false
    @Published private(set) var resultText: String? = nil
    @Published private(set) var resultIsError = false
    @Published private(set) var launchAtLogin = false

    // Menu bar item: what to show next to the ⚡ icon.
    /// Chart colour of every metric (menu bar graphs and Monitor charts).
    @Published var chartColors = MetricColors.load() { didSet { if chartColors != oldValue { chartColors.save() } } }

    /// Mac has a discrete GPU (its metrics and charts are shown only then).
    static let hasDiscreteGPU = SystemStats.hasDiscreteGPU

    @Published var menuSections = MenuSections.load() { didSet { if menuSections != oldValue { menuSections.save() } } }

    @Published var menuBarConfig = MenuBarConfig.load() {
        didSet { menuBarConfig.save(); updatePolling() }
    }

    /// Monitor window: smooth scrolling and chart layout (persisted).
    @Published var monitorPrefs = MonitorPrefs.load() {
        didSet { if monitorPrefs != oldValue { monitorPrefs.save() } }
    }

    func updateChart(_ id: ChartID, _ change: (inout ChartLayoutItem) -> Void) {
        guard let i = monitorPrefs.items.firstIndex(where: { $0.id == id }) else { return }
        var p = monitorPrefs
        change(&p.items[i])
        if p != monitorPrefs { monitorPrefs = p }
    }

    /// History of every metric for the Monitor window and menu bar graphs.
    let history = MetricsHistory()
    private let stats = SystemStats()

    /// Mac model identifier, e.g. "MacBookPro11,3".
    let macModel: String = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }()

    /// "Intel(R) Core(TM) i7-4850HQ CPU @ 2.30GHz" -> "Intel Core i7-4850HQ @ 2.30GHz"
    private(set) var cpuModel: String = ""

    private var draftLoaded = false
    private var timer: Timer? = nil
    private var timerInterval: TimeInterval = 0
    private let q = DispatchQueue(label: "com.voltbar.app.client", qos: .userInitiated)
    private var inFlight = false

    /// Which UI surfaces are on screen; polling is fast only while something is visible.
    var popoverVisible = false { didSet { updatePolling(); gpu.setVisible(popoverVisible || windowVisible) } }
    var windowVisible = false { didSet { updatePolling(); gpu.setVisible(popoverVisible || windowVisible) } }
    var monitorVisible = false { didSet { updatePolling() } }
    /// Monitor window open and not covered/minimised: charts animate only then.
    @Published var monitorOnScreen = true

    /// Nothing of VoltBar's UI is on screen: values are not pushed into SwiftUI views then.
    private var uiHidden: Bool { !(popoverVisible || windowVisible || monitorVisible) }

    init() {
        AppModel.shared = self
        if features.gpu { gpu.start() }
        if features.autoProfiles { startAutoProfiles(atLaunch: true) }
        updatePolling()
        refresh()
        // SMAppService.status is an XPC round-trip that can stall for seconds right after login —
        // never do it on the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let on = LoginItem.isEnabled
            DispatchQueue.main.async { self?.launchAtLogin = on }
        }
    }

    // MARK: Polling

    private func updatePolling() {
        // History is recorded all the time so the Monitor has data the moment it opens.
        let visible = popoverVisible || windowVisible || (monitorVisible && features.monitoring)
        let interval: TimeInterval = visible ? 1.0
            : (features.monitoring ? (menuBarConfig.hasItems ? 2.0 : 5.0) : 15.0)
        if visible { refresh() }
        if interval == timerInterval, timer != nil { return }
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        timerInterval = interval
    }

    func refresh() {
        if inFlight { return }
        inFlight = true
        q.async { [weak self] in
            let result = Result { try sendRequest(Request(cmd: "status"), timeout: 3) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inFlight = false
                switch result {
                case .success(let r):
                    if !self.connected { self.connected = true }
                    if self.connectionError != nil { self.connectionError = nil }
                    if let s = r.status { self.apply(status: s) }
                    self.sample(r.status)
                case .failure(let e):
                    if self.connected { self.connected = false }
                    let text = "\(e)"
                    if self.connectionError != text { self.connectionError = text }
                    self.sample(nil)
                }
            }
        }
    }

    /// Records one point of every metric: CPU/RAM/swap from the kernel, the rest from the daemon.
    private func sample(_ s: Status?) {
        guard features.monitoring else { return }
        var v: [Metric: Double] = [:]
        if let x = stats.cpuLoad() { v[.cpuLoad] = x }
        if let m = stats.memory() { v[.memory] = m.percent; memory = m }
        if let w = stats.swap() {
            v[.swap] = w.usedGB
            history.setRange(.swap, 0...max(1, w.totalGB))
            swap = w
        }
        if let t = s?.tempC { v[.cpuTemp] = Double(t) }
        let gpu = stats.gpuUtilization()
        if let g = gpu.integrated { v[.gpuLoadI] = g }
        if let g = gpu.discrete { v[.gpuLoadD] = g }
        for sensor in s?.sensors ?? [] {
            if sensor.key == "TCGC", let t = sensor.value { v[.gpuTempI] = t }
            if sensor.key == "TG0D", let t = sensor.value, Self.hasDiscreteGPU { v[.gpuTempD] = t }
        }
        if let p = s?.packageW { v[.cpuPower] = p }
        if let f = s?.freqGHz { v[.cpuFreq] = f }
        for f in s?.fans ?? [] {
            guard let m = Metric.fan(f.index) else { continue }
            v[m] = f.rpm
            history.setRange(m, f.minRPM * 0.9...f.maxRPM)
        }
        history.append(v, threadLoad: stats.perThreadLoad())
    }

    /// Latest memory / swap totals (for labels like "8.8 of 16 GB").
    private(set) var memory: MemoryUsage? = nil
    private(set) var swap: SwapUsage? = nil

    #if VOLTBAR_TESTING
    func injectForTesting(_ s: Status) { apply(status: s) }
    #endif

    private func apply(status s: Status) {
        // With no UI on screen, publishing every poll would only make hidden SwiftUI views re-render.
        // Keep just what the menu bar item needs; everything is refreshed when a window or the menu opens.
        let initialised = status != nil && (draftLoaded || !s.kextLoaded) && (fanDraftLoaded || (s.fans ?? []).isEmpty)
        if uiHidden && initialised {
            if status?.enforcing != s.enforcing { status?.enforcing = s.enforcing }
            return
        }
        if s.cpuName != status?.cpuName {
            var name = s.cpuName
            for junk in ["(R)", "(TM)", "(tm)", " CPU"] { name = name.replacingOccurrences(of: junk, with: "") }
            cpuModel = name.split(separator: " ").joined(separator: " ")
        }
        live.update(from: s)
        // The rest changes rarely; publish it only on real changes so the menu isn't re-rendered every second.
        var stable = s
        stable.tempC = nil; stable.freqGHz = nil; stable.packageW = nil; stable.pendingConfirmSeconds = nil
        stable.fans = nil; stable.sensors = nil
        stable.offsets = s.offsets.map { $0.map { ($0 * 10).rounded() / 10 } }
        if stable != status { status = stable }
        if !draftLoaded && s.kextLoaded {
            draft = initialDraft(from: s)
            draftLoaded = true
        }
        if !fanDraftLoaded, let fans = s.fans, !fans.isEmpty {
            fanDraft = Self.normalized(s.fanConfig ?? FanConfig(), fans: fans)
            fanDraftLoaded = true
        }
    }

    private func initialDraft(from s: Status) -> VBSettings {
        if let p = s.active ?? s.saved { return p }
        var d = VBSettings()
        d.offsets = s.offsets.map { Int(($0 ?? 0).rounded()) }
        if d.offsets.contains(where: { !VB.normalRange.contains($0) }) { d.damageMode = true }
        d.turbo = s.turboEnabled ?? true
        d.pl1 = (s.factoryPL1 ?? s.pl1 ?? 47).rounded()
        d.pl2 = (s.factoryPL2 ?? s.pl2 ?? 58).rounded()
        return d
    }

    // MARK: Draft state

    var offsetRange: ClosedRange<Int> { draft.damageMode ? VB.damageRange : VB.normalRange }

    var isDirty: Bool {
        guard let s = status else { return false }
        if let saved = s.saved, s.enforcing, s.active == saved { return draft != saved }
        let isDefault = draft.offsets.allSatisfy { $0 == 0 } && !draft.manageTurbo && !draft.managePower
        return !isDefault || s.active != nil
    }

    var factoryPL1: Double { status?.factoryPL1 ?? 47 }
    var factoryPL2: Double { status?.factoryPL2 ?? 58.75 }

    func setOffset(_ index: Int, _ v: Int) {
        let r = offsetRange
        let clamped = min(r.upperBound, max(r.lowerBound, v))
        if draft.offsets[index] != clamped { draft.offsets[index] = clamped }
    }

    func setDamageMode(_ on: Bool) {
        draft.damageMode = on
        if !on {
            draft.offsets = draft.offsets.map { min(VB.normalRange.upperBound, max(VB.normalRange.lowerBound, $0)) }
        }
    }

    func revertDraft() {
        if let s = status { draft = initialDraft(from: s) }
        resultText = nil
    }

    // MARK: Actions

    func save() {
        if let e = draft.validate() { show(e, error: true); return }
        send(Request(cmd: "save", settings: draft)) { [weak self] r in
            guard let self = self else { return }
            if r.ok {
                if (r.status?.pendingConfirmSeconds ?? 0) > 0 {
                    self.show("Saved and applied. If the system runs \(VB.confirmSeconds / 60) min without a crash, the profile will be applied at every boot.", error: false)
                } else {
                    self.show("Saved and applied. These offsets already passed the stability check.", error: false)
                }
            }
        }
    }

    func reset() {
        send(Request(cmd: "reset")) { [weak self] r in
            guard let self = self else { return }
            var d = VBSettings()
            d.pl1 = (r.status?.factoryPL1 ?? self.factoryPL1).rounded()
            d.pl2 = (r.status?.factoryPL2 ?? self.factoryPL2).rounded()
            d.turbo = r.status?.turboEnabled ?? true
            self.draft = d
            if r.ok { self.show("Reset to factory values. Profile disabled.", error: false) }
        }
    }

    private func send(_ req: Request, completion: @escaping (Response) -> Void) {
        busy = true
        resultText = nil
        q.async { [weak self] in
            let result = Result { try sendRequest(req, timeout: 15) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                switch result {
                case .success(let r):
                    if let s = r.status { self.apply(status: s) }
                    if !r.ok {
                        var text = r.error ?? "Error"
                        if let d = r.details, !d.isEmpty { text += ":\n• " + d.joined(separator: "\n• ") }
                        self.show(text, error: true)
                    }
                    completion(r)
                case .failure(let e):
                    self.show("\(e)", error: true)
                }
            }
        }
    }

    private func show(_ text: String, error: Bool) {
        resultText = text
        resultIsError = error
    }

    // MARK: Undervolting on/off

    /// Switches the saved undervolting profile on or off; the profile itself is kept.
    func setUndervolting(_ on: Bool) {
        send(Request(cmd: "undervolt", enabled: on)) { [weak self] r in
            guard let self = self, r.ok else { return }
            let checking = (r.status?.pendingConfirmSeconds ?? 0) > 0
            self.show(!on ? "Undervolting off — factory voltages. Your profile is kept."
                      : checking ? "Undervolting on. If the system runs \(VB.confirmSeconds / 60) min without a crash, the profile will be applied at every boot."
                      : "Undervolting on (offsets already passed the stability check).", error: false)
        }
    }

    // MARK: Fans

    @Published var fanDraft = FanConfig()
    @Published private(set) var fanError: String? = nil
    private var fanDraftLoaded = false
    private var fanSendWork: DispatchWorkItem? = nil

    /// One setting per fan, with sensible defaults (middle speed, default curve) for fans never configured.
    static func normalized(_ c: FanConfig, fans: [FanInfo]) -> FanConfig {
        var c = c
        for f in fans {
            if f.index >= c.fans.count {
                var s = FanSetting()
                s.fixedRPM = ((f.minRPM + f.maxRPM) / 2 / 100).rounded() * 100
                c.fans.append(s)
            }
            if c.fans[f.index].curve.isEmpty {
                c.fans[f.index].curve = FanSetting.defaultCurve(min: f.minRPM, max: f.maxRPM)
            }
        }
        return c
    }

    func fanSetting(_ i: Int) -> FanSetting { i < fanDraft.fans.count ? fanDraft.fans[i] : FanSetting() }

    /// Changes fan settings; they're applied right away (debounced while a control is being dragged).
    func updateFans(immediate: Bool = false, _ change: (inout FanConfig) -> Void) {
        var c = fanDraft
        change(&c)
        guard c != fanDraft else { return }
        fanDraft = c
        fanSendWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendFans() }
        fanSendWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.35), execute: work)
    }

    func updateFan(_ i: Int, immediate: Bool = false, _ change: @escaping (inout FanSetting) -> Void) {
        updateFans(immediate: immediate) { c in
            while c.fans.count <= i { c.fans.append(FanSetting()) }
            change(&c.fans[i])
        }
    }

    private func sendFans() {
        let cfg = fanDraft
        q.async { [weak self] in
            let result = Result { try sendRequest(Request(cmd: "fans", fanConfig: cfg), timeout: 10) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let r):
                    if let s = r.status { self.apply(status: s) }
                    self.fanError = r.ok ? nil : (r.error ?? "Error")
                case .failure(let e):
                    self.fanError = "\(e)"
                }
            }
        }
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLogin = on
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var err: Error? = nil
            do { try LoginItem.set(on) } catch { err = error }
            let now = LoginItem.isEnabled
            DispatchQueue.main.async {
                self?.launchAtLogin = now
                if let e = err { self?.show("Launch at login: \(e.localizedDescription)", error: true) }
            }
        }
    }
}

/// Launch at login: SMAppService on macOS 13+, a per-user LaunchAgent on macOS 12.
enum LoginItem {
    static let agentLabel = "com.voltbar.app"
    static var agentPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist" }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return FileManager.default.fileExists(atPath: agentPath)
    }

    static func set(_ on: Bool) throws {
        if #available(macOS 13.0, *) {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return
        }
        if on {
            let exe = Bundle.main.executablePath ?? "/Applications/VoltBar.app/Contents/MacOS/VoltBar"
            let plist: [String: Any] = [
                "Label": agentLabel,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
                "ProcessType": "Interactive",
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(atPath: (agentPath as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: agentPath), options: .atomic)
        } else if FileManager.default.fileExists(atPath: agentPath) {
            try FileManager.default.removeItem(atPath: agentPath)
        }
    }
}
