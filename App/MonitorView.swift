// VoltBar.app — Monitor window: live charts that can be shown/hidden, reordered (drag a card) and resized
// (drag the corner handle). Charts scroll smoothly between samples when "Smooth" is on.

import SwiftUI
import AppKit

// MARK: - Layout model (persisted)

enum ChartID: String, Codable, CaseIterable, Identifiable {
    case cpuLoad, cpuThreads, cpuFreq, cpuPower, cpuTemp, gpuLoad, gpuTemp, memory, swap, fans
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpuLoad: return "CPU Load"
        case .cpuThreads: return "CPU Threads"
        case .cpuFreq: return "CPU Frequency"
        case .cpuPower: return "CPU Power"
        case .cpuTemp: return "CPU Temperature"
        case .gpuLoad: return "GPU Load"
        case .gpuTemp: return "GPU Temperature"
        case .memory: return "Memory"
        case .swap: return "Swap"
        case .fans: return "Fans"
        }
    }

    /// Metrics drawn in this chart (each is a line with its own colour).
    func metrics(fans: [FanInfo]) -> [Metric] {
        switch self {
        case .cpuThreads: return [.cpuLoad]
        case .fans: return fans.compactMap { Metric.fan($0.index) }
        case .gpuLoad: return AppModel.hasDiscreteGPU ? [.gpuLoadI, .gpuLoadD] : [.gpuLoadI]
        case .gpuTemp: return AppModel.hasDiscreteGPU ? [.gpuTempI, .gpuTempD] : [.gpuTempI]
        default: return metric.map { [$0] } ?? []
        }
    }

    var metric: Metric? {
        switch self {
        case .cpuLoad: return .cpuLoad
        case .cpuFreq: return .cpuFreq
        case .cpuPower: return .cpuPower
        case .cpuTemp: return .cpuTemp
        case .memory: return .memory
        case .swap: return .swap
        case .cpuThreads, .fans, .gpuLoad, .gpuTemp: return nil
        }
    }
}

struct ChartLayoutItem: Codable, Equatable, Identifiable {
    var id: ChartID
    var visible = true
    var span = 1                  // 1 or 2 columns
    var rows = 1                  // 1 or 2 rows

    init(id: ChartID) { self.id = id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ChartID.self, forKey: .id)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        span = min(2, max(1, try c.decodeIfPresent(Int.self, forKey: .span) ?? 1))
        rows = min(2, max(1, try c.decodeIfPresent(Int.self, forKey: .rows) ?? 1))
    }
}

struct MonitorPrefs: Codable, Equatable {
    var smooth = true
    var items: [ChartLayoutItem] = ChartID.allCases.map { ChartLayoutItem(id: $0) }

    static let defaultsKey = "monitorPrefs"

    static func load() -> MonitorPrefs {
        guard let d = UserDefaults.standard.data(forKey: defaultsKey),
              var p = try? JSONDecoder().decode(MonitorPrefs.self, from: d) else { return MonitorPrefs() }
        // Charts added in later versions go to the end.
        for c in ChartID.allCases where !p.items.contains(where: { $0.id == c }) { p.items.append(ChartLayoutItem(id: c)) }
        return p
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.defaultsKey) }
    }
}

// MARK: - Window content

