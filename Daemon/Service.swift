// VoltBar daemon — Unix-сокет и уведомления о сне/пробуждении.

import Foundation
import IOKit
import IOKit.pwr_mgt

let core = Core()

// MARK: - Unix-сокет

func handleClient(_ fd: Int32) {
    defer { close(fd) }
    var uid: uid_t = 0, gid: gid_t = 0
    if getpeereid(fd, &uid, &gid) != 0 { return }
    var tv = timeval(tv_sec: 120, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var nosig: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))

    var buf = [UInt8]()
    while let line = vbReadLine(fd: fd, buffer: &buf) {
        let resp: Response
        if let req = try? JSONDecoder().decode(Request.self, from: line) {
            resp = core.q.sync { core.handle(req, uid: uid) }
        } else {
            resp = Response(ok: false, error: "Invalid request")
        }
        guard var out = try? JSONEncoder().encode(resp) else { return }
        out.append(0x0A)
        if !writeAll(fd: fd, out) { return }
    }
}

func startServer() {
    let path = VB.socketPath
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { vlog("socket() failed"); exit(1) }
    var addr = makeUnixAddress(path)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard rc == 0 else { vlog("bind(\(path)) failed: \(String(cString: strerror(errno)))"); exit(1) }
    chown(path, 0, 80)      // root:admin
    chmod(path, 0o660)
    guard listen(fd, 16) == 0 else { vlog("listen failed"); exit(1) }

    let t = Thread {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { usleep(10000); continue }
            Thread { handleClient(c) }.start()
        }
    }
    t.start()
    vlog("Listening on \(path)")
}

// MARK: - Сон / пробуждение

private func iokitMsg(_ m: UInt32) -> UInt32 { 0xE000_0000 | m }
let kMsgCanSystemSleep    = iokitMsg(0x270)
let kMsgSystemWillSleep   = iokitMsg(0x280)
let kMsgSystemHasPoweredOn = iokitMsg(0x300)

var rootPowerPort: io_connect_t = 0

let powerCallback: IOServiceInterestCallback = { _, _, messageType, messageArgument in
    switch messageType {
    case kMsgCanSystemSleep, kMsgSystemWillSleep:
        IOAllowPowerChange(rootPowerPort, Int(bitPattern: messageArgument))
    case kMsgSystemHasPoweredOn:
        // После выхода из сна/гибернации значения OC Mailbox сбрасываются — применяем заново
        // (дважды: сразу и с задержкой, на случай если прошивка ещё «досыпает»).
        core.q.asyncAfter(deadline: .now() + 2) { core.onWake() }
        core.q.asyncAfter(deadline: .now() + 15) { core.enforce(reason: "after wake") }
    default:
        break
    }
}

func registerPower() {
    var notifyPort: IONotificationPortRef? = nil
    var notifier: io_object_t = 0
    rootPowerPort = IORegisterForSystemPower(nil, &notifyPort, powerCallback, &notifier)
    guard rootPowerPort != 0, let port = notifyPort else {
        vlog("IORegisterForSystemPower failed — after-sleep restore will rely on the periodic timer only")
        return
    }
    CFRunLoopAddSource(CFRunLoopGetMain(),
                       IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                       .commonModes)
}

