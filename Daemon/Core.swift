// VoltBar daemon — ядро (Core) — работает от root через launchd.
//
// • применяет сохранённый профиль при загрузке, после сна/гибернации и следит,
//   чтобы значения не слетали (проверка каждые 30 с);
// • защита от «кирпича»: если после «Сохранить» система упала/перезагрузилась
//   раньше, чем через 10 минут, профиль при следующей загрузке НЕ применяется;
//   то же самое после 4 быстрых перезапусков подряд;
// • принимает команды от приложения/CLI через Unix-сокет (доступ: root и группа admin).

import Foundation
import IOKit
import IOKit.pwr_mgt

let daemonVersion = "2.0"

// MARK: - Хранилище

struct Config: Codable {
    var settings: VBSettings? = nil
    var enabled: Bool = false
    var fans: FanConfig? = nil
}

struct DaemonState: Codable {
    var lastStartBoot: Int = 0          // kern.boottime последнего запуска демона
    var factoryBoot: Int = 0            // в какую загрузку сняты заводские значения
    var factoryPL: UInt64? = nil        // MSR 0x610 до любых изменений
    var factoryTurbo: Bool? = nil
    var quickStarts: Int = 0
    var pendingUntil: Double? = nil     // время (epoch), до которого профиль не подтверждён
    var pendingBoot: Int? = nil
    var message: String? = nil
    var profileSavedAt: Double? = nil   // epoch of the last "save"
    var handledPanicAt: Double? = nil   // newest kernel panic report already acted upon
    // Left over from a 1.4 pre-release that could change these registers; restored once, then cleared.
    var factoryTurboRatios: [Int]? = nil
    var factoryTjOffset: Int? = nil
    var factoryBDProchot: Bool? = nil
    var cleanExit: Bool? = nil          // false while running; true after SIGTERM (normal shutdown/restart)
}

/// Newest kernel panic report written by macOS (mtime, epoch), if any.
func newestPanicReport() -> (date: Double, path: String)? {
    let dirs = ["/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports/Retired"]
    var best: (Double, String)? = nil
    for dir in dirs {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
        for n in names where n.hasPrefix("Kernel") && (n.hasSuffix(".panic") || n.hasSuffix(".ips")) {
            let path = dir + "/" + n
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let d = attrs[.modificationDate] as? Date else { continue }
            let t = d.timeIntervalSince1970
            if best == nil || t > best!.0 { best = (t, path) }
        }
    }
    return best.map { (date: $0.0, path: $0.1) }
}

/// Short description of the panic for the user ("Machine Check", "watchdog timeout", …).
func panicSummary(_ path: String) -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "kernel panic" }
    if text.contains("Machine Check") { return "kernel panic (Machine Check — typical for too deep undervolt)" }
    if text.contains("watchdog") { return "kernel panic (watchdog timeout — system hang)" }
    return "kernel panic"
}

func loadJSON<T: Decodable>(_ type: T.Type, _ path: String) -> T? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(type, from: d)
}

func saveJSON<T: Encodable>(_ value: T, _ path: String) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let d = try? enc.encode(value) else { return }
    do {
        try d.write(to: URL(fileURLWithPath: path), options: .atomic)
        chmod(path, 0o644)
    } catch {
        vlog("Failed to write \(path): \(error)")
    }
}

func sysctlString(_ name: String) -> String {
    var size = 0
    if sysctlbyname(name, nil, &size, nil, 0) != 0 || size == 0 { return "" }
    var buf = [CChar](repeating: 0, count: size)
    if sysctlbyname(name, &buf, &size, nil, 0) != 0 { return "" }
    return String(cString: buf)
}

/// kern.boottime is derived from the wall clock and can drift by a second between reads,
/// so "same boot" means "boot times within a few seconds". Real reboots differ by far more.
func sameBoot(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= 5 }

func bootTime() -> Int {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    if sysctlbyname("kern.boottime", &tv, &size, nil, 0) != 0 { return 0 }
    return Int(tv.tv_sec)
}

// MARK: - Ядро