struct MonitorView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var history: MetricsHistory
    @ObservedObject var live: LiveMetrics

    @State private var window = 120
    @State private var dragging: ChartID? = nil

    static let column: CGFloat = 360
    static let spacing: CGFloat = 14
    /// Height of a one-row card.
    static let cell: CGFloat = 196
    static var gridWidth: CGFloat { column * 2 + spacing }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            toolbar
            let placed = placement
            if placed.isEmpty {
                Text("No charts selected. Choose some from the Charts menu.").font(.callout)
                    .frame(width: Self.gridWidth, height: 120)
            } else {
                let gridHeight = placed.map(\.frame.maxY).max() ?? 0
                // Taller than the screen allows: scroll instead of growing the window off-screen.
                let maxHeight = max(300, (NSScreen.main?.visibleFrame.height ?? 900) - 150)
                ScrollView(.vertical, showsIndicators: gridHeight > maxHeight) {
                    ZStack(alignment: .topLeading) {
                        ForEach(placed, id: \.item.id) { p in
                            card(p.item)
                                .frame(width: p.frame.width, height: p.frame.height)
                                .offset(x: p.frame.minX, y: p.frame.minY)
                        }
                    }
                    .frame(width: Self.gridWidth, height: gridHeight, alignment: .topLeading)
                }
                .frame(width: Self.gridWidth + 16, height: min(gridHeight, maxHeight))
            }
        }
        .padding(20)
        .fixedSize()
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            HeaderView()
            Spacer()
            Toggle("Smooth", isOn: $model.monitorPrefs.smooth)
                .toggleStyle(.checkbox)
                .help("Interpolate between samples so charts scroll smoothly")
            Menu("Charts") {
                ForEach(ChartID.allCases) { c in
                    Toggle(c.title, isOn: Binding(
                        get: { model.monitorPrefs.items.first { $0.id == c }?.visible ?? false },
                        set: { v in model.updateChart(c) { $0.visible = v } }))
                }
                Divider()
                Button("Reset Layout") { model.monitorPrefs.items = MonitorPrefs().items }
            }
            .fixedSize()
            Picker("Time span", selection: $window) {
                Text("1 min").tag(60)
                Text("2 min").tag(120)
                Text("5 min").tag(300)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
        }
        .frame(width: Self.gridWidth)
    }

    struct Placed { let item: ChartLayoutItem; let frame: CGRect }

    /// Packs the visible charts, in order, into a two-column grid: each takes 1–2 columns and 1–2 rows
    /// and goes into the first free spot that fits (scanning top to bottom, left to right).
    private var placement: [Placed] {
        var taken = Set<[Int]>()          // [row, column]
        var out: [Placed] = []
        for it in model.monitorPrefs.items where it.visible {
            let w = it.span, h = it.rows
            var r = 0
            search: while true {
                for c in 0...(2 - w) {
                    let cells = (r..<(r + h)).flatMap { rr in (c..<(c + w)).map { [rr, $0] } }
                    if cells.allSatisfy({ !taken.contains($0) }) {
                        cells.forEach { taken.insert($0) }
                        let frame = CGRect(x: CGFloat(c) * (Self.column + Self.spacing),
                                           y: CGFloat(r) * (Self.cell + Self.spacing),
                                           width: CGFloat(w) * Self.column + CGFloat(w - 1) * Self.spacing,
                                           height: CGFloat(h) * Self.cell + CGFloat(h - 1) * Self.spacing)
                        out.append(Placed(item: it, frame: frame))
                        break search
                    }
                }
                r += 1
            }
        }
        return out
    }

    @ViewBuilder
    private func card(_ item: ChartLayoutItem) -> some View {
        content(item)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                ResizeHandle(item: item) { change in model.updateChart(item.id, change) }
            }
            .overlay(ColorContextMenu(metrics: item.id.metrics(fans: live.fans), fans: live.fans))
            .opacity(dragging == item.id ? 0.5 : 1)
            .onDrag {
                dragging = item.id
                return NSItemProvider(object: item.id.rawValue as NSString)
            }
            .onDrop(of: [.text], delegate: ChartDropDelegate(target: item.id, dragging: $dragging, model: model))
    }

    @ViewBuilder
    private func content(_ item: ChartLayoutItem) -> some View {
        let timing = ChartTiming(smooth: model.monitorPrefs.smooth, last: history.times.last ?? Date(),
                                 interval: history.sampleInterval, paused: !model.monitorOnScreen)
        switch item.id {
        case .cpuThreads:
            ThreadsCard(history: history, samples: window, span: item.span, timing: timing,
                        color: model.chartColors.color(.cpuLoad).color)
        case .fans:
            let fanMetrics = live.fans.compactMap { Metric.fan($0.index) }
            let lo = live.fans.map(\.minRPM).min() ?? 0
            let hi = live.fans.map(\.maxRPM).max() ?? 6000
            ChartCard(title: "Fans",
                      subtitle: live.fans.isEmpty ? "No fans reported" : (model.fanDraft.enabled ? "VoltBar fan control on" : "Controlled by macOS"),
                      value: live.fans.isEmpty ? "—" : live.fans.map { "\(Int($0.rpm))" }.joined(separator: " / ") + " rpm",
                      series: fanMetrics.map { m in
                          ChartSeries(name: m.title(fans: live.fans), values: history.values(m, last: window),
                                      color: model.chartColors.color(m).color)
                      },
                      range: (lo * 0.9)...max(lo + 1, hi), unit: "rpm", samples: window, timing: timing)
        case .gpuLoad, .gpuTemp:
            let ms = item.id.metrics(fans: live.fans)
            let isTemp = item.id == .gpuTemp
            ChartCard(title: item.id.title,
                      subtitle: ms.count > 1 ? "Integrated and discrete GPU" : "Integrated GPU",
                      value: ms.map { $0.format(history.latest($0), compact: true) }.joined(separator: " / "),
                      series: ms.map { m in
                          ChartSeries(name: m == .gpuLoadI || m == .gpuTempI ? "Integrated" : "Discrete",
                                      values: history.values(m, last: window), color: model.chartColors.color(m).color)
                      },
                      range: isTemp ? 30...100 : 0...100, unit: isTemp ? "°C" : "%", samples: window, timing: timing)
        default:
            let m = item.id.metric!
            ChartCard(title: item.id.title, subtitle: subtitle(m),
                      value: m.format(history.latest(m), compact: false),
                      series: [ChartSeries(name: "", values: history.values(m, last: window), color: model.chartColors.color(m).color)],
                      range: history.range(m, last: window), unit: unit(m), samples: window, timing: timing)
        }
    }

    private func unit(_ m: Metric) -> String {
        switch m {
        case .cpuLoad, .memory: return "%"
        case .cpuTemp: return "°C"
        case .cpuPower: return "W"
        case .cpuFreq: return "GHz"
        case .swap: return "GB"
        default: return "rpm"
        }
    }

    private func subtitle(_ m: Metric) -> String {
        switch m {
        case .memory: return model.memory.map { String(format: "%.1f of %.0f GB used", $0.usedGB, $0.totalGB) } ?? " "
        case .swap: return model.swap.map { $0.totalGB > 0 ? String(format: "%.2f of %.2f GB used", $0.usedGB, $0.totalGB) : "No swap in use" } ?? " "
        case .cpuFreq: return "Average of active cores"
        case .cpuPower: return "Package (cores, GPU, uncore)"
        case .cpuLoad: return "All threads"
        case .cpuTemp: return "Package sensor"
        default: return " "
        }
    }
}

