// VoltBar daemon (com.voltbar.daemon) — точка входа. Запускается launchd от root.

import Foundation

signal(SIGPIPE, SIG_IGN)

// MARK: - Запуск

core.q.sync { core.start() }
startServer()
registerPower()
RunLoop.main.run()
