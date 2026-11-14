// VoltBar daemon — доступ к MSR через VoltageShift.kext и логика андервольтинга.
// Интерфейс kext взят из VoltageShift (sicreative, GPL-3.0):
//   класс сервиса "VoltageShiftAnVMSR", селекторы 0 = RDMSR, 1 = WRMSR,
//   структура { UInt32 action; UInt32 msr; UInt64 param } на вход и выход.

import Foundation
import IOKit

struct MSRIO {
    var action: UInt32
    var msr: UInt32
    var param: UInt64
}

enum HWError: Error, CustomStringConvertible {
    case noKext, call(String, kern_return_t), mailboxBusy, mailbox(UInt8), locked, verify
    var description: String {
        switch self {
        case .noKext: return "MSR driver (VoltBarMSR.kext) is not loaded"
        case .call(let what, let kr): return "\(what): IOKit 0x\(String(UInt32(bitPattern: kr), radix: 16))"
        case .mailboxBusy: return "OC Mailbox busy (timeout)"
        case .mailbox(let c): return "OC Mailbox returned code \(c)\(c == 1 ? " (OC Locked)" : "")"
        case .locked: return "register is locked by firmware"
        case .verify: return "read-back value does not match"
        }
    }
}

/// MSR access through one of two kernel drivers:
///  * VoltBarMSR (our own kext, preferred): scalar methods 0 = read, 1 = write;
///  * VoltageShift.kext (legacy): struct methods 0 = RDMSR, 1 = WRMSR.
final class MSRDevice {
    enum Driver: String { case voltbar = "VoltBarMSR", voltageShift = "VoltageShift" }

    private var connect: io_connect_t = 0
    private(set) var driver: Driver? = nil

    var isOpen: Bool { connect != 0 }

    func open() -> Bool {
        if connect != 0 { return true }
        for (cls, drv) in [(VB.ownKextClass, Driver.voltbar), (VB.kextClass, Driver.voltageShift)] {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(cls))
            if service == 0 { continue }
            defer { IOObjectRelease(service) }
            var c: io_connect_t = 0
            let kr = IOServiceOpen(service, mach_task_self_, 0, &c)
            if kr != KERN_SUCCESS {
                vlog("IOServiceOpen(\(cls)) failed: 0x\(String(UInt32(bitPattern: kr), radix: 16))")
                continue
            }
            connect = c
            if driver != drv { vlog("Using driver \(drv.rawValue)") }
            driver = drv
            return true
        }
        return false
    }

    func close() {
        if connect != 0 { IOServiceClose(connect); connect = 0 }
    }

    private func call(_ selector: UInt32, msr: UInt32, param: UInt64) throws -> UInt64 {
        if connect == 0 && !open() { throw HWError.noKext }
        var kr: kern_return_t
        var result: UInt64 = 0
        if driver == .voltbar {
            var input: [UInt64] = selector == 0 ? [UInt64(msr)] : [UInt64(msr), param]
            var out: UInt64 = 0
            var outCount: UInt32 = 1
            kr = IOConnectCallScalarMethod(connect, selector, &input, UInt32(input.count), &out, &outCount)
            result = out
        } else {
            var input = MSRIO(action: selector, msr: msr, param: param)
            var output = MSRIO(action: 0, msr: 0, param: 0)
            var outSize = MemoryLayout<MSRIO>.size
            kr = IOConnectCallStructMethod(connect, selector, &input, MemoryLayout<MSRIO>.size, &output, &outSize)
            result = output.param
        }
        if kr != KERN_SUCCESS {
            let what = (selector == 0 ? "RDMSR 0x" : "WRMSR 0x") + String(msr, radix: 16)
            // Our kext returns real errors for unknown/forbidden MSRs — keep the connection then.
            // Anything else: the connection may be stale (kext reloaded), reopen next time.
            if driver != .voltbar || kr == kIOReturnNotAttached || kr == MACH_SEND_INVALID_DEST || kr == kIOReturnNotOpen {
                close()
            }
            throw HWError.call(what, kr)
        }
        return result
    }

    func read(_ msr: UInt32) throws -> UInt64 { try call(0, msr: msr, param: 0) }
    func write(_ msr: UInt32, _ value: UInt64) throws { _ = try call(1, msr: msr, param: value) }
}

// MARK: - Регистры

enum MSR {
    static let ocMailbox: UInt32      = 0x150
    static let flexRatio: UInt32      = 0x194
    static let perfStatus: UInt32     = 0x198
    static let miscEnable: UInt32     = 0x1A0
    static let tempTarget: UInt32     = 0x1A2
    static let pkgThermStatus: UInt32 = 0x1B1
    static let raplUnit: UInt32       = 0x606
    static let pkgPowerLimit: UInt32  = 0x610
    static let pkgEnergy: UInt32      = 0x611
}

final class Hardware {
    let dev = MSRDevice()

    // MARK: OC Mailbox (смещения напряжения)

    /// Одна транзакция OC Mailbox. Возвращает ответ (биты 0..31 — данные, 32..39 — код).
    private func mailbox(cmd: UInt64, domain: Int, data: UInt64) throws -> UInt64 {
        let request: UInt64 = (1 << 63) | (UInt64(domain & 0xFF) << 40) | ((cmd & 0xFF) << 32) | (data & 0xFFFF_FFFF)
        try dev.write(MSR.ocMailbox, request)
        for _ in 0..<20 {
            let r = try dev.read(MSR.ocMailbox)
            if (r >> 63) & 1 == 0 {
                let code = UInt8((r >> 32) & 0xFF)
                if code != 0 { throw HWError.mailbox(code) }
                return r
            }
            usleep(500)
        }
        throw HWError.mailboxBusy
    }