/// Reorders charts while one is dragged over another.
struct ChartDropDelegate: DropDelegate {
    let target: ChartID
    @Binding var dragging: ChartID?
    let model: AppModel

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target,
              let from = model.monitorPrefs.items.firstIndex(where: { $0.id == d }),
              let to = model.monitorPrefs.items.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            var items = model.monitorPrefs.items
            let it = items.remove(at: from)
            items.insert(it, at: to)
            model.monitorPrefs.items = items
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Corner handle: drag right/left to make a chart two/one columns wide, down/up for two/one rows.
/// Sizes are discrete and applied on release; the drag is measured in screen coordinates
/// (NSEvent.mouseLocation) so the moving card and window can't feed back into it.
struct ResizeHandle: View {
    let item: ChartLayoutItem
    let change: ((inout ChartLayoutItem) -> Void) -> Void
    @State private var start: NSPoint? = nil
    @State private var pending: (span: Int, rows: Int)? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let p = pending, p.span != item.span || p.rows != item.rows {
                Text("Release for \(p.span) × \(p.rows)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.9)))
                    .foregroundColor(.white)
                    .offset(x: -22, y: -4)
                    .fixedSize()
            }
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .semibold))
                .padding(6)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { _ in
                            let mouse = NSEvent.mouseLocation
                            if start == nil { start = mouse }
                            guard let s = start else { return }
                            let dx = mouse.x - s.x
                            let dy = s.y - mouse.y           // screen y grows upwards
                            let span = dx > 80 ? 2 : (dx < -80 ? 1 : item.span)
                            let rows = dy > 60 ? 2 : (dy < -60 ? 1 : item.rows)
                            if pending?.span != span || pending?.rows != rows { pending = (span, rows) }
                        }
                        .onEnded { _ in
                            if let p = pending, p.span != item.span || p.rows != item.rows {
                                withAnimation(.easeInOut(duration: 0.2)) { change { $0.span = p.span; $0.rows = p.rows } }
                            }
                            start = nil
                            pending = nil
                        })
                .help("Drag to resize: right/left for two/one columns, down/up for two/one rows")
        }
    }
}

