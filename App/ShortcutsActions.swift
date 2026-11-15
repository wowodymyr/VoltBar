// VoltBar.app — actions for the Shortcuts app (App Intents, macOS 13+). On macOS 12 the same things
// are available through voltbar:// URLs ("Open URLs" action) — see Automation.swift.
//
// The metadata Shortcuts needs is extracted at build time by build.sh (appintentsmetadataprocessor)
// into VoltBar.app/Contents/Resources/Metadata.appintents.

import AppIntents
import AppKit
import Foundation

@available(macOS 13.0, *)
enum ShortcutsSupport {
    @MainActor
    static func model() throws -> AppModel {
        guard let m = AppModel.shared else { throw VoltBarIntentError.notRunning }
        return m
    }
}

@available(macOS 13.0, *)
enum VoltBarIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning, profileMissing, unavailable(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: return "VoltBar isn't running."
        case .profileMissing: return "That profile doesn't exist any more."
        case .unavailable(let what): return "\(what)"
        }
    }
}

// MARK: - Profiles

@available(macOS 13.0, *)
struct ProfileEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "VoltBar Profile"
    static var defaultQuery = ProfileQuery()

    var id: String
    var name: String
    var summary: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(summary)")
    }

    init(_ p: VoltBarProfile) {
        id = p.id.uuidString
        name = p.name
        summary = p.summary
    }
}

@available(macOS 13.0, *)
struct ProfileQuery: EntityQuery {
    /// Read straight from profiles.json so the list is right even before the app has finished launching.
    private func all() -> [ProfileEntity] {
        guard let d = try? Data(contentsOf: ProfileStore.fileURL),
              let list = try? JSONDecoder().decode([VoltBarProfile].self, from: d) else { return [] }
        return list.map(ProfileEntity.init)
    }

    func entities(for identifiers: [ProfileEntity.ID]) async throws -> [ProfileEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ProfileEntity] { all() }
}

@available(macOS 13.0, *)
struct ApplyProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply VoltBar Profile"
    static var description = IntentDescription("Applies a VoltBar profile: its undervolting, fan and graphics settings.")

    @Parameter(title: "Profile") var profile: ProfileEntity

    static var parameterSummary: some ParameterSummary { Summary("Apply \(\.$profile)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let m = try ShortcutsSupport.model()
        guard m.applyProfile(named: profile.id) else { throw VoltBarIntentError.profileMissing }
        return .result()
    }
}

// MARK: - Graphics

@available(macOS 13.0, *)
enum GraphicsModeAppEnum: String, AppEnum {
    case integrated, dynamic, discrete

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Graphics Mode"
    static var caseDisplayRepresentations: [GraphicsModeAppEnum: DisplayRepresentation] = [
        .integrated: "Integrated",
        .dynamic: "Dynamic",
        .discrete: "Discrete",
    ]
}

@available(macOS 13.0, *)
struct SetGraphicsModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Graphics Mode"
    static var description = IntentDescription("Chooses the integrated GPU, the discrete GPU or automatic switching on dual-GPU MacBook Pros.")

    @Parameter(title: "Mode", default: .integrated) var mode: GraphicsModeAppEnum

    static var parameterSummary: some ParameterSummary { Summary("Set graphics to \(\.$mode)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let m = try ShortcutsSupport.model()
        guard m.features.gpu, m.gpu.available else { throw VoltBarIntentError.unavailable("Graphics switching isn't available on this Mac.") }
        m.gpu.apply(GPUMode(rawValue: mode.rawValue) ?? .dynamic, confirmed: true)
        return .result()
    }
}

// MARK: - Fans and undervolting

@available(macOS 13.0, *)
struct SetFanControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Set VoltBar Fan Control"
    static var description = IntentDescription("Turns VoltBar's fan control on (your fan modes) or off (macOS controls the fans).")

    @Parameter(title: "Fan control", default: true) var enabled: Bool

    static var parameterSummary: some ParameterSummary { Summary("Turn fan control \(\.$enabled)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let m = try ShortcutsSupport.model()
        guard m.features.fans else { throw VoltBarIntentError.unavailable("Fan control is turned off in VoltBar's settings.") }
        m.updateFans(immediate: true) { $0.enabled = enabled }
        return .result()
    }
}

@available(macOS 13.0, *)
struct SetUndervoltingIntent: AppIntent {
    static var title: LocalizedStringResource = "Set VoltBar Undervolting"
    static var description = IntentDescription("Turns the saved undervolting profile on or off (off restores factory voltages).")

    @Parameter(title: "Undervolting", default: true) var enabled: Bool

    static var parameterSummary: some ParameterSummary { Summary("Turn undervolting \(\.$enabled)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let m = try ShortcutsSupport.model()
        guard m.features.undervolting else { throw VoltBarIntentError.unavailable("Undervolting is turned off in VoltBar's settings.") }
        m.setUndervolting(enabled)
        return .result()
    }
}

@available(macOS 13.0, *)
struct OpenMonitorIntent: AppIntent {
    static var title: LocalizedStringResource = "Open VoltBar Monitor"
    static var description = IntentDescription("Opens the Monitor window with live CPU, memory and fan charts.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let url = URL(string: "voltbar://monitor") else { return .result() }
        NSWorkspace.shared.open(url)
        return .result()
    }
}