final class Core {
    let q = DispatchQueue(label: "com.voltbar.hw")
    let hw = Hardware()
    lazy var fans = FanController(packageTemp: { [unowned self] in
        (self.kextReady || self.hw.dev.isOpen) ? (try? self.hw.temperature()).map(Double.init) : nil
    })
    var config: Config
    var state: DaemonState
    let currentBoot = bootTime()
    let cpuName = sysctlString("machdep.cpu.brand_string")

    /// Временные настройки (CLI `apply`), действуют до перезагрузки/сохранения/сброса.
    var override: VBSettings? = nil
    var kextReady = false
    var lastKextLoadAttempt: TimeInterval = -1000
    var confirmGeneration = 0
    var timers: [DispatchSourceTimer] = []

    init() {
        try? FileManager.default.createDirectory(atPath: VB.supportDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o755])
        config = loadJSON(Config.self, VB.configPath) ?? Config()
        state = loadJSON(DaemonState.self, VB.statePath) ?? DaemonState()

        let newBoot = !sameBoot(state.lastStartBoot, currentBoot)
        vlog("VoltBar daemon \(daemonVersion) start. CPU: \(cpuName). newBoot=\(newBoot)")

        // 1) Неподтверждённый профиль + была перезагрузка => откат.
        if let pb = state.pendingBoot, state.pendingUntil != nil, !sameBoot(pb, currentBoot) {
            if config.enabled {
                config.enabled = false
                state.message = "Profile disabled: the system restarted less than \(VB.confirmSeconds / 60) min after saving (possible instability). Check the values and save again."
                vlog(state.message!)
            }
            state.pendingUntil = nil
            state.pendingBoot = nil
        }

