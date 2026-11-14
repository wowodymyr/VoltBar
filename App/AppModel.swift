// VoltBar.app — model: polls the daemon, holds the draft settings, save/reset.

import Foundation
import ServiceManagement
import SwiftUI

final class AppModel: ObservableObject {
    @Published private(set) var status: Status? = nil
    @Published private(set) var connected = true
    @Published private(set) var connectionError: String? = nil
    @Published var draft = VBSettings()
    @Published private(set) var busy = false
    @Published private(set) var resultText: String? = nil
    @Published private(set) var resultIsError = false
    @Published private(set) var launchAtLogin = false

    // Menu bar item: what to show next to the ⚡ icon.
    @Published var menuBarShowTemp = UserDefaults.standard.bool(forKey: "menuBarShowTemp") {
        didSet { UserDefaults.standard.set(menuBarShowTemp, forKey: "menuBarShowTemp"); updatePolling() }
    }
    @Published var menuBarShowPower = UserDefaults.standard.bool(forKey: "menuBarShowPower") {
        didSet { UserDefaults.standard.set(menuBarShowPower, forKey: "menuBarShowPower"); updatePolling() }
    }

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
    var popoverVisible = false { didSet { updatePolling() } }
    var windowVisible = false { didSet { updatePolling() } }

    init() {
        updatePolling()
        refresh()
        // SMAppService.status is an XPC round-trip that can stall for seconds right after login —
        // never do it on the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let on = SMAppService.mainApp.status == .enabled
            DispatchQueue.main.async { self?.launchAtLogin = on }
        }
    }

    // MARK: Polling

    private func updatePolling() {
        let visible = popoverVisible || windowVisible
        let interval: TimeInterval = visible ? 1.0 : ((menuBarShowTemp || menuBarShowPower) ? 2.0 : 15.0)
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
                case .failure(let e):
                    if self.connected { self.connected = false }
                    let text = "\(e)"
                    if self.connectionError != text { self.connectionError = text }
                }
            }
        }
    }

    private func apply(status s: Status) {
        if s.cpuName != status?.cpuName {
            var name = s.cpuName
            for junk in ["(R)", "(TM)", "(tm)", " CPU"] { name = name.replacingOccurrences(of: junk, with: "") }
            cpuModel = name.split(separator: " ").joined(separator: " ")
        }
        // Publishing only real changes keeps SwiftUI from re-rendering for nothing.
        if s != status { status = s }
        if !draftLoaded && s.kextLoaded {
            draft = initialDraft(from: s)
            draftLoaded = true
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
                self.show("Saved and applied. If the system runs \(VB.confirmSeconds / 60) min without a crash, the profile will be applied at every boot.", error: false)
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

    // MARK: Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLogin = on
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var err: Error? = nil
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { err = error }
            let now = SMAppService.mainApp.status == .enabled
            DispatchQueue.main.async {
                self?.launchAtLogin = now
                if let e = err { self?.show("Launch at login: \(e.localizedDescription)", error: true) }
            }
        }
    }
}
