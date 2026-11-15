// VoltBar.app — graphics switching views: menu section and the Graphics settings tab.

import SwiftUI

let gpuSymbolName = "display"

extension GPUMode {
    var detail: String {
        switch self {
        case .integrated: return "Always use the integrated GPU. Longest battery life and least heat; apps asking for the discrete GPU are switched back."
        case .dynamic: return "macOS switches between the GPUs automatically (the default)."
        case .discrete: return "Always use the discrete GPU. Best graphics performance, more heat and power."
        }
    }
}

/// Mode picker with the "apps may crash" confirmation used by both the menu and Settings.
struct GPUModePicker: View {
    @ObservedObject var gpu: GPUSwitcher
    @State private var pending: GPUMode? = nil

    var body: some View {
        Picker("Graphics", selection: Binding(get: { gpu.settings.mode }, set: { choose($0) })) {
            ForEach(GPUMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .alert("Switch to the integrated GPU?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Switch", role: .destructive) { if let m = pending { gpu.apply(m, confirmed: true) }; pending = nil }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("These apps are using the discrete GPU and may quit unexpectedly: "
                 + gpu.appsAtRisk(for: .integrated).map(\.name).joined(separator: ", ") + ".")
        }
    }

    private func choose(_ m: GPUMode) {
        if !gpu.appsAtRisk(for: m).isEmpty { pending = m } else { gpu.apply(m) }
    }
}

struct GPUMenuSection: View {
    @ObservedObject var gpu: GPUSwitcher
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Graphics", systemImage: gpuSymbolName).font(.headline)
                Spacer()
                Button(gpu.activeName) { openSettings() }
                    .buttonStyle(.link)
                    .font(.callout)
                    .help("Active GPU — open Settings → Graphics")
            }
            GPUModePicker(gpu: gpu)
            let users = gpu.dependents.map(\.name)
            if !users.isEmpty {
                Text((gpu.usingIntegrated ? "Wants the discrete GPU: " : "Using the discrete GPU: ") + users.joined(separator: ", "))
                    .font(.callout)
                    .lineLimit(2)
            }
            if let m = gpu.message { Notice(text: m) }
        }
    }
}

struct GPUSettingsView: View {
    @ObservedObject var gpu: GPUSwitcher

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: gpuSymbolName).font(.system(size: 28)).frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Graphics Switching").font(.headline)
                    Text("Choose which GPU this MacBook Pro uses: \(gpu.integratedName) or \(gpu.discreteName). Forcing the integrated GPU saves battery and heat; an external display always needs the discrete one.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Mode").font(.headline)
                        Spacer()
                        GPUModePicker(gpu: gpu).frame(width: 300)
                    }
                    Text(gpu.settings.mode.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    HStack(spacing: 8) {
                        Circle().fill(gpu.usingIntegrated ? Color.green : Color.orange).frame(width: 8, height: 8)
                        Text("Now using: \(gpu.activeName)").font(.callout.weight(.medium))
                        Spacer()
                        Text(gpu.usingIntegrated ? "Integrated" : "Discrete").font(.callout)
                    }
                    if let m = gpu.message { Notice(text: m) }
                }
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(gpu.usingIntegrated ? "Apps asking for the discrete GPU" : "Apps using the discrete GPU").font(.headline)
                    if gpu.dependents.isEmpty {
                        Text("None.").font(.callout)
                    } else {
                        ForEach(gpu.dependents) { p in
                            HStack {
                                Image(systemName: p.pid == 0 ? "display.2" : "app")
                                Text(p.name).font(.callout)
                                Spacer()
                                if p.pid > 0 { Text("PID " + String(p.pid)).font(.callout).monospacedDigit() }
                            }
                        }
                    }
                    Text(gpu.usingIntegrated
                         ? "These apps would switch the Mac to the discrete GPU in dynamic mode."
                         : "Switching to integrated only while these apps run may make them quit.")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Notify when the active GPU changes", isOn: Binding(
                    get: { gpu.settings.notifyOnChange },
                    set: { v in gpu.settings.notifyOnChange = v; if v { gpu.requestNotificationPermission() } }))
                Toggle("Dot on the menu bar icon while the discrete GPU is active", isOn: Binding(
                    get: { gpu.settings.menuBarDot }, set: { gpu.settings.menuBarDot = $0 }))
            }
            .toggleStyle(.checkbox)
            Text("From the command line: open -a VoltBar --args --integrated | --dynamic | --discrete").font(.caption)
        }
        .padding(20)
        .frame(width: 560, alignment: .leading)
        .fixedSize()
    }
}
