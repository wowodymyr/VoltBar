// VoltBar.app — fan control views: menu section, per-fan editor and curve editor.

import SwiftUI
import AppKit

/// "fanblades" exists from SF Symbols 4 (macOS 13); fall back to "wind" on macOS 12.
let fanSymbolName: String = NSImage(systemSymbolName: "fanblades", accessibilityDescription: nil) != nil ? "fanblades" : "wind"

extension FanMode {
    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .fixed: return "Fixed"
        case .linear: return "Linear"
        case .curve: return "Curve"
        }
    }
}

private func sensorName(_ key: String, _ sensors: [SensorInfo]) -> String {
    sensors.first { $0.key == key }?.name ?? key
}

/// One-line description of what a fan is doing, e.g. "Curve · CPU package".
func fanSummary(_ s: FanSetting, enabled: Bool, sensors: [SensorInfo]) -> String {
    guard enabled else { return "Automatic" }
    switch s.mode {
    case .auto: return "Automatic"
    case .fixed: return "Fixed · \(Int(s.fixedRPM)) rpm"
    case .linear: return "Linear · \(sensorName(s.sensor, sensors))"
    case .curve: return "Curve · \(sensorName(s.sensor, sensors))"
    }
}

// MARK: - Menu (popover) section

struct FansMenuSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var live: LiveMetrics
    let openFanSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Fans", systemImage: fanSymbolName).font(.headline)
                Spacer()
                Toggle("Fan control", isOn: Binding(get: { model.fanDraft.enabled },
                                                    set: { v in model.updateFans(immediate: true) { $0.enabled = v } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(live.fans.isEmpty)
                    .help("Let VoltBar control the fans")
            }
            if live.fans.isEmpty {
                Text("No fans reported by the SMC.").font(.callout)
            } else {
                ForEach(live.fans, id: \.index) { f in
                    HStack(spacing: 8) {
                        Text(f.name).font(.callout.weight(.medium))
                        Spacer()
                        Button(fanSummary(model.fanSetting(f.index), enabled: model.fanDraft.enabled, sensors: live.sensors)) {
                            openFanSettings()
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                        .help("Change in Settings → Fans")
                        Text("\(Int(f.rpm)) rpm")
                            .font(.callout.weight(.semibold)).monospacedDigit()
                            .frame(width: 76, alignment: .trailing)
                    }
                }
            }
            if model.fanDraft.enabled, let m = model.status?.fanMessage { Notice(text: m) }
            if let e = model.fanError { Notice(text: e, kind: .danger) }
        }
    }
}

// MARK: - Settings: Fans tab

struct FansSettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var live: LiveMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: fanSymbolName).font(.system(size: 28)).frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fan Control").font(.headline)
                    Text("When off, macOS controls the fans as usual. VoltBar gives control back to the system before sleep and when it quits. Whatever the mode, fans run at full speed if the CPU reaches \(Int(VB.fanFailsafeTemp)) °C.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("Fan control", isOn: Binding(get: { model.fanDraft.enabled },
                                                    set: { v in model.updateFans(immediate: true) { $0.enabled = v } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(live.fans.isEmpty)
            }
            .frame(width: 796)
            if !model.connected {
                Notice(text: "The VoltBar daemon is not responding.", kind: .danger)
            } else if live.fans.isEmpty {
                Notice(text: "No fans reported by the SMC on this Mac.")
            } else {
                if let m = model.status?.fanMessage, model.fanDraft.enabled { Notice(text: m) }
                if let e = model.fanError { Notice(text: e, kind: .danger) }
                LazyVGrid(columns: [GridItem(.fixed(390), spacing: 16, alignment: .top),
                                    GridItem(.fixed(390), spacing: 16, alignment: .top)],
                          alignment: .leading, spacing: 16) {
                    ForEach(live.fans, id: \.index) { f in
                        FanEditor(fan: f, live: live)
                    }
                }
                .disabled(!model.fanDraft.enabled)
                .opacity(model.fanDraft.enabled ? 1 : 0.55)
            }
        }
        .padding(20)
        .fixedSize()
    }
}

struct FanEditor: View {
    @EnvironmentObject var model: AppModel
    let fan: FanInfo
    @ObservedObject var live: LiveMetrics

