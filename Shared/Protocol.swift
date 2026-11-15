// VoltBar — общий протокол между демоном, приложением и CLI.
// Лицензия: GPL-3.0 (как и VoltageShift, с которым совместим kext).

import Foundation

public enum VB {
    public static let socketPath   = "/var/run/com.voltbar.daemon.sock"
    public static let supportDir   = "/Library/Application Support/VoltBar"
    public static let configPath   = supportDir + "/config.json"
    public static let statePath    = supportDir + "/state.json"
    public static let kextCopyPath = "/Library/Extensions/VoltageShift.kext"
    public static let kextBundleID = "com.sicreative.VoltageShift"
    public static let kextClass    = "VoltageShiftAnVMSR"
    /// Our own driver (Kext/VoltBarMSR.cpp), installed by VoltBar.pkg and loaded by the daemon.
    public static let ownKextPath  = supportDir + "/VoltBarMSR.kext"
    public static let ownKextClass = "VoltBarMSR"
    /// Places where a kext is loaded from by the daemon if no driver is running yet (in order).
    public static let kextLoadCandidates = [ownKextPath,
                                            "/Library/Extensions/VoltBarMSR.kext",
                                            kextCopyPath,
                                            "/Library/Application Support/VoltageShift/VoltageShift.kext"]

    /// Имена плоскостей в порядке доменов OC Mailbox (как у VoltageShift).
    public static let planeNames = ["CPU", "GPU", "CPU Cache", "System Agent", "Analog I/O", "Digital I/O"]

    public static let normalRange: ClosedRange<Int> = -250...250
    public static let damageRange: ClosedRange<Int> = -500...500
    public static let powerRange: ClosedRange<Double> = 3...200

    /// Сколько секунд после «Сохранить» система должна проработать без сбоя,
    /// чтобы профиль считался подтверждённым и применялся при загрузке.
    public static let confirmSeconds = 600

    /// Pseudo sensor key: CPU package temperature read from MSR (the most responsive CPU reading).
    public static let packageSensor = "CPU package"
    /// Above this CPU package temperature every controlled fan runs at full speed, whatever its mode.
    public static let fanFailsafeTemp: Double = 95
}

/// Профиль, который пользователь сохраняет.
public struct VBSettings: Codable, Equatable {
    public var offsets: [Int]          // 6 values, mV
    public var damageMode: Bool        // extended range (like --damage)
    public var manageTurbo: Bool
    public var turbo: Bool             // true = Turbo Boost enabled
    public var managePower: Bool
    public var pl1: Double             // W, long term
    public var pl2: Double             // W, short term

    public init(offsets: [Int] = Array(repeating: 0, count: 6),
                damageMode: Bool = false,
                manageTurbo: Bool = false, turbo: Bool = true,
                managePower: Bool = false, pl1: Double = 47, pl2: Double = 58.75) {
        self.offsets = offsets
        self.damageMode = damageMode
        self.manageTurbo = manageTurbo
        self.turbo = turbo
        self.managePower = managePower
        self.pl1 = pl1
        self.pl2 = pl2
    }

    // Tolerant decoding: a missing key falls back to the default instead of discarding the whole profile.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VBSettings()
        offsets = try c.decodeIfPresent([Int].self, forKey: .offsets) ?? d.offsets
        damageMode = try c.decodeIfPresent(Bool.self, forKey: .damageMode) ?? d.damageMode
        manageTurbo = try c.decodeIfPresent(Bool.self, forKey: .manageTurbo) ?? d.manageTurbo
        turbo = try c.decodeIfPresent(Bool.self, forKey: .turbo) ?? d.turbo
        managePower = try c.decodeIfPresent(Bool.self, forKey: .managePower) ?? d.managePower
        pl1 = try c.decodeIfPresent(Double.self, forKey: .pl1) ?? d.pl1
        pl2 = try c.decodeIfPresent(Double.self, forKey: .pl2) ?? d.pl2
    }

    /// Validates values; returns an error text or nil.
    public func validate() -> String? {
        if offsets.count != 6 { return "Exactly 6 offset values are required" }
        let range = damageMode ? VB.damageRange : VB.normalRange
        for (i, v) in offsets.enumerated() where !range.contains(v) {
            return "\(VB.planeNames[i]): \(v) mV is outside \(range.lowerBound)…\(range.upperBound)"
        }
        if managePower {
            if !VB.powerRange.contains(pl1) || !VB.powerRange.contains(pl2) {
                return "PL1/PL2 must be within \(Int(VB.powerRange.lowerBound))…\(Int(VB.powerRange.upperBound)) W"
            }
        }
        return nil
    }
}

