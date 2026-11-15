// VoltBar.app — profiles UI: menu section and the Profiles settings tab.

import SwiftUI

struct ProfilesMenuSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: ProfileStore
    let openSettings: () -> Void

    var body: some View {
        HStack {
            Label("Profile", systemImage: "square.stack.3d.up").font(.headline)
            Spacer()
            Menu {
                ForEach(store.profiles) { p in
                    Button { model.applyProfile(p) } label: {
                        Label(p.name, systemImage: p.id == store.activeID ? "checkmark" : p.symbol)
                    }
                }
                if !store.profiles.isEmpty { Divider() }
                Button("Edit Profiles…") { openSettings() }
            } label: {
                Text(store.profiles.first { $0.id == store.activeID }?.name ?? (store.profiles.isEmpty ? "None yet" : "Choose"))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

struct ProfilesSettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: ProfileStore
    @State private var selection: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 28)).frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Profiles").font(.headline)
                    Text("Save undervolting, fan and graphics settings as a profile and switch between them in one click — from the menu, the Shortcuts app, a voltbar:// URL or the command line. A profile only changes the parts it includes.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                // List
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(store.profiles) { p in
                            HStack {
                                Image(systemName: p.symbol).frame(width: 18)
                                Text(p.name)
                                Spacer()
                                if p.id == store.activeID { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                            }
                            .tag(p.id)
                        }
                    }
                    .frame(width: 200, height: 250)
                    Divider()
                    HStack(spacing: 0) {
                        Button { addFromCurrent() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                            .help("New profile from the current settings")
                        Button { deleteSelected() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                            .disabled(selection == nil)
                            .help("Delete the selected profile")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(4)
                }
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.2)))

                // Editor
                if let i = store.profiles.firstIndex(where: { $0.id == selection }) {
                    ProfileEditor(profile: $store.profiles[i], isActive: store.profiles[i].id == store.activeID)
                        .frame(width: 400, alignment: .topLeading)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.profiles.isEmpty ? "No profiles yet." : "Select a profile.").font(.callout.weight(.medium))
                        Text("Set things up the way you like (undervolting, fans, graphics), then press + to save them as a profile — for example “Silent”, “Battery” or “Games”.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 400, alignment: .topLeading)
                }
            }

            AutoSwitchBox(power: model.power, store: store)

            GroupBox {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automation").font(.headline)
                    Text("Shortcuts (macOS 13+): “Apply VoltBar Profile”, “Set Graphics Mode”, “Set VoltBar Fan Control”, “Set VoltBar Undervolting”.").font(.caption)
                    Text("Any macOS: “Open URLs” with voltbar://profile/<name> · Terminal: voltbarctl profile <name>").font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
        .padding(20)
        .frame(width: 650, alignment: .leading)
        .fixedSize()
        .onAppear { if selection == nil { selection = store.activeID ?? store.profiles.first?.id } }
    }

    private func addFromCurrent() {
        let p = model.captureProfile(named: "New Profile")
        store.profiles.append(p)
        selection = p.id
    }

    private func deleteSelected() {
        guard let id = selection, let i = store.profiles.firstIndex(where: { $0.id == id }) else { return }
        store.profiles.remove(at: i)
        if store.activeID == id { store.activeID = nil }
        selection = store.profiles.indices.contains(i) ? store.profiles[i].id : store.profiles.last?.id
    }
}

