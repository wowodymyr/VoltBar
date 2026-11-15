// VoltBar.app — SwiftUI views: compact menu-bar popover and the full settings window.
// All text uses the primary label color; meaning is carried by icons, not by gray/colored text.

import SwiftUI
import AppKit

// MARK: - Building blocks

struct Notice: View {
    enum Kind { case info, success, warning, danger }
    let text: String
    var kind: Kind = .warning

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).foregroundColor(tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var icon: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "exclamationmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .danger: return .red
        }
    }
}

struct HeaderView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").foregroundColor(.yellow)
                Text("VoltBar").font(.headline)
                Spacer()
            }
            let cpu = [model.cpuModel, model.macModel].filter { !$0.isEmpty }.joined(separator: " · ")
            if !cpu.isEmpty {
                Label(cpu, systemImage: "cpu")
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
    }
}

struct MetricsView: View {
    @ObservedObject var live: LiveMetrics

    var body: some View {
        HStack {
            metric("Temperature", live.tempC.map { "\($0) °C" } ?? "—")
            Spacer()
            metric("Frequency", live.freqGHz.map { String(format: "%.1f GHz", $0) } ?? "—")
            Spacer()
            metric("Package", live.packageW.map { String(format: "%.1f W", $0) } ?? "—")
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption)
            Text(value).font(.system(.body, design: .rounded).weight(.medium)).monospacedDigit()
        }
    }
}

struct StatusNotes: View {
    @EnvironmentObject var model: AppModel
    let status: Status

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !status.undervoltAvailable {
                Notice(text: "OC Mailbox is not responding (OC_Locked): voltage offsets are unavailable, but Turbo and power limits still work.")
            }
            ConfirmCountdown(live: model.live)
            if let m = status.message {
                Notice(text: m)
            }
        }
    }
}

struct ConfirmCountdown: View {
    @ObservedObject var live: LiveMetrics

    var body: some View {
        if let sec = live.pendingConfirmSeconds, sec > 0 {
            Notice(text: "Stability check: \(sec / 60):\(String(format: "%02d", sec % 60)) left. If the system crashes or restarts before then, the profile will not be applied on next boot.", kind: .info)
        }
    }
}

/// Shows a connection / kext problem instead of the content, or the content with the current status.
struct StatusGate<Content: View>: View {
    @EnvironmentObject var model: AppModel
    @ViewBuilder let content: (Status) -> Content

    var body: some View {
        if !model.connected {
            Notice(text: "The VoltBar daemon is not responding. Reinstall VoltBar.pkg.\n\(model.connectionError ?? "")", kind: .danger)
        } else if let s = model.status, !s.kextLoaded {
            Notice(text: "The VoltBarMSR driver is not loaded yet. If macOS asks to allow a blocked extension, approve it in System Settings → Privacy & Security and restart. Alternatively load VoltBarMSR.kext via OpenCore (Kernel → Add).")
        } else if let s = model.status {
            content(s)
        } else {
            HStack { ProgressView().controlSize(.small); Text("Connecting…").font(.callout) }
        }
    }
}

