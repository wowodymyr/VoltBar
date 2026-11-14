// VoltBar daemon (com.voltbar.daemon) — точка входа. Запускается launchd от root.

import Foundation

signal(SIGPIPE, SIG_IGN)

// MARK: - Запуск

// Mark a normal exit (shutdown/restart/reinstall) so the next boot can tell it apart from a hang.
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: core.q)
termSource.setEventHandler {
    core.markCleanExit()
    vlog("SIGTERM: clean exit")
    exit(0)
}
termSource.resume()

core.q.sync { core.start() }
startServer()
registerPower()
RunLoop.main.run()