// MARK: - Fans

public enum FanMode: String, Codable, CaseIterable {
    case auto      // system (SMC) control
    case fixed     // constant RPM
    case linear    // min temp -> min RPM, max temp -> max RPM, straight line in between
    case curve     // user-defined points (temperature -> RPM)
}

public struct FanCurvePoint: Codable, Equatable {
    public var temp: Double   // °C
    public var rpm: Double
    public init(temp: Double, rpm: Double) { self.temp = temp; self.rpm = rpm }
}

public struct FanSetting: Codable, Equatable {
    public var mode: FanMode = .auto
    public var sensor: String = VB.packageSensor   // sensor key (SMC key or VB.packageSensor)
    public var fixedRPM: Double = 3000
    public var linearMinTemp: Double = 50
    public var linearMaxTemp: Double = 90
    public var curve: [FanCurvePoint] = []          // sorted by temp; empty = default curve for the fan

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FanSetting()
        mode = (try? c.decodeIfPresent(FanMode.self, forKey: .mode)) ?? d.mode
        sensor = try c.decodeIfPresent(String.self, forKey: .sensor) ?? d.sensor
        fixedRPM = try c.decodeIfPresent(Double.self, forKey: .fixedRPM) ?? d.fixedRPM
        linearMinTemp = try c.decodeIfPresent(Double.self, forKey: .linearMinTemp) ?? d.linearMinTemp
        linearMaxTemp = try c.decodeIfPresent(Double.self, forKey: .linearMaxTemp) ?? d.linearMaxTemp
        curve = try c.decodeIfPresent([FanCurvePoint].self, forKey: .curve) ?? d.curve
    }

    /// Default 5-point curve spanning the fan's RPM range.
    public static func defaultCurve(min: Double, max: Double) -> [FanCurvePoint] {
        let temps: [Double] = [40, 55, 70, 80, 90]
        let fr: [Double] = [0, 0.15, 0.4, 0.7, 1]
        return zip(temps, fr).map { FanCurvePoint(temp: $0, rpm: (min + (max - min) * $1).rounded()) }
    }

    /// Target RPM for a sensor temperature, clamped to the fan's range.
    public func target(temp: Double, min lo: Double, max hi: Double) -> Double? {
        func clamp(_ v: Double) -> Double { Swift.min(hi, Swift.max(lo, v)) }
        switch mode {
        case .auto:
            return nil
        case .fixed:
            return clamp(fixedRPM)
        case .linear:
            let span = Swift.max(1, linearMaxTemp - linearMinTemp)
            let f = Swift.min(1, Swift.max(0, (temp - linearMinTemp) / span))
            return clamp(lo + (hi - lo) * f)
        case .curve:
            let pts = (curve.isEmpty ? FanSetting.defaultCurve(min: lo, max: hi) : curve).sorted { $0.temp < $1.temp }
            guard let first = pts.first, let last = pts.last else { return nil }
            if temp <= first.temp { return clamp(first.rpm) }
            if temp >= last.temp { return clamp(last.rpm) }
            for (a, b) in zip(pts, pts.dropFirst()) where temp <= b.temp {
                let f = (temp - a.temp) / Swift.max(0.001, b.temp - a.temp)
                return clamp(a.rpm + (b.rpm - a.rpm) * f)
            }
            return clamp(last.rpm)
        }
    }
}

public struct FanConfig: Codable, Equatable {
    public var enabled: Bool = false
    public var fans: [FanSetting] = []
    public init() {}
}

public struct FanInfo: Codable, Equatable {
    public var index: Int
    public var name: String
    public var rpm: Double
    public var minRPM: Double
    public var maxRPM: Double
    public var targetRPM: Double?
    public var controlled: Bool          // VoltBar is driving this fan right now
    public init(index: Int, name: String, rpm: Double, minRPM: Double, maxRPM: Double, targetRPM: Double?, controlled: Bool) {
        self.index = index; self.name = name; self.rpm = rpm; self.minRPM = minRPM; self.maxRPM = maxRPM
        self.targetRPM = targetRPM; self.controlled = controlled
    }
}

public struct SensorInfo: Codable, Equatable {
    public var key: String
    public var name: String
    public var value: Double?
    public init(key: String, name: String, value: Double?) { self.key = key; self.name = name; self.value = value }
}