// MARK: - Cards

struct ChartSeries {
    let name: String
    let values: [Double?]
    let color: Color
}

/// Timing of the newest sample, used to slide charts smoothly towards it.
struct ChartTiming {
    let smooth: Bool
    let last: Date
    let interval: Double
    var paused = false     // window covered or minimised: no animation frames
}

struct ChartCard: View {
    let title: String
    let subtitle: String?
    let value: String
    let series: [ChartSeries]
    let range: ClosedRange<Double>
    let unit: String
    let samples: Int
    let timing: ChartTiming

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.headline)
                        Text(subtitle ?? " ").font(.caption)
                    }
                    Spacer()
                    Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                }
                LineChart(series: series, range: range, samples: samples, timing: timing)
                    .frame(maxHeight: .infinity)
                HStack {
                    Text("\(fmt(range.lowerBound)) – \(fmt(range.upperBound)) \(unit)").font(.caption2)
                    Spacer()
                    if series.count > 1 {
                        ForEach(Array(series.enumerated()), id: \.offset) { _, s in
                            HStack(spacing: 3) {
                                Circle().fill(s.color).frame(width: 6, height: 6)
                                Text(s.name).font(.caption2)
                            }
                        }
                    }
                    Spacer().frame(width: 14)   // room for the resize handle
                }
            }
            .padding(4)
            .frame(maxHeight: .infinity)
        }
    }

    private func fmt(_ v: Double) -> String { v.rounded() == v ? "\(Int(v))" : String(format: "%.1f", v) }
}

/// Every logical CPU as a small chart, all in one card.
struct ThreadsCard: View {
    @ObservedObject var history: MetricsHistory
    let samples: Int
    let span: Int
    let timing: ChartTiming
    var color: Color = .accentColor

    var body: some View {
        let n = history.threads.count
        let cols = span == 2 ? min(8, max(1, n)) : 4
        let latest = (0..<n).compactMap { history.threads[$0].last ?? nil }
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CPU Threads").font(.headline)
                        Text("\(n) logical CPUs").font(.caption)
                    }
                    Spacer()
                    Text(latest.isEmpty ? "—" : String(format: "max %.0f%%", latest.max() ?? 0))
                        .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                }
                let gridRows = max(1, Int(ceil(Double(n) / Double(cols))))
                VStack(spacing: 4) {
                  ForEach(0..<gridRows, id: \.self) { row in
                   HStack(spacing: 6) {
                    ForEach((row * cols)..<min(n, (row + 1) * cols), id: \.self) { i in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text("\(i + 1)").font(.caption2.weight(.semibold))
                                Spacer()
                                Text((history.threads[i].last ?? nil).map { String(format: "%.0f%%", $0) } ?? "—")
                                    .font(.caption2).monospacedDigit()
                            }
                            LineChart(series: [ChartSeries(name: "", values: history.threadValues(i, last: samples), color: color)],
                                      range: 0...100, samples: samples, timing: timing, gridLines: false, animate: false)
                                .frame(maxHeight: .infinity)
                        }
                    }
                   }
                  }
                }
                .frame(maxHeight: .infinity)
                HStack {
                    Text("0 – 100 % each").font(.caption2)
                    Spacer()
                }
            }
            .padding(4)
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Chart drawing

