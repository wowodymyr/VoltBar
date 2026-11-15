// VoltBar.app — profiles: named snapshots of undervolting, fan and graphics settings that can be applied
// in one go — from the menu, Settings, the voltbar:// URL scheme, `voltbarctl profile` or Shortcuts.
// Every part is optional: a profile only changes what it includes.

import Foundation
import Combine

struct VoltBarProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var symbol = "slider.horizontal.3"

    /// Undervolting: the settings to save and whether undervolting is on. nil = leave as is.
    var undervolt: VBSettings? = nil
    var undervoltEnabled: Bool? = nil
    /// Fan control configuration. nil = leave as is.
    var fans: FanConfig? = nil
    /// Graphics mode. nil = leave as is.
    var gpuMode: GPUMode? = nil

    var summary: String {
        var parts: [String] = []
        if let on = undervoltEnabled {
            if on, let s = undervolt { parts.append("Undervolt \(s.offsets[0])/\(s.offsets[1]) mV") } else { parts.append("Undervolt off") }
        }
        if let f = fans { parts.append(f.enabled ? "Fans: " + Set(f.fans.map(\.mode.title)).sorted().joined(separator: "/") : "Fans: macOS") }
        if let g = gpuMode { parts.append("GPU: \(g.title)") }
        return parts.isEmpty ? "Changes nothing" : parts.joined(separator: " · ")
    }

    static let symbols = ["slider.horizontal.3", "leaf", "speaker.slash", "bolt", "flame", "gamecontroller",
                          "battery.100", "powerplug", "moon", "briefcase", "film", "hammer"]
}

final class ProfileStore: ObservableObject {
    @Published var profiles: [VoltBarProfile] = [] { didSet { if profiles != oldValue { save() } } }
    /// Last profile applied (shown as the current one until settings are changed by hand).
    @Published var activeID: UUID? = nil { didSet { UserDefaults.standard.set(activeID?.uuidString, forKey: "activeProfile") } }

    /// ~/Library/Application Support/VoltBar/profiles.json — also read by `voltbarctl profiles`.
    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoltBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }

    init() {
        if let d = try? Data(contentsOf: Self.fileURL), let p = try? JSONDecoder().decode([VoltBarProfile].self, from: d) {
            profiles = p
        }
        if let s = UserDefaults.standard.string(forKey: "activeProfile") { activeID = UUID(uuidString: s) }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(profiles) { try? d.write(to: Self.fileURL, options: .atomic) }
    }

    /// Finds a profile by id or (case-insensitive) name.
    func find(_ key: String) -> VoltBarProfile? {
        if let u = UUID(uuidString: key), let p = profiles.first(where: { $0.id == u }) { return p }
        return profiles.first { $0.name.compare(key, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    func uniqueName(_ base: String) -> String {
        var name = base, n = 2
        while profiles.contains(where: { $0.name == name }) { name = "\(base) \(n)"; n += 1 }
        return name
    }
}

extension AppModel {
    /// A new profile holding the current settings of every enabled module.
    func captureProfile(named name: String) -> VoltBarProfile {
        var p = VoltBarProfile(name: profiles.uniqueName(name))
        if features.undervolting, let s = status, s.kextLoaded {
            p.undervolt = s.saved ?? draft
            p.undervoltEnabled = s.enforcing
        }
        if features.fans, !fanDraft.fans.isEmpty { p.fans = fanDraft }
        if features.gpu, gpu.available { p.gpuMode = gpu.settings.mode }
        return p
    }

    /// Applies every part a profile includes. Undervolting goes through the daemon's normal save path
    /// (10-minute stability check included); graphics switching doesn't ask about apps that may quit.
    func applyProfile(_ p: VoltBarProfile) {
        if features.undervolting, let on = p.undervoltEnabled {
            if on, let s = p.undervolt {
                draft = s
                save()
            } else if status?.enforcing == true {
                setUndervolting(false)
            }
        }
        if features.fans, let f = p.fans, !live.fans.isEmpty {
            let target = Self.normalized(f, fans: live.fans)
            updateFans(immediate: true) { $0 = target }
        }
        if features.gpu, let g = p.gpuMode, gpu.available {
            gpu.apply(g, confirmed: true)
        }
        profiles.activeID = p.id
    }

    func applyProfile(named key: String) -> Bool {
        guard let p = profiles.find(key) else { return false }
        applyProfile(p)
        return true
    }
}