struct OffsetRow: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    let current: Double?

    /// Slider position while it is being dragged. Kept local so a drag re-renders only this row;
    /// the model (and the rest of the menu) is updated once, when the drag ends.
    @State private var dragValue: Double? = nil

    private var value: Int { dragValue.map { Int($0.rounded()) } ?? model.draft.offsets[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(VB.planeNames[index]).font(.callout.weight(.medium))
                Spacer()
                if let c = current {
                    Text(String(format: "now %+.0f", c.rounded() == 0 ? 0 : c))
                        .font(.callout).monospacedDigit()
                }
                Button { model.setOffset(index, 0) } label: {
                    Text(value == 0 ? "0 mV" : String(format: "%+d mV", value))
                        .font(.callout.weight(.semibold)).monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .help("Click to set 0 mV")
            }
            HStack(spacing: 4) {
                Button { model.setOffset(index, value - 1) } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                // No `step:` — on macOS it turns into hundreds of tick marks and makes the row take seconds to build.
                // Values are rounded in the binding instead.
                Slider(value: Binding(get: { dragValue ?? Double(model.draft.offsets[index]) },
                                      set: { v in
                                          let r = v.rounded()
                                          if dragValue != r { dragValue = r }
                                      }),
                       in: Double(model.offsetRange.lowerBound)...Double(model.offsetRange.upperBound),
                       onEditingChanged: { editing in
                           if !editing, let v = dragValue {
                               model.setOffset(index, Int(v))
                               dragValue = nil
                           }
                       })
                    .controlSize(.small)
                    // Center mark at 0 mV (the range is symmetric, so 0 is exactly in the middle).
                    .overlay(Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 1.5, height: 10).allowsHitTesting(false))
                Button { model.setOffset(index, value + 1) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
            }
        }
    }
}

struct OffsetWarnings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.draft.damageMode {
            Notice(text: "Extended range −500…+500 mV. Large offsets can freeze the system or damage the CPU!", kind: .danger)
        } else if model.draft.offsets.contains(where: { $0 > 0 }) {
            Notice(text: "Positive offset = overvolting: more heat and power draw, use with care.")
        }
    }
}

struct TurboRow: View {
    @EnvironmentObject var model: AppModel
    let status: Status

    var body: some View {
        HStack {
            Text("Turbo Boost").font(.headline)
            Spacer()
            Picker("", selection: Binding<Int>(
                get: { model.draft.manageTurbo ? (model.draft.turbo ? 1 : 2) : 0 },
                set: { v in
                    model.draft.manageTurbo = v != 0
                    model.draft.turbo = v != 2
                })) {
                Text("Default").tag(0)
                Text("On").tag(1)
                Text("Off").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
        }
        .help("Now: " + (status.turboEnabled.map { $0 ? "enabled" : "disabled" } ?? "—"))
    }
}

struct PowerSection: View {
    @EnvironmentObject var model: AppModel
    let status: Status

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Power limits").font(.headline)
                Spacer()
                Toggle("Custom", isOn: $model.draft.managePower)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            if status.powerLocked == true {
                Notice(text: "MSR 0x610 is locked by firmware — PL1/PL2 cannot be changed.")
            }
            Text("Now: PL1 \(fmtW(status.pl1)), PL2 \(fmtW(status.pl2)) · factory \(fmtW(status.factoryPL1)) / \(fmtW(status.factoryPL2))")
                .font(.callout)
            if model.draft.managePower {
                PowerRow(title: "PL1 (long term)", value: Binding(
                    get: { model.draft.pl1 },
                    set: { model.draft.pl1 = $0; if model.draft.pl2 < $0 { model.draft.pl2 = $0 } }))
                PowerRow(title: "PL2 (short term)", value: Binding(
                    get: { model.draft.pl2 },
                    set: { model.draft.pl2 = max($0, model.draft.pl1) }))
            }
        }
        .disabled(status.powerLocked == true)
    }

    private func fmtW(_ v: Double?) -> String {
        guard let v = v else { return "—" }
        return v == v.rounded() ? "\(Int(v)) W" : String(format: "%.2f W", v)
    }
}

struct PowerRow: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text("\(Int(value)) W").font(.callout.weight(.semibold)).monospacedDigit()
            }
            HStack(spacing: 4) {
                Button { value = max(VB.powerRange.lowerBound, value - 1) } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: VB.powerRange)
                    .controlSize(.small)
                Button { value = min(VB.powerRange.upperBound, value + 1) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
            }
        }
    }
}

struct ActionButtons: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Reset") { model.reset() }
                    .help("Restore factory values and disable the profile")
                if model.isDirty {
                    Button("Revert changes") { model.revertDraft() }
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Save") { model.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || !model.isDirty)
            }
            if let t = model.resultText {
                Notice(text: t, kind: model.resultIsError ? .danger : .success)
            }
        }
    }
}