/// Line + area chart drawn with Canvas. With `timing.smooth` the curve is a Catmull-Rom spline and the
/// whole chart slides left continuously between samples. The frame rate follows how far a sample moves:
/// ~20 fps for a 1-minute span, ~10 for 2 minutes, 4 for 5 minutes — enough for sub-pixel steps
/// without burning CPU (≈0.4 ms per chart per frame).
struct LineChart: View {
    let series: [ChartSeries]
    let range: ClosedRange<Double>
    let samples: Int
    let timing: ChartTiming
    var gridLines = true
    /// Tiny charts move less than a pixel per sample; they're drawn smooth but not animated.
    var animate = true

    private var fps: Double { min(30, max(4, 1200 / Double(max(1, samples)))) }

    var body: some View {
        if timing.smooth && animate {
            TimelineView(.animation(minimumInterval: 1.0 / fps, paused: timing.paused)) { ctx in
                canvas(progress: min(1, max(0, ctx.date.timeIntervalSince(timing.last) / timing.interval)))
            }
        } else {
            canvas(progress: 1)
        }
    }

    private func canvas(progress: Double) -> some View {
        Canvas { g, size in
            let rect = CGRect(origin: .zero, size: size)
            let border = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4)
            g.stroke(border, with: .color(.primary.opacity(0.2)))
            if gridLines {
                var grid = Path()
                for f in [0.25, 0.5, 0.75] {
                    let y = size.height * CGFloat(f)
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                g.stroke(grid, with: .color(.primary.opacity(0.07)))
            }
            g.clip(to: border)
            for s in series {
                let segments = points(s.values, size: size, progress: progress)
                for seg in segments where !seg.isEmpty {
                    let line = timing.smooth ? spline(seg, height: size.height) : polyline(seg)
                    if series.count == 1, let first = seg.first, let last = seg.last {
                        var area = line
                        area.addLine(to: CGPoint(x: last.x, y: size.height))
                        area.addLine(to: CGPoint(x: first.x, y: size.height))
                        area.closeSubpath()
                        g.fill(area, with: .color(s.color.opacity(0.15)))
                    }
                    g.stroke(line, with: .color(s.color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    /// Points split at missing samples. The newest point enters from the right edge as `progress` goes 0 → 1.
    private func points(_ vals: [Double?], size: CGSize, progress: Double) -> [[CGPoint]] {
        let span = max(0.0001, range.upperBound - range.lowerBound)
        let step = size.width / CGFloat(max(1, samples - 1))
        let shift = (timing.smooth && animate) ? step * CGFloat(1 - progress) : 0
        var out: [[CGPoint]] = [[]]
        for (i, v) in vals.enumerated() {
            guard let v = v else { if !(out.last?.isEmpty ?? true) { out.append([]) }; continue }
            let x = size.width - step * CGFloat(vals.count - 1 - i) + shift
            let f = CGFloat(min(1, max(0, (v - range.lowerBound) / span)))
            out[out.count - 1].append(CGPoint(x: x, y: size.height - f * (size.height - 2) - 1))
        }
        return out
    }

    private func polyline(_ pts: [CGPoint]) -> Path {
        Path { p in
            p.move(to: pts[0])
            for pt in pts.dropFirst() { p.addLine(to: pt) }
        }
    }

    /// Catmull-Rom spline through the points, control points clamped so it never overshoots the plot.
    private func spline(_ pts: [CGPoint], height: CGFloat) -> Path {
        Path { p in
            p.move(to: pts[0])
            guard pts.count > 1 else { return }
            func clampY(_ y: CGFloat) -> CGFloat { min(height - 1, max(1, y)) }
            for i in 0..<(pts.count - 1) {
                let p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(pts.count - 1, i + 2)]
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: clampY(p1.y + (p2.y - p0.y) / 6))
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: clampY(p2.y - (p3.y - p1.y) / 6))
                p.addCurve(to: p2, control1: c1, control2: c2)
            }
        }
    }
}
