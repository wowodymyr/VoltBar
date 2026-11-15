// VoltBar daemon — Apple SMC access (fans and temperature sensors) through the AppleSMC user client.
// Reading works for any user; writing (fan control) requires root, which the daemon has.

import Foundation
import IOKit

/// Mirrors the C struct SMCKeyData_t used by AppleSMC (80 bytes).
struct SMCParam {
    struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    // Explicit padding: Swift would otherwise place the next fields into this struct's tail padding
    // (C keeps it), shifting everything after it and breaking the 80-byte layout.
    struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var dataAttributes: UInt8 = 0, pad0: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0 }

    var key: UInt32 = 0
    var vers = Vers()
    var pLimit = PLimit()
    var keyInfo = KeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

enum SMCError: Error, CustomStringConvertible {
    case notOpen, call(kern_return_t), smc(UInt8), keyNotFound(String), badType(String)
    var description: String {
        switch self {
        case .notOpen: return "AppleSMC is not available"
        case .call(let kr): return "AppleSMC call failed: 0x\(String(UInt32(bitPattern: kr), radix: 16))"
        case .smc(let r): return "SMC error \(r)"
        case .keyNotFound(let k): return "SMC key \(k) not found"
        case .badType(let k): return "SMC key \(k) has an unexpected type"
        }
    }
}

func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
func fourCCString(_ v: UInt32) -> String {
    String(bytes: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)], encoding: .ascii) ?? "????"
}

final class SMC {
    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: SMCParam.KeyInfo] = [:]

    private static let kernelIndex: UInt32 = 2
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdWriteBytes: UInt8 = 6
    private static let cmdReadKeyInfo: UInt8 = 9

    func open() -> Bool {
        if conn != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS
    }

    func close() { if conn != 0 { IOServiceClose(conn); conn = 0 } }

    private func call(_ input: inout SMCParam) throws -> SMCParam {
        guard conn != 0 || open() else { throw SMCError.notOpen }
        var output = SMCParam()
        var outSize = MemoryLayout<SMCParam>.stride
        let kr = IOConnectCallStructMethod(conn, SMC.kernelIndex, &input, MemoryLayout<SMCParam>.stride, &output, &outSize)
        if kr != KERN_SUCCESS { throw SMCError.call(kr) }
        if output.result == 132 { throw SMCError.keyNotFound(fourCCString(input.key)) }
        if output.result != 0 { throw SMCError.smc(output.result) }
        return output
    }

    func keyInfo(_ key: String) throws -> SMCParam.KeyInfo {
        let k = fourCC(key)
        if let i = infoCache[k] { return i }
        var p = SMCParam()
        p.key = k
        p.data8 = SMC.cmdReadKeyInfo
        let out = try call(&p)
        infoCache[k] = out.keyInfo
        return out.keyInfo
    }

    func exists(_ key: String) -> Bool { (try? keyInfo(key)) != nil }

    func readBytes(_ key: String) throws -> (type: String, bytes: [UInt8]) {
        let info = try keyInfo(key)
        var p = SMCParam()
        p.key = fourCC(key)
        p.keyInfo.dataSize = info.dataSize
        p.data8 = SMC.cmdReadBytes
        let out = try call(&p)
        let all = withUnsafeBytes(of: out.bytes) { Array($0) }
        return (fourCCString(info.dataType), Array(all.prefix(Int(info.dataSize))))
    }

    func writeBytes(_ key: String, _ bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard bytes.count == Int(info.dataSize) else { throw SMCError.badType(key) }
        var p = SMCParam()
        p.key = fourCC(key)
        p.keyInfo.dataSize = info.dataSize
        p.data8 = SMC.cmdWriteBytes
        withUnsafeMutableBytes(of: &p.bytes) { raw in for (i, b) in bytes.enumerated() { raw[i] = b } }
        _ = try call(&p)
    }

    // MARK: Typed values

    /// Reads a numeric key, decoding the common SMC types.
    func readNumber(_ key: String) throws -> Double {
        let (type, b) = try readBytes(key)
        switch type {
        case "ui8 ": return Double(b[0])
        case "ui16": return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32": return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "fpe2": return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "sp78": return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case "flt ":
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: bits))
        default: throw SMCError.badType(key)
        }
    }

    /// Writes a fan speed (fpe2 or flt) to `key`.
    func writeRPM(_ key: String, _ rpm: Double) throws {
        let info = try keyInfo(key)
        switch fourCCString(info.dataType) {
        case "fpe2":
            let v = UInt16(max(0, min(16383, rpm.rounded())) * 4)
            try writeBytes(key, [UInt8(v >> 8), UInt8(v & 0xFF)])
        case "flt ":
            let bits = Float(rpm).bitPattern
            try writeBytes(key, [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24)])
        default: throw SMCError.badType(key)
        }
    }

    func writeUInt(_ key: String, _ value: UInt32) throws {
        let info = try keyInfo(key)
        let n = Int(info.dataSize)
        try writeBytes(key, (0..<n).map { UInt8(value >> (8 * UInt32(n - 1 - $0)) & 0xFF) })
    }
}

// MARK: - Known temperature sensors (Intel Macs). Only the ones present on the machine are offered.

let smcSensorCandidates: [(key: String, name: String)] = [
    ("TC0P", "CPU proximity"),
    ("TC0E", "CPU die (virtual)"),
    ("TC0F", "CPU die (filtered)"),
    ("TC0D", "CPU die"),
    ("TC0H", "CPU heatsink"),
    ("TCGC", "Integrated GPU (PECI)"),
    ("TG0P", "GPU proximity"),
    ("TG0D", "GPU die"),
    ("TG0H", "GPU heatsink"),
    ("TPCD", "Platform controller hub"),
    ("TM0P", "Memory proximity"),
    ("Th1H", "Heat pipe"),
    ("TH0P", "Drive proximity"),
    ("Ts0P", "Palm rest"),
    ("TB0T", "Battery"),
]
