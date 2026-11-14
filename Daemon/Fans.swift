// VoltBar daemon — fan control through the SMC.
//
// Safety rules:
//   * control is handed back to the system (SMC auto mode) when it is switched off, before sleep,
//     when the daemon exits (SIGTERM) and every time the daemon starts (crash recovery);
//   * above VB.fanFailsafeTemp CPU temperature every controlled fan runs at its maximum;
//   * if a fan's sensor can't be read, that fan runs at its maximum;
//   * speeds are always clamped to the fan's own min…max reported by the SMC.

import Foundation

final class FanController {
    private let smc = SMC()
    private let packageTemp: () -> Double?

    private(set) var available = false
    private(set) var fanCount = 0
    private var names: [String] = []
    private var mins: [Double] = []
    private var maxs: [Double] = []
    private var sensors: [(key: String, name: String)] = []
    private var useForceMask = true          // FS! bitmask (2013–2015 Macs) vs. F<n>Md mode keys

    var config = FanConfig()
    /// Set while the system goes to sleep: fans stay with the system until wake.
    var suspended = false
    private var controlled: Set<Int> = []
    private var lastTarget: [Int: Double] = [:]
    private(set) var message: String? = nil

    /// Fastest allowed slow-down per tick (1 s); speeding up is immediate.
    private let rampDown: Double = 150

    init(packageTemp: @escaping () -> Double?) {
        self.packageTemp = packageTemp
    }

    func setup() {
        guard smc.open(), let n = try? smc.readNumber("FNum"), n > 0 else {
            vlog("Fans: SMC not available or no fans")
            return
        }
        fanCount = Int(n)
        for i in 0..<fanCount {
            names.append(fanName(i))
            mins.append((try? smc.readNumber("F\(i)Mn")) ?? 1000)
            maxs.append((try? smc.readNumber("F\(i)Mx")) ?? 6000)
        }
        useForceMask = smc.exists("FS! ")
        sensors = smcSensorCandidates.filter { (try? smc.readNumber($0.key)) != nil }.map { ($0.key, $0.name) }
        available = true
        vlog("Fans: \(fanCount) (" + (0..<fanCount).map { "\(names[$0]) \(Int(mins[$0]))–\(Int(maxs[$0]))" }.joined(separator: ", ")
             + "), \(sensors.count) sensors, control via \(useForceMask ? "FS!" : "F<n>Md")")
        // A previous daemon may have died while forcing the fans: start from system control.
        releaseAll(force: true)
    }

    private func fanName(_ i: Int) -> String {
        if let (_, b) = try? smc.readBytes("F\(i)ID"), b.count > 4 {
            let s = String(decoding: b.dropFirst(4).filter { $0 >= 32 && $0 < 127 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { return s.prefix(1).uppercased() + s.dropFirst() + (s.lowercased().hasSuffix("fan") ? "" : " fan") }
        }
        return "Fan \(i + 1)"
    }

    // MARK: Sensors

    private func cpuTemp() -> Double? {
        packageTemp() ?? (try? smc.readNumber("TC0E")) ?? (try? smc.readNumber("TC0P"))
    }

    func sensorValue(_ key: String) -> Double? {
        key == VB.packageSensor ? packageTemp() : (try? smc.readNumber(key))
    }

    // MARK: Control loop (called every second on the hardware queue)

    func tick() {
        guard available else { return }
        guard config.enabled, !suspended else {
            if !controlled.isEmpty { releaseAll() }
            message = nil
            return
        }
        let cpu = cpuTemp()
        let failsafe = (cpu ?? 0) >= VB.fanFailsafeTemp
        var notes: [String] = []
        for i in 0..<fanCount {
            let s = i < config.fans.count ? config.fans[i] : FanSetting()
            if s.mode == .auto && !failsafe { release(i); continue }
            var target: Double
            if failsafe {
                target = maxs[i]
            } else if let t = sensorValue(s.sensor), let v = s.target(temp: t, min: mins[i], max: maxs[i]) {
                target = v
            } else {
                target = maxs[i]
                notes.append("\(names[i]): sensor \(s.sensor) unavailable, running at full speed")
            }
            if !failsafe, let last = lastTarget[i], target < last { target = max(target, last - rampDown) }
            if let e = force(i, rpm: target) { notes.append(e) }
        }
        if failsafe { notes.insert("CPU above \(Int(VB.fanFailsafeTemp)) °C: fans at full speed", at: 0) }
        let m = notes.isEmpty ? nil : notes.joined(separator: "\n")
        if m != message, let m = m { vlog("Fans: " + m.replacingOccurrences(of: "\n", with: "; ")) }
        message = m
    }

    /// Returns an error text if the SMC refused the change.
    private func force(_ i: Int, rpm: Double) -> String? {
        do {
            if !controlled.contains(i) {
                try setManual(i, true)
                controlled.insert(i)
            }
            if lastTarget[i].map({ abs($0 - rpm) >= 20 }) ?? true {
                try smc.writeRPM("F\(i)Tg", rpm)
                lastTarget[i] = rpm
            }
            return nil
        } catch {
            return "\(names[i]): \(error)"
        }
    }

    private func release(_ i: Int) {
        guard controlled.contains(i) else { return }
        do { try setManual(i, false) } catch { vlog("Fans: release \(names[i]): \(error)") }
        controlled.remove(i)
        lastTarget[i] = nil
    }

    /// Hands every fan back to the system.
    func releaseAll(force: Bool = false) {
        guard available else { return }
        if force {
            for i in 0..<fanCount { try? setManual(i, false) }
            controlled.removeAll()
            lastTarget.removeAll()
            return
        }
        for i in Array(controlled) { release(i) }
    }

    private func setManual(_ i: Int, _ on: Bool) throws {
        if useForceMask {
            let cur = UInt32((try? smc.readNumber("FS! ")) ?? 0)
            let bit = UInt32(1) << UInt32(i)
            let v = on ? (cur | bit) : (cur & ~bit)
            if v != cur || on { try smc.writeUInt("FS! ", v) }
        } else {
            try smc.writeUInt("F\(i)Md", on ? 1 : 0)
        }
    }

    // MARK: Status

    func fanInfo() -> [FanInfo] {
        guard available else { return [] }
        return (0..<fanCount).map { i in
            FanInfo(index: i, name: names[i], rpm: (try? smc.readNumber("F\(i)Ac")) ?? 0,
                    minRPM: mins[i], maxRPM: maxs[i],
                    targetRPM: controlled.contains(i) ? lastTarget[i] : nil,
                    controlled: controlled.contains(i))
        }
    }

    func sensorInfo() -> [SensorInfo] {
        guard available else { return [] }
        return [SensorInfo(key: VB.packageSensor, name: "CPU package", value: packageTemp())]
            + sensors.map { SensorInfo(key: $0.key, name: $0.name, value: try? smc.readNumber($0.key)) }
    }

    /// Validates a config coming from a client.
    func validate(_ c: FanConfig) -> String? {
        let keys = Set([VB.packageSensor] + sensors.map { $0.key })
        for (i, f) in c.fans.enumerated() where i < fanCount {
            if f.mode != .auto && !keys.contains(f.sensor) && f.mode != .fixed { return "Unknown sensor \(f.sensor)" }
            if f.mode == .linear && f.linearMaxTemp <= f.linearMinTemp { return "\(names[i]): max temperature must be above min" }
            if f.mode == .curve && f.curve.count < 2 && !f.curve.isEmpty { return "\(names[i]): a curve needs at least 2 points" }
        }
        return nil
    }
}