/// Section header used by Settings tabs: big icon, title, description and the module's on/off switch.
struct FeatureHeader: View {
    let symbol: String
    let title: String
    let description: String
    let isOn: Binding<Bool>
    var switchDisabled = false
    var width: CGFloat? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 28)).frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(description).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(switchDisabled)
        }
        .frame(width: width)
    }
}

extension AppModel {
    /// On = the saved profile is applied and maintained by the daemon.
    var undervoltingBinding: Binding<Bool> {
        Binding(get: { self.status?.enforcing ?? false }, set: { self.setUndervolting($0) })
    }
}

struct ProfileBadge: View {
    let active: Bool
    var body: some View {
        Text(active ? "Profile active" : "Profile off")
            .font(.callout)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(active ? Color.green.opacity(0.3) : Color.primary.opacity(0.1)))
    }
}

// MARK: - Compact popover (menu bar)

struct CompactMenuView: View {
    @EnvironmentObject var model: AppModel
    let openSettings: (SettingsTab) -> Void
    var openMonitor: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HeaderView()
            if model.connected { MetricsView(live: model.live) }
            Divider()

            // Undervolting
            if model.features.undervolting {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Undervolting", systemImage: "bolt").font(.headline)
                    Spacer()
                    Toggle("Undervolting", isOn: model.undervoltingBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .disabled(model.status?.kextLoaded != true || (model.status?.saved == nil && !(model.status?.enforcing ?? false)))
                        .help(model.status?.saved == nil ? "Save a profile first" : "Apply the saved profile")
                }
                StatusGate { s in
                    VStack(alignment: .leading, spacing: 8) {
                        StatusNotes(status: s)
                        OffsetWarnings()
                        VStack(alignment: .leading, spacing: 6) {
                            OffsetRow(index: 0, current: s.offsets[0])
                            OffsetRow(index: 1, current: s.offsets[1])
                        }
                        .disabled(!s.undervoltAvailable)
                        TurboRow(status: s)
                        ActionButtons()
                    }
                }
            }
            Divider()
            }

            // Fans
            if model.connected && model.features.fans {
                FansMenuSection(live: model.live, openFanSettings: { openSettings(.fans) })
                Divider()
            }

            if !model.features.undervolting && !model.features.fans {
                Text("Undervolting and fan control are turned off. Turn them on in Settings → General.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
            }

            HStack {
                Button("Settings…") { openSettings(model.features.undervolting ? .undervolting : (model.features.fans ? .fans : .general)) }
                    .keyboardShortcut(",", modifiers: .command)
                if model.features.monitoring {
                    Button("Monitor…") { openMonitor() }
                        .keyboardShortcut("m", modifiers: [.command, .option])
                        .help("Live charts of CPU, memory, swap and fans")
                }
                Spacer()
                Button("Quit VoltBar") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}

// MARK: - Settings window (tabs: Undervolting, Fans, General)

enum SettingsTab: Int, CaseIterable {
    case undervolting, fans, general

    var title: String {
        switch self {
        case .undervolting: return "Undervolting"
        case .fans: return "Fans"
        case .general: return "General"
        }
    }

    var symbol: String {
        switch self {
        case .undervolting: return "bolt"
        case .fans: return fanSymbolName
        case .general: return "gearshape"
        }
    }
}

struct UndervoltSettingsView: View {
    @EnvironmentObject var model: AppModel

    private let column: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FeatureHeader(symbol: "bolt", title: "Undervolting",
                          description: "Lowers CPU and GPU voltage to run cooler and hold turbo longer. Changes are applied with Save; a new profile has to survive \(VB.confirmSeconds / 60) minutes before it's used at boot, and a crash or hang turns it off automatically. Switching off restores factory voltages and keeps your profile.",
                          isOn: model.undervoltingBinding,
                          switchDisabled: model.status?.kextLoaded != true || (model.status?.saved == nil && !(model.status?.enforcing ?? false)),
                          width: column * 2 + 21)
            StatusGate { s in
                VStack(alignment: .leading, spacing: 12) {
                    MetricsView(live: model.live).frame(width: column)
                    StatusNotes(status: s)
                    Divider()
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Voltage Offset").font(.headline)
                                Spacer()
                                Toggle("Damage mode", isOn: Binding(get: { model.draft.damageMode },
                                                                    set: { model.setDamageMode($0) }))
                                    .toggleStyle(.checkbox)
                            }
                            OffsetWarnings()
                            ForEach(0..<6, id: \.self) { i in
                                OffsetRow(index: i, current: s.offsets[i])
                            }
                        }
                        .disabled(!s.undervoltAvailable)
                        .frame(width: column)
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            TurboRow(status: s)
                            Divider()
                            PowerSection(status: s)
                        }
                        .frame(width: column)
                    }
                    Divider()
                    ActionButtons()
                }
            }
        }
        .padding(20)
        .fixedSize()
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HeaderView()
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Features").font(.headline)
                FeatureToggle(symbol: "bolt", title: "Undervolting",
                              detail: "Voltage offsets, Turbo Boost and power limits. Off: factory settings.",
                              isOn: $model.features.undervolting)
                FeatureToggle(symbol: fanSymbolName, title: "Fan Control",
                              detail: "Custom fan modes. Off: macOS controls the fans.",
                              isOn: $model.features.fans)
                FeatureToggle(symbol: "chart.xyaxis.line", title: "Monitoring",
                              detail: "Monitor window and live values in the menu bar. Off: nothing is sampled.",
                              isOn: $model.features.monitoring)
            }
            Divider()
            MenuBarSettings(live: model.live)
            Divider()
            Toggle("Launch VoltBar at login", isOn: Binding(get: { model.launchAtLogin },
                                                            set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("About").font(.headline)
                Text("VoltBar \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")"
                     + (model.status.map { " · daemon \($0.daemonVersion)" } ?? "")).font(.callout)
                if let d = model.status?.driver {
                    Text("MSR driver: \(d == VB.ownKextClass ? "VoltBarMSR (built-in)" : d)").font(.callout)
                }
            }
        }
        .padding(20)
        .frame(width: 480, alignment: .leading)
        .fixedSize()
    }
}

