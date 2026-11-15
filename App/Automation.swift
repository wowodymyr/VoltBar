// VoltBar.app — the voltbar:// URL scheme. Works from Shortcuts on every macOS version ("Open URLs"),
// from Terminal (`open voltbar://…`, `voltbarctl profile …`) and from other automation tools.
//
//   voltbar://profile/<name or id>          apply a profile
//   voltbar://gpu/integrated|dynamic|discrete
//   voltbar://fans/on|off
//   voltbar://undervolt/on|off
//   voltbar://monitor                       open the Monitor
//   voltbar://settings[/undervolting|fans|gpu|general]

import AppKit

enum Automation {
    /// Performs a voltbar:// URL; returns an error text when it can't.
    @discardableResult
    static func handle(_ url: URL, model: AppModel,
                       openSettings: (SettingsTab) -> Void, openMonitor: () -> Void) -> String? {
        guard url.scheme?.lowercased() == "voltbar" else { return "Not a voltbar:// URL" }
        let command = (url.host ?? "").lowercased()
        let arg = url.pathComponents.dropFirst().joined(separator: "/").removingPercentEncoding ?? ""
        let value = arg.lowercased()

        switch command {
        case "profile":
            return model.applyProfile(named: arg) ? nil : "No profile named “\(arg)”"
        case "gpu", "graphics":
            guard let m = GPUMode(rawValue: value) else { return "Unknown graphics mode “\(arg)”" }
            guard model.features.gpu, model.gpu.available else { return "Graphics switching isn't available" }
            model.gpu.apply(m, confirmed: true)
        case "fans":
            guard let on = onOff(value) else { return "Use voltbar://fans/on or /off" }
            guard model.features.fans else { return "Fan control is turned off in Settings → General" }
            model.updateFans(immediate: true) { $0.enabled = on }
        case "undervolt", "undervolting":
            guard let on = onOff(value) else { return "Use voltbar://undervolt/on or /off" }
            guard model.features.undervolting else { return "Undervolting is turned off in Settings → General" }
            model.setUndervolting(on)
        case "monitor":
            openMonitor()
        case "settings":
            let tab = SettingsTab.allCases.first { "\($0)".lowercased() == value } ?? .general
            openSettings(tab)
        default:
            return "Unknown command “\(command)”"
        }
        return nil
    }

    private static func onOff(_ s: String) -> Bool? {
        switch s {
        case "on", "1", "true", "yes": return true
        case "off", "0", "false", "no": return false
        default: return nil
        }
    }
}