struct ProfileEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var profile: VoltBarProfile
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Menu {
                    ForEach(VoltBarProfile.symbols, id: \.self) { s in
                        Button { profile.symbol = s } label: { Label(s, systemImage: s) }
                    }
                } label: { Image(systemName: profile.symbol) }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Icon")
                TextField("Name", text: $profile.name).textFieldStyle(.roundedBorder)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if model.features.undervolting {
                        PartRow(title: "Undervolting", symbol: "bolt",
                                included: Binding(get: { profile.undervoltEnabled != nil },
                                                  set: { on in
                                                      if on {
                                                          let c = model.captureProfile(named: "x")
                                                          profile.undervolt = c.undervolt ?? model.draft
                                                          profile.undervoltEnabled = c.undervoltEnabled ?? true
                                                      } else { profile.undervolt = nil; profile.undervoltEnabled = nil }
                                                  }),
                                detail: undervoltDetail)
                    }
                    if model.features.fans {
                        PartRow(title: "Fans", symbol: fanSymbolName,
                                included: Binding(get: { profile.fans != nil },
                                                  set: { profile.fans = $0 ? model.fanDraft : nil }),
                                detail: fanDetail)
                    }
                    if model.features.gpu && model.gpu.available {
                        HStack {
                            PartRow(title: "Graphics", symbol: gpuSymbolName,
                                    included: Binding(get: { profile.gpuMode != nil },
                                                      set: { profile.gpuMode = $0 ? model.gpu.settings.mode : nil }),
                                    detail: nil)
                            if profile.gpuMode != nil {
                                Picker("Graphics", selection: Binding(get: { profile.gpuMode ?? .dynamic }, set: { profile.gpuMode = $0 })) {
                                    ForEach(GPUMode.allCases, id: \.self) { Text($0.title).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 230)
                            }
                        }
                    }
                }
                .padding(4)
            }

            HStack {
                Button("Update from Current Settings") {
                    let c = model.captureProfile(named: "x")
                    if profile.undervoltEnabled != nil { profile.undervolt = c.undervolt; profile.undervoltEnabled = c.undervoltEnabled }
                    if profile.fans != nil { profile.fans = c.fans }
                    if profile.gpuMode != nil { profile.gpuMode = c.gpuMode }
                }
                .help("Replace the included parts with how things are set right now")
                Spacer()
                Button(isActive ? "Apply Again" : "Apply") { model.applyProfile(profile) }
                    .keyboardShortcut(.defaultAction)
            }
            Text(profile.summary).font(.caption)
        }
    }

    private var undervoltDetail: String? {
        guard let on = profile.undervoltEnabled else { return nil }
        guard on, let s = profile.undervolt else { return "Off (factory voltages)" }
        var d = "CPU \(s.offsets[0]) · GPU \(s.offsets[1]) · Cache \(s.offsets[2]) mV"
        if s.manageTurbo { d += " · Turbo \(s.turbo ? "on" : "off")" }
        if s.managePower { d += " · PL1/PL2 \(Int(s.pl1))/\(Int(s.pl2)) W" }
        return d
    }

    private var fanDetail: String? {
        guard let f = profile.fans else { return nil }
        guard f.enabled else { return "macOS controls the fans" }
        return f.fans.enumerated().map { i, s in
            let name = model.live.fans.first { $0.index == i }?.name ?? "Fan \(i + 1)"
            return "\(name): " + fanSummary(s, enabled: true, sensors: model.live.sensors)
        }.joined(separator: "\n")
    }
}

private struct PartRow: View {
    let title: String
    let symbol: String
    let included: Binding<Bool>
    let detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(isOn: included) {
                Label(title, systemImage: symbol).font(.callout.weight(.medium))
            }
            .toggleStyle(.checkbox)
            Spacer()
            if let d = detail {
                Text(d).font(.caption).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}


/// Profiles applied automatically when the power adapter is connected or disconnected.
struct AutoSwitchBox: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var power: PowerSourceWatcher
    @ObservedObject var store: ProfileStore

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Automatic Switching", systemImage: "powerplug").font(.headline)
                    Spacer()
                    if let src = power.source {
                        Text("Now: \(src.title)").font(.callout)
                    }
                }
                if !model.features.autoProfiles {
                    Text("Turned off — switch on “Automatic Profile Switching” in General.").font(.callout)
                } else if store.profiles.isEmpty {
                    Text("Create a profile first, then choose which one to use on the power adapter and on battery.").font(.callout)
                } else {
                    row("When the power adapter is connected", Binding(get: { power.settings.onAC }, set: { power.settings.onAC = $0 }))
                    row("When running on battery", Binding(get: { power.settings.onBattery }, set: { power.settings.onBattery = $0 }))
                    Toggle("Also apply when VoltBar starts (at login)", isOn: Binding(
                        get: { power.settings.applyAtLaunch }, set: { power.settings.applyAtLaunch = $0 }))
                        .toggleStyle(.checkbox)
                    if let e = power.lastEvent { Text(e).font(.caption) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .disabled(!model.features.autoProfiles)
    }

    private func row(_ title: String, _ selection: Binding<UUID?>) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Picker(title, selection: selection) {
                Text("Do nothing").tag(UUID?.none)
                Divider()
                ForEach(store.profiles) { p in Label(p.name, systemImage: p.symbol).tag(UUID?.some(p.id)) }
            }
            .labelsHidden()
            .frame(width: 200)
        }
    }
}