struct FeatureToggle: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16)).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption)
            }
            Spacer()
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

/// Menu bar item: icon style, separators and, per metric, nothing / value / graph / both.
struct MenuBarSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var live: LiveMetrics

    private var metrics: [Metric] {
        [.cpuLoad, .cpuTemp, .cpuPower, .cpuFreq, .memory, .swap] + live.fans.compactMap { Metric.fan($0.index) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu Bar").font(.headline)
            HStack {
                Text("Icon")
                Spacer()
                Picker("Icon", selection: Binding(get: { model.menuBarConfig.icon },
                                                  set: { model.menuBarConfig.icon = $0 })) {
                    ForEach(MenuBarIconStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            if model.features.monitoring {
            Toggle("Separators between items", isOn: Binding(get: { model.menuBarConfig.separators },
                                                             set: { model.menuBarConfig.separators = $0 }))
                .toggleStyle(.checkbox)
            ForEach(metrics, id: \.self) { m in
                HStack {
                    Text(m.title(fans: live.fans))
                    Spacer()
                    Picker(m.title(fans: live.fans), selection: Binding(get: { model.menuBarConfig.display(m) },
                                                                        set: { model.menuBarConfig.items[m] = $0 })) {
                        ForEach(MenuBarDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
            }
            } else {
                Text("Turn on Monitoring to show live values and graphs in the menu bar.").font(.caption)
            }
            if model.menuBarConfig.icon == .hidden && !(model.menuBarConfig.hasItems && model.features.monitoring) {
                Notice(text: "With nothing else shown, the icon stays visible so VoltBar can still be opened.", kind: .info)
            }
        }
    }
}