    private var setting: FanSetting { model.fanSetting(fan.index) }
    private var sensorTemp: Double? { live.sensors.first { $0.key == setting.sensor }?.value }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Mode", selection: Binding(get: { setting.mode },
                                                  set: { m in model.updateFan(fan.index, immediate: true) { $0.mode = m } })) {
                    ForEach(FanMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch setting.mode {
                case .auto:
                    Text("Speed is controlled by macOS.").font(.callout)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                case .fixed:
                    RPMSlider(title: "Speed", value: setting.fixedRPM, range: fan.minRPM...fan.maxRPM) { v in
                        model.updateFan(fan.index) { $0.fixedRPM = v }
                    }
                case .linear:
                    sensorPicker
                    TempSlider(title: "Minimum speed at", value: setting.linearMinTemp) { v in
                        model.updateFan(fan.index) { s in s.linearMinTemp = min(v, s.linearMaxTemp - 1) }
                    }
                    TempSlider(title: "Maximum speed at", value: setting.linearMaxTemp) { v in
                        model.updateFan(fan.index) { s in s.linearMaxTemp = max(v, s.linearMinTemp + 1) }
                    }
                    Text("\(Int(fan.minRPM)) rpm at \(Int(setting.linearMinTemp)) °C and below, rising in a straight line to \(Int(fan.maxRPM)) rpm at \(Int(setting.linearMaxTemp)) °C.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                case .curve:
                    sensorPicker
                    CurveEditor(points: setting.curve.isEmpty ? FanSetting.defaultCurve(min: fan.minRPM, max: fan.maxRPM) : setting.curve,
                                minRPM: fan.minRPM, maxRPM: fan.maxRPM,
                                currentTemp: sensorTemp, currentRPM: fan.rpm) { pts in
                        model.updateFan(fan.index, immediate: true) { $0.curve = pts }
                    }
                    HStack {
                        Text("Drag the points to shape the curve.").font(.callout)
                        Spacer()
                        Button("Reset Curve") {
                            model.updateFan(fan.index, immediate: true) {
                                $0.curve = FanSetting.defaultCurve(min: fan.minRPM, max: fan.maxRPM)
                            }
                        }
                    }
                }
            }
            .padding(6)
        } label: {
            HStack {
                Text(fan.name).font(.headline)
                Spacer()
                Text("\(Int(fan.rpm)) rpm").font(.callout.weight(.semibold)).monospacedDigit()
            }
        }
    }

    private var sensorPicker: some View {
        Picker("Sensor", selection: Binding(get: { setting.sensor },
                                            set: { k in model.updateFan(fan.index, immediate: true) { $0.sensor = k } })) {
            ForEach(live.sensors, id: \.key) { s in
                Text(s.name + (s.value.map { String(format: " — %.0f °C", $0) } ?? "")).tag(s.key)
            }
        }
        .pickerStyle(.menu)
    }
}

/// Slider whose value is kept locally while dragging; `commit` is called with rounded values.
struct RPMSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let commit: (Double) -> Void
    @State private var drag: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text("\(Int(drag ?? value)) rpm").font(.callout.weight(.semibold)).monospacedDigit()
            }
            Slider(value: Binding(get: { drag ?? value }, set: { drag = ($0 / 50).rounded() * 50 }), in: range,
                   onEditingChanged: { editing in
                       if !editing, let d = drag { commit(min(range.upperBound, max(range.lowerBound, d))); drag = nil }
                   })
                .controlSize(.small)
        }
    }
}

struct TempSlider: View {
    let title: String
    let value: Double
    let commit: (Double) -> Void
    @State private var drag: Double? = nil
    static let range: ClosedRange<Double> = 30...100

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text("\(Int(drag ?? value)) °C").font(.callout.weight(.semibold)).monospacedDigit()
            }
            Slider(value: Binding(get: { drag ?? value }, set: { drag = $0.rounded() }), in: Self.range,
                   onEditingChanged: { editing in
                       if !editing, let d = drag { commit(d); drag = nil }
                   })
                .controlSize(.small)
        }
    }
}

// MARK: - Curve editor

/// Temperature (x) → RPM (y) graph with draggable points. Points keep their order:
/// a point can't move past its neighbours, and stays within the fan's RPM range.
struct CurveEditor: View {
    let points: [FanCurvePoint]
    let minRPM: Double
    let maxRPM: Double
    let currentTemp: Double?
    let currentRPM: Double?
    let commit: ([FanCurvePoint]) -> Void

    @State private var dragging: [FanCurvePoint]? = nil
    @State private var activeIndex: Int? = nil

    private let tempRange: ClosedRange<Double> = 30...100
    private let inset = EdgeInsets(top: 8, leading: 44, bottom: 20, trailing: 8)

    private var shown: [FanCurvePoint] { (dragging ?? points).sorted { $0.temp < $1.temp } }

