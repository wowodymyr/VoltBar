// voltbarctl — VoltBar command-line client with voltageshift-style commands.

import Foundation

var args = Array(CommandLine.arguments.dropFirst())
var damage = false
if let i = args.firstIndex(of: "--damage") { damage = true; args.remove(at: i) }

func usage() -> Never {
    print("""
    VoltBar CLI (VoltageShift-compatible)

      voltbarctl info                         show current values
      voltbarctl mon                          monitor frequency / temperature / package power
      voltbarctl offset <CPU> [GPU] [Cache] [SA] [AIO] [DIO]
                                              apply voltage offsets (mV) temporarily
      voltbarctl turbo <0|1>                  disable/enable Turbo Boost temporarily
      voltbarctl power <PL1> <PL2>            set power limits (W) temporarily
      voltbarctl fans                         fans, sensors and fan control state
      voltbarctl fans off                     hand all fans back to the system
      voltbarctl save                         save current temporary settings as the profile
      voltbarctl reset                        restore factory values and disable the profile
      sudo voltbarctl read <0xMSR>            read an MSR
      sudo voltbarctl write <0xMSR> <0xVAL>   write an MSR (DANGEROUS)

      --damage  extend the offset range to -500…+500 mV (default -250…+250)

    Temporary settings last until restart; "save" makes them permanent.
    """)
    exit(1)
}

func call(_ r: Request) -> Response {
    do {
        let resp = try sendRequest(r)
        if !resp.ok {
            fputs("Error: \(resp.error ?? "?")\n", stderr)
            for d in resp.details ?? [] { fputs("  • \(d)\n", stderr) }
        }
        return resp
    } catch {
        fputs("\(error)\n", stderr)
        exit(2)
    }
}

func status() -> Status {
    guard let s = call(Request(cmd: "status")).status else { exit(2) }
    return s
}

func fmt(_ v: Double?, _ digits: Int = 1, _ unit: String = "") -> String {
    guard let v = v else { return "—" }
    return String(format: "%.\(digits)f", v) + unit
}

func parseHex(_ s: String) -> UInt64? {
    let t = s.lowercased().hasPrefix("0x") ? String(s.dropFirst(2)) : s
    return UInt64(t, radix: 16)
}

func printInfo(_ s: Status) {
    print("CPU:            \(s.cpuName)")
    print("Kext:           \(s.kextLoaded ? "loaded" : "NOT loaded")")
    if !s.kextLoaded { return }
    print("Driver:         \(s.driver ?? "—")")
    print("OC Mailbox:     \(s.undervoltAvailable ? "available" : "unavailable (OC_Locked?)")" +
          (s.ocLockBit == true ? "   [OC Lock bit set in 0x194]" : ""))
    for (i, name) in VB.planeNames.enumerated() {
        print("  " + name.padding(toLength: 14, withPad: " ", startingAt: 0) + fmt(s.offsets[i], 1, " mV"))
    }
    print("Turbo Boost:    \(s.turboEnabled.map { $0 ? "enabled" : "disabled" } ?? "—")")
    print("PL1 / PL2:      \(fmt(s.pl1, 2)) / \(fmt(s.pl2, 2)) W" + (s.powerLocked == true ? "  [locked]" : "") +
          "   (factory \(fmt(s.factoryPL1, 2)) / \(fmt(s.factoryPL2, 2)))")
    print("Frequency:      \(fmt(s.freqGHz, 1, " GHz"))   Temperature: \(s.tempC.map { "\($0) °C" } ?? "—")")
    print("Profile:        \(s.enforcing ? "active" : "inactive")" +
          (s.pendingConfirmSeconds.map { ", awaiting confirmation for \($0) s more" } ?? ""))
    if let m = s.message { print("Message:        \(m)") }
}

func base(_ s: Status) -> VBSettings {
    var b = s.active ?? s.saved ?? VBSettings()
    if damage { b.damageMode = true }
    return b
}

guard let cmd = args.first else { usage() }
let rest = Array(args.dropFirst())

switch cmd {
case "info":
    printInfo(status())

case "mon":
    _ = status()
    while true {
        sleep(1)
        let s = status()
        print("\(fmt(s.freqGHz, 1, " GHz"))  \(s.tempC.map { "\($0) °C" } ?? "—")  \(fmt(s.packageW, 1, " W"))")
    }

case "offset":
    guard !rest.isEmpty, rest.count <= 6 else { usage() }
    var b = base(status())
    for (i, a) in rest.enumerated() {
        guard let v = Int(a) else { usage() }
        b.offsets[i] = v
    }
    let r = call(Request(cmd: "apply", settings: b))
    if let s = r.status { printInfo(s) }

case "turbo":
    guard rest.count == 1, let v = Int(rest[0]), v == 0 || v == 1 else { usage() }
    var b = base(status())
    b.manageTurbo = true
    b.turbo = v == 1
    let r = call(Request(cmd: "apply", settings: b))
    if let s = r.status { printInfo(s) }

case "power":
    guard rest.count == 2, let p1 = Double(rest[0]), let p2 = Double(rest[1]) else { usage() }
    var b = base(status())
    b.managePower = true
    b.pl1 = p1
    b.pl2 = p2
    let r = call(Request(cmd: "apply", settings: b))
    if let s = r.status { printInfo(s) }

case "fans":
    if rest.first == "off" {
        var fc = status().fanConfig ?? FanConfig()
        fc.enabled = false
        let r = call(Request(cmd: "fans", fanConfig: fc))
        if r.ok { print("Fan control off — the system controls the fans.") }
        break
    }
    let s = status()
    guard let fans = s.fans, !fans.isEmpty else { print("No fans reported by the SMC"); break }
    let fc = s.fanConfig ?? FanConfig()
    print("Fan control:    \(fc.enabled ? "on" : "off")")
    for f in fans {
        let set = f.index < fc.fans.count ? fc.fans[f.index] : FanSetting()
        print("  \(f.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(Int(f.rpm)) rpm  (\(Int(f.minRPM))–\(Int(f.maxRPM)))  "
              + (fc.enabled ? set.mode.rawValue + (set.mode == .fixed ? " · \(Int(set.fixedRPM)) rpm" : set.mode == .auto ? "" : " · \(set.sensor)") : "system"))
    }
    print("Sensors:")
    for x in s.sensors ?? [] { print("  \(x.name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(x.value.map { String(format: "%.1f °C", $0) } ?? "—")") }
    if let m = s.fanMessage { print("Note:           \(m)") }

case "save":
    let s = status()
    guard let b = s.active ?? s.saved else { fputs("Nothing to save\n", stderr); exit(1) }
    let r = call(Request(cmd: "save", settings: b))
    if r.ok { print("Saved. The profile will be applied at boot and after sleep.") }

case "reset":
    let r = call(Request(cmd: "reset"))
    if r.ok { print("Reset to factory values.") }

case "read":
    guard rest.count == 1, let m = parseHex(rest[0]) else { usage() }
    let r = call(Request(cmd: "read", msr: UInt32(truncatingIfNeeded: m)))
    if let v = r.value { print("0x" + String(v, radix: 16, uppercase: true)) }

case "write":
    guard rest.count == 2, let m = parseHex(rest[0]), let v = parseHex(rest[1]) else { usage() }
    let r = call(Request(cmd: "write", msr: UInt32(truncatingIfNeeded: m), value: v))
    if let v = r.value { print("0x" + String(v, radix: 16, uppercase: true)) }

default:
    usage()
}
