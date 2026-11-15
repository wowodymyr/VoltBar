// VoltBar.app — automatic profile switching on power adapter connect/disconnect.
// (Shortcuts only got a "Charger" automation trigger in macOS 14, so VoltBar does it itself.)

import Foundation
import Combine
import IOKit.ps

enum PowerSourceKind: String, Codable {
    case ac, battery

    /// The source currently powering the Mac (nil on Macs without a battery report).
    static func current() -> PowerSourceKind? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return nil }
        if type == kIOPMACPowerKey { return .ac }
        if type == kIOPMBatteryPowerKey { return .battery }
        return nil
    }

    var title: String { self == .ac ? "Power adapter" : "Battery" }
}

struct AutoProfileSettings: Codable, Equatable {
    var onAC: UUID? = nil
    var onBattery: UUID? = nil
    /// Also apply the matching profile when VoltBar starts (e.g. at login).
    var applyAtLaunch = false

    static let key = "autoProfiles"
    static func load() -> AutoProfileSettings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AutoProfileSettings.self, from: d) else { return AutoProfileSettings() }
        return s
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) } }

    func profileID(for kind: PowerSourceKind) -> UUID? { kind == .ac ? onAC : onBattery }
}

final class PowerSourceWatcher: ObservableObject {
    @Published private(set) var source: PowerSourceKind? = PowerSourceKind.current()
    @Published var settings = AutoProfileSettings.load() { didSet { if settings != oldValue { settings.save() } } }
    /// What happened last, for the Profiles tab ("Battery → applied “Silent” at 14:02").
    @Published private(set) var lastEvent: String? = nil

    private var runLoopSource: CFRunLoopSource? = nil
    private var onChange: ((PowerSourceKind) -> Void)? = nil

    /// Starts watching; `apply` is called once per adapter connect/disconnect (not on battery % changes).
    func start(apply: @escaping (PowerSourceKind) -> Void) {
        guard runLoopSource == nil else { return }
        onChange = apply
        source = PowerSourceKind.current()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let rls = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx = ctx else { return }
            Unmanaged<PowerSourceWatcher>.fromOpaque(ctx).takeUnretainedValue().powerChanged()
        }, ctx)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), rls, .defaultMode)
        runLoopSource = rls
    }

    func stop() {
        if let rls = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), rls, .defaultMode) }
        runLoopSource = nil
        onChange = nil
    }

    func note(_ text: String) {
        let f = DateFormatter()
        f.timeStyle = .short
        lastEvent = "\(text) at \(f.string(from: Date()))"
    }

    private func powerChanged() {
        guard let now = PowerSourceKind.current(), now != source else { return }
        source = now
        onChange?(now)
    }
}

extension AppModel {
    /// Applies the profile assigned to `kind`, if any.
    func applyAutoProfile(for kind: PowerSourceKind, reason: String) {
        guard features.autoProfiles else { return }
        guard let id = power.settings.profileID(for: kind),
              let p = profiles.profiles.first(where: { $0.id == id }) else {
            power.note("\(kind.title): no profile assigned")
            return
        }
        applyProfile(p)
        power.note("\(reason) — applied “\(p.name)”")
    }

    func startAutoProfiles(atLaunch: Bool) {
        power.start { [weak self] kind in
            self?.applyAutoProfile(for: kind, reason: kind == .ac ? "Power adapter connected" : "Running on battery")
        }
        if atLaunch, power.settings.applyAtLaunch, let kind = power.source {
            // Give the daemon a moment to answer the first status request first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.applyAutoProfile(for: kind, reason: "VoltBar started on \(kind.title.lowercased())")
            }
        }
    }
}