/// Текущее состояние железа и демона.
public struct Status: Codable, Equatable {
    public var daemonVersion: String = ""
    public var cpuName: String = ""
    public var kextLoaded: Bool = false
    public var driver: String? = nil           // "VoltBarMSR" / "VoltageShift"
    public var ocLockBit: Bool? = nil          // MSR 0x194 бит 20
    public var undervoltAvailable: Bool = false // OC Mailbox отвечает
    public var offsets: [Double?] = Array(repeating: nil, count: 6) // фактические, мВ
    public var turboEnabled: Bool? = nil
    public var pl1: Double? = nil
    public var pl2: Double? = nil
    public var pl1Enabled: Bool? = nil
    public var pl2Enabled: Bool? = nil
    public var powerLocked: Bool? = nil        // MSR 0x610 бит 63
    public var factoryPL1: Double? = nil
    public var factoryPL2: Double? = nil
    public var tempC: Int? = nil
    public var freqGHz: Double? = nil
    public var packageW: Double? = nil
    public var saved: VBSettings? = nil          // сохранённый профиль (может быть отключён защитой)
    public var active: VBSettings? = nil         // то, что сейчас поддерживается демоном
    public var enforcing: Bool = false
    public var pendingConfirmSeconds: Int? = nil
    public var message: String? = nil          // последнее важное сообщение демона
    // Fans (since 1.5)
    public var fans: [FanInfo]? = nil
    public var sensors: [SensorInfo]? = nil
    public var fanConfig: FanConfig? = nil
    public var fanMessage: String? = nil

    public init() {}
}

public struct Request: Codable {
    public var cmd: String                     // status | save | reset | apply | read | write
    public var settings: VBSettings? = nil
    public var msr: UInt32? = nil
    public var value: UInt64? = nil
    public var fanConfig: FanConfig? = nil      // for cmd "fans"
    public var enabled: Bool? = nil             // for cmd "undervolt"

    public init(cmd: String, settings: VBSettings? = nil, msr: UInt32? = nil, value: UInt64? = nil, fanConfig: FanConfig? = nil, enabled: Bool? = nil) {
        self.cmd = cmd
        self.settings = settings
        self.msr = msr
        self.value = value
        self.fanConfig = fanConfig
        self.enabled = enabled
    }
}

public struct Response: Codable {
    public var ok: Bool
    public var error: String? = nil
    public var status: Status? = nil
    public var value: UInt64? = nil
    public var details: [String]? = nil

    public init(ok: Bool, error: String? = nil, status: Status? = nil, value: UInt64? = nil, details: [String]? = nil) {
        self.ok = ok
        self.error = error
        self.status = status
        self.value = value
        self.details = details
    }
}

// MARK: - Клиент Unix-сокета (используется приложением и CLI)

public enum ClientError: Error, CustomStringConvertible {
    case connect(String), io(String), decode(String)
    public var description: String {
        switch self {
        case .connect(let s): return "Cannot reach the VoltBar daemon: \(s)"
        case .io(let s):      return "Daemon communication error: \(s)"
        case .decode(let s):  return "Invalid daemon response: \(s)"
        }
    }
}

public func makeUnixAddress(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        let n = min(bytes.count, raw.count - 1)
        for i in 0..<n { raw[i] = bytes[i] }
        raw[n] = 0
    }
    return addr
}

/// Читает из fd до символа '\n'. Возвращает строку без '\n' или nil при EOF.
public func vbReadLine(fd: Int32, buffer: inout [UInt8]) -> Data? {
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        if let idx = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[0..<idx])
            buffer.removeSubrange(0...idx)
            return line
        }
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 { return nil }
        buffer.append(contentsOf: chunk[0..<n])
        if buffer.count > 1_000_000 { return nil }
    }
}

public func writeAll(fd: Int32, _ data: Data) -> Bool {
    var ok = true
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var off = 0
        while off < raw.count {
            let n = write(fd, base + off, raw.count - off)
            if n <= 0 { ok = false; return }
            off += n
        }
    }
    return ok
}

public func sendRequest(_ req: Request, timeout: Int = 10) throws -> Response {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { throw ClientError.connect(String(cString: strerror(errno))) }
    defer { close(fd) }

    var tv = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var nosig: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))

    var addr = makeUnixAddress(VB.socketPath)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if rc != 0 {
        let e = errno
        if e == EACCES { throw ClientError.connect("permission denied (user must be an administrator)") }
        throw ClientError.connect(String(cString: strerror(e)))
    }

    var data = try JSONEncoder().encode(req)
    data.append(0x0A)
    if !writeAll(fd: fd, data) { throw ClientError.io("write failed") }

    var buf = [UInt8]()
    guard let line = vbReadLine(fd: fd, buffer: &buf) else { throw ClientError.io("no reply from daemon") }
    do {
        return try JSONDecoder().decode(Response.self, from: line)
    } catch {
        throw ClientError.decode("\(error)")
    }
}