    /// мВ -> 11-битное знаковое значение в единицах 1/1.024 мВ.
    static func encodeOffset(_ mv: Int) -> UInt64 {
        let units = Int((Double(mv) * 1.024).rounded())
        return UInt64(bitPattern: Int64(units)) & 0x7FF
    }

    static func decodeOffset(_ raw11: UInt64) -> Double {
        var v = Int(raw11 & 0x7FF)
        if v & 0x400 != 0 { v -= 0x800 }
        return Double(v) / 1.024
    }

    func readOffsetRaw(_ plane: Int) throws -> UInt64 {
        let r = try mailbox(cmd: 0x10, domain: plane, data: 0)
        return (r >> 21) & 0x7FF
    }

    func readOffset(_ plane: Int) throws -> Double {
        Hardware.decodeOffset(try readOffsetRaw(plane))
    }

    func writeOffset(_ plane: Int, mv: Int) throws {
        let raw = Hardware.encodeOffset(mv)
        _ = try mailbox(cmd: 0x11, domain: plane, data: raw << 21)
        // Проверяем, что значение реально встало.
        let back = try readOffsetRaw(plane)
        if back != raw {
            throw HWError.verify
        }
    }

    func undervoltAvailable() -> Bool {
        (try? readOffsetRaw(0)) != nil
    }

    // MARK: Turbo

    func turboEnabled() throws -> Bool {
        let v = try dev.read(MSR.miscEnable)
        return (v >> 38) & 1 == 0
    }

    func setTurbo(_ on: Bool) throws {
        var v = try dev.read(MSR.miscEnable)
        let bit: UInt64 = 1 << 38
        if on { v &= ~bit } else { v |= bit }
        try dev.write(MSR.miscEnable, v)
    }

    // MARK: Power limits (MSR 0x610)

    func powerUnitWatts() throws -> Double {
        let u = try dev.read(MSR.raplUnit)
        return 1.0 / Double(1 << Int(u & 0xF))
    }

    func energyUnitJoules() throws -> Double {
        let u = try dev.read(MSR.raplUnit)
        return 1.0 / Double(UInt64(1) << ((u >> 8) & 0x1F))
    }

    struct PowerLimits {
        var raw: UInt64
        var pl1: Double, pl2: Double
        var pl1Enabled: Bool, pl2Enabled: Bool
        var locked: Bool
    }

    func readPowerLimits() throws -> PowerLimits {
        let unit = try powerUnitWatts()
        let v = try dev.read(MSR.pkgPowerLimit)
        return PowerLimits(raw: v,
                           pl1: Double(v & 0x7FFF) * unit,
                           pl2: Double((v >> 32) & 0x7FFF) * unit,
                           pl1Enabled: (v >> 15) & 1 == 1,
                           pl2Enabled: (v >> 47) & 1 == 1,
                           locked: (v >> 63) & 1 == 1)
    }

    static func decodePL(raw: UInt64, unit: Double) -> (Double, Double) {
        (Double(raw & 0x7FFF) * unit, Double((raw >> 32) & 0x7FFF) * unit)
    }

    /// Устанавливает PL1/PL2, сохраняя окна времени и прочие биты.
    func setPowerLimits(pl1: Double, pl2: Double) throws {
        let unit = try powerUnitWatts()
        var v = try dev.read(MSR.pkgPowerLimit)
        if (v >> 63) & 1 == 1 { throw HWError.locked }
        let r1 = UInt64(max(1, min(0x7FFF, (pl1 / unit).rounded())))
        let r2 = UInt64(max(1, min(0x7FFF, (pl2 / unit).rounded())))
        v &= ~UInt64(0x7FFF)
        v &= ~(UInt64(0x7FFF) << 32)
        v |= r1 | (1 << 15)
        v |= (r2 << 32) | (1 << 47)
        try dev.write(MSR.pkgPowerLimit, v)
    }

    func writeRawPowerLimit(_ raw: UInt64) throws {
        let cur = try dev.read(MSR.pkgPowerLimit)
        if (cur >> 63) & 1 == 1 { throw HWError.locked }
        try dev.write(MSR.pkgPowerLimit, raw & ~(UInt64(1) << 63))
    }

    // MARK: Мониторинг

    func temperature() throws -> Int {
        let tj = Int((try dev.read(MSR.tempTarget) >> 16) & 0xFF)
        let st = try dev.read(MSR.pkgThermStatus)
        let readout = Int((st >> 16) & 0x7F)
        return tj - readout
    }

    func frequencyGHz() throws -> Double {
        let v = try dev.read(MSR.perfStatus)
        return Double((v >> 8) & 0xFF) / 10.0
    }

    func ocLockBit() throws -> Bool {
        ((try dev.read(MSR.flexRatio)) >> 20) & 1 == 1
    }

    private var lastEnergy: (raw: UInt64, time: TimeInterval)? = nil

    func resetEnergySample() { lastEnergy = nil }

    /// Мощность пакета по дельте счётчика энергии с прошлого вызова.
    func packageWatts() -> Double? {
        guard let eu = try? energyUnitJoules(),
              let e = try? dev.read(MSR.pkgEnergy) else { return nil }
        let raw = e & 0xFFFF_FFFF
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastEnergy = (raw, now) }
        guard let last = lastEnergy else { return nil }
        let dt = now - last.time
        if dt < 0.2 || dt > 30 { return nil }
        let delta = raw >= last.raw ? raw - last.raw : (0x1_0000_0000 - last.raw) + raw
        return Double(delta) * eu / dt
    }
}

// MARK: - Лог

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func vlog(_ s: String) {
    let line = "[\(logFormatter.string(from: Date()))] \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}