        // 2) Много быстрых перезапусков подряд => безопасный режим.
        state.quickStarts += 1
        if state.quickStarts >= 4 && config.enabled {
            config.enabled = false
            state.message = "Profile disabled: \(state.quickStarts) quick restarts in a row. Check the values and save again."
            vlog(state.message!)
        }
        // 3) Previous boot ended without a normal shutdown (hard hang, forced power-off): a hang at
        //    idle leaves no panic report, so this is the only trace of an unstable undervolt.
        if newBoot, state.cleanExit == false, config.enabled,
           let s = config.settings, s.offsets.contains(where: { $0 != 0 }) {
            config.enabled = false
            state.pendingUntil = nil
            state.pendingBoot = nil
            state.message = "Profile disabled: the previous session ended without a normal shutdown (system hang or forced power-off). Use smaller offsets and save again."
            vlog(state.message!)
        }
        state.cleanExit = false
        state.lastStartBoot = currentBoot
        checkForPanic()
        persist()
    }

    /// If a kernel panic happened after the profile was saved, the profile is not trusted any more:
    /// disable it (and reset the hardware if the driver is up). Works even after the 10-minute
    /// confirmation, because undervolt crashes often happen later, e.g. at idle.
    @discardableResult
    func checkForPanic() -> Bool {
        guard let p = newestPanicReport() else { return false }
        if let h = state.handledPanicAt, p.date <= h { return false }
        state.handledPanicAt = p.date
        guard config.enabled || override != nil else { persist(); return false }
        if let saved = state.profileSavedAt, p.date < saved { persist(); return false }
        let what = panicSummary(p.path)
        override = nil
        config.enabled = false
        state.pendingUntil = nil
        state.pendingBoot = nil
        state.message = "Profile disabled: a \(what) happened after it was saved. Use smaller offsets and save again."
        vlog(state.message! + " [\(p.path)]")
        if kextReady { _ = resetHardware() }
        persist()
        return true
    }

    /// Called on SIGTERM (normal shutdown, restart, reinstall).
    func markCleanExit() {
        fans.releaseAll()
        state.cleanExit = true
        persist()
    }

    func persist() {
        saveJSON(config, VB.configPath)
        saveJSON(state, VB.statePath)
    }

    var activeSettings: VBSettings? {
        if let o = override { return o }
        return config.enabled ? config.settings : nil
    }

    func start() {
        // Сброс счётчика быстрых перезапусков после 3 минут стабильной работы.
        q.asyncAfter(deadline: .now() + 180) { [self] in
            state.quickStarts = 0
            persist()
        }
        // Если профиль был сохранён в эту же загрузку и ещё не подтверждён — дождёмся.
        if let until = state.pendingUntil, let pb = state.pendingBoot, sameBoot(pb, currentBoot) {
            scheduleConfirm(after: max(1, until - Date().timeIntervalSince1970))
        }

        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 5)
        t.setEventHandler { [self] in tick() }
        t.resume()
        timers.append(t)

        // Fans: own 1-second loop, independent of the undervolting profile and of the MSR driver.
        fans.setup()
        fans.config = config.fans ?? FanConfig()
        let ft = DispatchSource.makeTimerSource(queue: q)
        ft.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        ft.setEventHandler { [self] in fans.tick() }
        ft.resume()
        timers.append(ft)
    }

    private var lastEnforce: TimeInterval = 0

    /// Каждые 5 с: ждём kext; каждые 30 с — проверка и восстановление значений.
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now < 15 * 60 { checkForPanic() }
        if !kextReady {
            if hw.dev.open() {
                kextReady = true
                vlog("MSR driver ready: \(hw.dev.driver?.rawValue ?? "?")")
                onKextReady()
            } else if now - lastKextLoadAttempt > 60 {
                lastKextLoadAttempt = now
                tryLoadKext()
            }
            return
        }
        if now - lastEnforce >= 30 {
            lastEnforce = now
            enforce(reason: "periodic check")
        }
    }

    private var loadAttempt = 0

    /// Loads a driver kext. Our own VoltBarMSR first; VoltageShift copies only as a fallback.
    func tryLoadKext() {
        let existing = VB.kextLoadCandidates.filter { FileManager.default.fileExists(atPath: $0) }
        // Never touch VoltageShift while our own driver is installed: loading it would only trigger
        // a second "approve extension" prompt. It's a fallback for setups without VoltBarMSR.kext.
        let own = existing.filter { $0.hasSuffix("/VoltBarMSR.kext") }
        let candidates = own.isEmpty ? existing : own
        guard !candidates.isEmpty else {
            vlog("No MSR driver loaded and no kext found to load — waiting (it may be loaded by OpenCore)")
            return
        }
        let path = candidates[loadAttempt % candidates.count]
        loadAttempt += 1
        vlog("Loading \(path) via kmutil")
        // Don't block the hardware queue: kmutil can take several seconds.
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/kmutil")
            p.arguments = ["load", "-p", path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do {
                try p.run()
                p.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                vlog("kmutil exited with code \(p.terminationStatus)" + (out.isEmpty ? "" : ": \(out.prefix(400))"))
            } catch {
                vlog("Failed to run kmutil: \(error)")
            }
        }
    }

    func onKextReady() {
        // Заводские значения снимаем один раз за загрузку, ДО применения профиля.
        let freshBoot = !sameBoot(state.factoryBoot, currentBoot)
        restorePreReleaseRegisters(freshBoot: freshBoot)
        if freshBoot || state.factoryPL == nil {
            if let pl = try? hw.dev.read(MSR.pkgPowerLimit) { state.factoryPL = pl }
            if let t = try? hw.turboEnabled() { state.factoryTurbo = t }
            state.factoryBoot = currentBoot
            persist()
            vlog("Factory values: 0x610=\(state.factoryPL.map { "0x" + String($0, radix: 16) } ?? "?"), turbo=\(state.factoryTurbo.map { "\($0)" } ?? "?")")
        }
        checkForPanic()
        if let s = activeSettings {
            let errs = apply(s)
            vlog("Profile applied at startup" + (errs.isEmpty ? "" : " with errors: \(errs.joined(separator: "; "))"))
        }
    }

    // MARK: Применение

    /// Применяет настройки. Возвращает список ошибок (пустой — всё хорошо).
    @discardableResult
    func apply(_ s: VBSettings) -> [String] {
        var errors: [String] = []
        for plane in 0..<6 {
            let target = s.offsets[plane]
            do {
                try hw.writeOffset(plane, mv: target)
            } catch {
                // Плоскость может не поддерживаться (например, I/O на части CPU) — ноль не считаем ошибкой.
                if target != 0 { errors.append("\(VB.planeNames[plane]): \(error)") }
            }
        }

        let wantTurbo: Bool? = s.manageTurbo ? s.turbo : state.factoryTurbo
        if let want = wantTurbo {
            do {
                if try hw.turboEnabled() != want { try hw.setTurbo(want) }
            } catch { errors.append("Turbo: \(error)") }
        }

        do {
            if s.managePower {
                let cur = try hw.readPowerLimits()
                if abs(cur.pl1 - s.pl1) > 0.2 || abs(cur.pl2 - s.pl2) > 0.2 || !cur.pl1Enabled || !cur.pl2Enabled {
                    try hw.setPowerLimits(pl1: s.pl1, pl2: s.pl2)
                }
            } else if let f = state.factoryPL {
                let cur = try hw.dev.read(MSR.pkgPowerLimit)
                if (cur & 0x7FFF_FFFF_FFFF_FFFF) != (f & 0x7FFF_FFFF_FFFF_FFFF) && (cur >> 63) & 1 == 0 {
                    try hw.writeRawPowerLimit(f)
                }
            }
        } catch { errors.append("Power limit: \(error)") }

        return errors
    }

    /// A 1.4 pre-release could change turbo ratios, the TjMax offset and BD PROCHOT. Put them back to
    /// the factory values it recorded (a reboot resets them anyway), then forget them.
    func restorePreReleaseRegisters(freshBoot: Bool) {
        guard state.factoryTurboRatios != nil || state.factoryTjOffset != nil || state.factoryBDProchot != nil else { return }
        if !freshBoot {
            if let f = state.factoryTurboRatios, f.count == 4, (try? hw.turboRatios()) != f { try? hw.setTurboRatios(f) }
            if let f = state.factoryTjOffset, (try? hw.tjOffset()) != f { try? hw.setTjOffset(f) }
            if let f = state.factoryBDProchot, (try? hw.bdProchot()) != f { try? hw.setBDProchot(f) }
            vlog("Restored turbo ratios / TjMax offset / BD PROCHOT to factory values")
        }
        state.factoryTurboRatios = nil
        state.factoryTjOffset = nil
        state.factoryBDProchot = nil
        persist()
    }

    /// Проверяет, что значения на месте; при расхождении применяет заново.
    func enforce(reason: String) {
        guard kextReady, let s = activeSettings else { return }
        var mismatch: [String] = []
        for plane in 0..<6 {
            guard let raw = try? hw.readOffsetRaw(plane) else { continue }
            if raw != Hardware.encodeOffset(s.offsets[plane]) { mismatch.append(VB.planeNames[plane]) }
        }
        if s.manageTurbo, let t = try? hw.turboEnabled(), t != s.turbo { mismatch.append("Turbo") }
        if s.managePower, let pl = try? hw.readPowerLimits(), !pl.locked,
           abs(pl.pl1 - s.pl1) > 0.2 || abs(pl.pl2 - s.pl2) > 0.2 { mismatch.append("PL1/PL2") }
        if !mismatch.isEmpty {
            let errs = apply(s)
            vlog("[\(reason)] restored: \(mismatch.joined(separator: ", "))" + (errs.isEmpty ? "" : "; errors: \(errs.joined(separator: "; "))"))
        }
    }

    func resetHardware() -> [String] {
        var errors: [String] = []
        for plane in 0..<6 {
            do {
                if try hw.readOffsetRaw(plane) != 0 { try hw.writeOffset(plane, mv: 0) }
            } catch {
                // Нечитаемая плоскость — пропускаем.
            }
        }
        do {
            let want = state.factoryTurbo ?? true
            if try hw.turboEnabled() != want { try hw.setTurbo(want) }
        } catch { errors.append("Turbo: \(error)") }
        if let f = state.factoryPL {
            do { try hw.writeRawPowerLimit(f) } catch { errors.append("Power limit: \(error)") }
        }
        return errors
    }

    func scheduleConfirm(after seconds: Double) {
        confirmGeneration += 1
        let gen = confirmGeneration
        q.asyncAfter(deadline: .now() + seconds) { [self] in
            guard gen == confirmGeneration, state.pendingUntil != nil else { return }
            state.pendingUntil = nil
            state.pendingBoot = nil
            persist()
            vlog("Profile confirmed (system stable for \(VB.confirmSeconds / 60) min)")
        }
    }

    func onWake() {
        hw.resetEnergySample()
        guard kextReady else { return }
        if let s = activeSettings {
            let errs = apply(s)
            vlog("Wake: profile applied" + (errs.isEmpty ? "" : " with errors: \(errs.joined(separator: "; "))"))
        }
    }

    // MARK: Статус

    func status() -> Status {
        var st = Status()
        st.daemonVersion = daemonVersion
        st.cpuName = cpuName
        if !kextReady, hw.dev.open() {
            kextReady = true
            onKextReady()
        }
        st.kextLoaded = kextReady
        st.driver = kextReady ? hw.dev.driver?.rawValue : nil
        st.saved = config.settings
        st.active = activeSettings
        st.enforcing = activeSettings != nil
        st.message = state.message
        if let until = state.pendingUntil {
            st.pendingConfirmSeconds = max(0, Int(until - Date().timeIntervalSince1970))
        }
        if override != nil {
            st.message = "Temporary settings in effect (CLI) — the saved profile returns after restart."
        }
        guard kextReady else { return st }

        st.ocLockBit = try? hw.ocLockBit()
        var anyPlane = false
        for plane in 0..<6 {
            if let v = try? hw.readOffset(plane) { st.offsets[plane] = v; anyPlane = true }
        }
        st.undervoltAvailable = anyPlane
        st.turboEnabled = try? hw.turboEnabled()
        if let pl = try? hw.readPowerLimits() {
            st.pl1 = pl.pl1; st.pl2 = pl.pl2
            st.pl1Enabled = pl.pl1Enabled; st.pl2Enabled = pl.pl2Enabled
            st.powerLocked = pl.locked
        }
        if let f = state.factoryPL, let unit = try? hw.powerUnitWatts() {
            let (a, b) = Hardware.decodePL(raw: f, unit: unit)
            st.factoryPL1 = a; st.factoryPL2 = b
        }
        if fans.available {
            st.fans = fans.fanInfo()
            st.sensors = fans.sensorInfo()
            st.fanConfig = fans.config
            st.fanMessage = fans.message
        }
        st.tempC = try? hw.temperature()
        st.freqGHz = try? hw.frequencyGHz()
        st.packageW = hw.packageWatts()
        return st
    }

    // MARK: Команды

    func handle(_ req: Request, uid: uid_t) -> Response {
        switch req.cmd {
        case "status":
            return Response(ok: true, status: status())

        case "save", "apply":
            guard let s = req.settings else { return Response(ok: false, error: "No settings") }
            if let e = s.validate() { return Response(ok: false, error: e) }
            guard kextReady || hw.dev.open() else { return Response(ok: false, error: HWError.noKext.description) }
            kextReady = true
            let errs = apply(s)
            if req.cmd == "apply" {
                override = s
                vlog("Temporary settings applied (uid \(uid))")
                return Response(ok: errs.isEmpty, error: errs.isEmpty ? nil : "Applied with errors", status: status(), details: errs)
            }
            if !errs.isEmpty {
                // Не сохраняем профиль, который не удалось применить целиком; возвращаемся к прежнему.
                if let prev = activeSettings { apply(prev) } else { _ = resetHardware() }
                return Response(ok: false, error: "Profile not saved", status: status(), details: errs)
            }
            override = nil
            config.settings = s
            config.enabled = true
            state.message = nil
            state.pendingUntil = Date().timeIntervalSince1970 + Double(VB.confirmSeconds)
            state.pendingBoot = currentBoot
            state.profileSavedAt = Date().timeIntervalSince1970
            state.handledPanicAt = newestPanicReport()?.date ?? state.handledPanicAt
            persist()
            scheduleConfirm(after: Double(VB.confirmSeconds))
            vlog("Profile saved (uid \(uid)): \(s.offsets) turbo=\(s.manageTurbo ? "\(s.turbo)" : "-") power=\(s.managePower ? "\(s.pl1)/\(s.pl2)" : "-")")
            return Response(ok: true, status: status())

        case "undervolt":
            // Switch the saved profile on/off without forgetting it (unlike "reset").
            guard let on = req.enabled else { return Response(ok: false, error: "Missing on/off") }
            if on {
                guard let s = config.settings else { return Response(ok: false, error: "No saved profile yet — adjust the values and press Save") }
                guard kextReady || hw.dev.open() else { return Response(ok: false, error: HWError.noKext.description) }
                kextReady = true
                let errs = apply(s)
                if !errs.isEmpty {
                    _ = resetHardware()
                    return Response(ok: false, error: "Profile could not be applied", status: status(), details: errs)
                }
                override = nil
                config.enabled = true
                state.message = nil
                state.pendingUntil = Date().timeIntervalSince1970 + Double(VB.confirmSeconds)
                state.pendingBoot = currentBoot
                state.profileSavedAt = Date().timeIntervalSince1970
                state.handledPanicAt = newestPanicReport()?.date ?? state.handledPanicAt
                persist()
                scheduleConfirm(after: Double(VB.confirmSeconds))
                vlog("Undervolting on (uid \(uid))")
            } else {
                var errs: [String] = []
                if kextReady || hw.dev.open() { kextReady = true; errs = resetHardware() }
                override = nil
                config.enabled = false
                state.pendingUntil = nil
                state.pendingBoot = nil
                persist()
                confirmGeneration += 1
                vlog("Undervolting off (uid \(uid))")
                if !errs.isEmpty { return Response(ok: false, error: "Turned off with errors", status: status(), details: errs) }
            }
            return Response(ok: true, status: status())

        case "fans":
            guard fans.available else { return Response(ok: false, error: "Fan control is not available on this Mac") }
            guard let c = req.fanConfig else { return Response(ok: false, error: "No fan settings") }
            if let e = fans.validate(c) { return Response(ok: false, error: e) }
            config.fans = c
            fans.config = c
            persist()
            fans.tick()
            vlog("Fans: control \(c.enabled ? "on" : "off") — " + c.fans.enumerated().map { "\($0.offset): \($0.element.mode.rawValue)" }.joined(separator: ", ") + " (uid \(uid))")
            return Response(ok: true, status: status())

        case "reset":
            var errs: [String] = []
            if kextReady || hw.dev.open() {
                kextReady = true
                errs = resetHardware()
            } else {
                // No driver: nothing is applied right now, but make sure nothing will be applied later.
                vlog("Reset without driver: profile disabled, hardware untouched")
            }
            override = nil
            config = Config()
            state.pendingUntil = nil
            state.pendingBoot = nil
            state.message = nil
            persist()
            confirmGeneration += 1
            vlog("Reset to factory values (uid \(uid))")
            return Response(ok: errs.isEmpty, error: errs.isEmpty ? nil : "Reset with errors", status: status(), details: errs)

        case "read":
            guard uid == 0 else { return Response(ok: false, error: "Reading MSRs requires root (sudo)") }
            guard let msr = req.msr else { return Response(ok: false, error: "No MSR specified") }
            do { return Response(ok: true, value: try hw.dev.read(msr)) }
            catch { return Response(ok: false, error: "\(error)") }

        case "write":
            guard uid == 0 else { return Response(ok: false, error: "Writing MSRs requires root (sudo)") }
            guard let msr = req.msr, let v = req.value else { return Response(ok: false, error: "MSR and value are required") }
            do {
                try hw.dev.write(msr, v)
                vlog("WRMSR 0x\(String(msr, radix: 16)) = 0x\(String(v, radix: 16)) (uid \(uid))")
                return Response(ok: true, value: try? hw.dev.read(msr))
            } catch { return Response(ok: false, error: "\(error)") }

        default:
            return Response(ok: false, error: "Unknown command \(req.cmd)")
        }
    }
}