    var body: some View {
        GeometryReader { g in
            let plot = CGRect(x: inset.leading, y: inset.top,
                              width: g.size.width - inset.leading - inset.trailing,
                              height: g.size.height - inset.top - inset.bottom)
            ZStack(alignment: .topLeading) {
                grid(plot)
                curvePath(plot, closed: true).fill(Color.accentColor.opacity(0.12))
                curvePath(plot, closed: false).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                if let t = currentTemp, tempRange.contains(t) {
                    let x = xPos(t, plot)
                    Path { p in p.move(to: CGPoint(x: x, y: plot.minY)); p.addLine(to: CGPoint(x: x, y: plot.maxY)) }
                        .stroke(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    if let r = currentRPM {
                        Circle().fill(Color.primary).frame(width: 7, height: 7)
                            .position(x: x, y: yPos(min(maxRPM, max(minRPM, r)), plot))
                            .help(String(format: "Now: %.0f °C, %.0f rpm", t, r))
                    }
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { i, pt in
                    Circle()
                        .fill(Color.accentColor)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                        .frame(width: activeIndex == i ? 14 : 11, height: activeIndex == i ? 14 : 11)
                        .position(x: xPos(pt.temp, plot), y: yPos(pt.rpm, plot))
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("curve"))
                            .onChanged { v in move(i, to: v.location, plot) }
                            .onEnded { _ in
                                if let d = dragging { commit(d.sorted { $0.temp < $1.temp }) }
                                dragging = nil
                                activeIndex = nil
                            })
                        .help(String(format: "%.0f °C → %.0f rpm", pt.temp, pt.rpm))
                }
                if let i = activeIndex, i < shown.count {
                    let pt = shown[i]
                    Text(String(format: "%.0f °C · %.0f rpm", pt.temp, pt.rpm))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .windowBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.2)))
                        .position(x: min(plot.maxX - 50, max(plot.minX + 50, xPos(pt.temp, plot))),
                                  y: max(plot.minY + 10, yPos(pt.rpm, plot) - 18))
                }
            }
            .coordinateSpace(name: "curve")
        }
        .frame(height: 180)
    }

    // MARK: Geometry

    private func xPos(_ t: Double, _ r: CGRect) -> CGFloat {
        r.minX + CGFloat((t - tempRange.lowerBound) / (tempRange.upperBound - tempRange.lowerBound)) * r.width
    }

    private func yPos(_ rpm: Double, _ r: CGRect) -> CGFloat {
        r.maxY - CGFloat((rpm - minRPM) / max(1, maxRPM - minRPM)) * r.height
    }

    private func move(_ i: Int, to p: CGPoint, _ r: CGRect) {
        var pts = dragging ?? shown
        guard i < pts.count else { return }
        activeIndex = i
        let lo = i > 0 ? pts[i - 1].temp + 1 : tempRange.lowerBound
        let hi = i < pts.count - 1 ? pts[i + 1].temp - 1 : tempRange.upperBound
        let t = tempRange.lowerBound + Double((p.x - r.minX) / r.width) * (tempRange.upperBound - tempRange.lowerBound)
        let rpm = minRPM + Double((r.maxY - p.y) / r.height) * (maxRPM - minRPM)
        pts[i].temp = min(hi, max(lo, t.rounded()))
        pts[i].rpm = min(maxRPM, max(minRPM, (rpm / 50).rounded() * 50))
        dragging = pts
    }

    private func curvePath(_ r: CGRect, closed: Bool) -> Path {
        Path { p in
            let pts = shown
            guard let first = pts.first, let last = pts.last else { return }
            // Flat before the first and after the last point, like the controller does.
            p.move(to: CGPoint(x: r.minX, y: yPos(first.rpm, r)))
            for pt in pts { p.addLine(to: CGPoint(x: xPos(pt.temp, r), y: yPos(pt.rpm, r))) }
            p.addLine(to: CGPoint(x: r.maxX, y: yPos(last.rpm, r)))
            if closed {
                p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                p.closeSubpath()
            }
        }
    }

    @ViewBuilder
    private func grid(_ r: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.primary.opacity(0.25))
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
        Path { p in
            for f in [0.25, 0.5, 0.75] {
                let y = r.maxY - r.height * CGFloat(f)
                p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
            }
            for t in stride(from: 40.0, through: 90.0, by: 10) {
                let x = xPos(t, r)
                p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
            }
        }
        .stroke(Color.primary.opacity(0.08))
        ForEach(Array(stride(from: 30.0, through: 100.0, by: 10)), id: \.self) { t in
            Text("\(Int(t))°").font(.caption2).monospacedDigit()
                .position(x: xPos(t, r), y: r.maxY + 10)
        }
        Text("\(Int(maxRPM))").font(.caption2).monospacedDigit()
            .frame(width: 40, alignment: .trailing)
            .position(x: r.minX - 24, y: r.minY + 4)
        Text("\(Int(minRPM))").font(.caption2).monospacedDigit()
            .frame(width: 40, alignment: .trailing)
            .position(x: r.minX - 24, y: r.maxY - 4)
        Text("rpm").font(.caption2)
            .frame(width: 40, alignment: .trailing)
            .position(x: r.minX - 24, y: r.midY)
    }
}
