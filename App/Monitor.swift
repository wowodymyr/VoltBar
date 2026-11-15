// VoltBar.app — live metrics: history buffer, menu bar configuration and the menu bar image renderer.

import AppKit
import Combine

// MARK: - Metrics

enum Metric: String, Codable, CaseIterable, Hashable {
    case cpuLoad, cpuTemp, cpuPower, cpuFreq, memory, swap, fan0, fan1, fan2, fan3

    var fanIndex: Int? {
        switch self {
        case .fan0: return 0
        case .fan1: return 1
        case .fan2: return 2
        case .fan3: return 3
        default: return nil
        }
    }

    static let fans: [Metric] = [.fan0, .fan1, .fan2, .fan3]
    static func fan(_ i: Int) -> Metric? { fans.indices.contains(i) ? fans[i] : nil }

    func title(fans: [FanInfo]) -> String {
        switch self {
        case .cpuLoad: return "CPU Load"
        case .cpuTemp: return "CPU Temperature"
        case .cpuPower: return "CPU Power"
        case .cpuFreq: return "CPU Frequency"
        case .memory: return "Memory"
        case .swap: return "Swap"
        default: return fans.first { $0.index == fanIndex }?.name ?? "Fan \((fanIndex ?? 0) + 1)"
        }
    }

    /// Tiny label shown above the value in the menu bar.
    var shortLabel: String {
        switch self {
        case .cpuLoad: return "CPU"
        case .cpuTemp: return "TEMP"
        case .cpuPower: return "PWR"
        case .cpuFreq: return "FREQ"
        case .memory: return "RAM"
        case .swap: return "SWAP"
        default: return "FAN\((fanIndex ?? 0) + 1)"
        }
    }

    /// Widest value this metric can show in the menu bar; its width is reserved so the item never jumps.
    var widestCompactValue: String {
        switch self {
        case .cpuLoad, .memory: return "100%"
        case .cpuTemp: return "100°"
        case .cpuPower: return "88.8W"
        case .cpuFreq, .swap: return "8.8G"
        default: return "8888"
        }
    }

    func format(_ v: Double?, compact: Bool) -> String {
        guard let v = v else { return "–" }
        switch self {
        case .cpuLoad, .memory: return String(format: "%.0f%%", v)
        case .cpuTemp: return String(format: compact ? "%.0f°" : "%.0f °C", v)
        case .cpuPower: return String(format: compact ? "%.1fW" : "%.1f W", v)
        case .cpuFreq: return String(format: compact ? "%.1fG" : "%.2f GHz", v)
        case .swap: return String(format: compact ? "%.1fG" : "%.2f GB", v)
        default: return String(format: compact ? "%.0f" : "%.0f rpm", v)
        }
    }
}

// MARK: - History

final class MetricsHistory: ObservableObject {
    static let capacity = 300

    /// Bumped on every sample; views observe this instead of the (large) buffers.
    @Published private(set) var tick = 0
    private(set) var times: [Date] = []
    private var series: [Metric: [Double?]] = [:]
    /// Per-thread (logical CPU) load, one series per thread.
    private(set) var threads: [[Double?]] = []
    /// Value range per metric for graphs (fans: their min…max RPM, swap: total size).
    private(set) var ranges: [Metric: ClosedRange<Double>] = [:]

    func append(_ values: [Metric: Double], threadLoad: [Double]? = nil, at t: Date = Date()) {
        times.append(t)
        if let tl = threadLoad {
            if threads.count != tl.count { threads = Array(repeating: Array(repeating: nil, count: times.count - 1), count: tl.count) }
            for i in tl.indices {
                threads[i].append(tl[i])
                if threads[i].count > Self.capacity { threads[i].removeFirst(threads[i].count - Self.capacity) }
            }
        } else {
            for i in threads.indices {
                threads[i].append(nil)
                if threads[i].count > Self.capacity { threads[i].removeFirst(threads[i].count - Self.capacity) }
            }
        }
        for m in Metric.allCases {
            var s = series[m] ?? []
            s.append(values[m])
            if s.count > Self.capacity { s.removeFirst(s.count - Self.capacity) }
            series[m] = s
        }
        if times.count > Self.capacity { times.removeFirst(times.count - Self.capacity) }
        tick &+= 1
    }

    func setRange(_ m: Metric, _ r: ClosedRange<Double>) { ranges[m] = r }

    func values(_ m: Metric, last n: Int) -> [Double?] { Array((series[m] ?? []).suffix(n)) }

    func latest(_ m: Metric) -> Double? { series[m]?.last ?? nil }

    func threadValues(_ i: Int, last n: Int) -> [Double?] { i < threads.count ? Array(threads[i].suffix(n)) : [] }

    /// Seconds between the two newest samples (used to animate the scroll between them).
    var sampleInterval: Double {
        guard times.count >= 2 else { return 1 }
        return min(5, max(0.5, times[times.count - 1].timeIntervalSince(times[times.count - 2])))
    }

    /// Range to draw `m` in: fixed for percentages/temperature, otherwise grows with the data.
    func range(_ m: Metric, last n: Int) -> ClosedRange<Double> {
        switch m {
        case .cpuLoad, .memory: return 0...100
        case .cpuTemp: return 30...100
        default:
            if let r = ranges[m] { return r }
            let peak = values(m, last: n).compactMap { $0 }.max() ?? 1
            switch m {
            case .cpuPower: return 0...max(10, (peak / 10).rounded(.up) * 10)
            case .cpuFreq: return 0...max(1, peak.rounded(.up))
            case .swap: return 0...max(1, peak.rounded(.up))
            default: return 0...max(1, peak)
            }
        }
    }
}

// MARK: - Menu bar configuration

enum MenuBarDisplay: String, Codable, CaseIterable {
    case off, text, graph, both

    var title: String {
        switch self {
        case .off: return "Off"
        case .text: return "Value"
        case .graph: return "Graph"
        case .both: return "Both"
        }
    }
}

enum MenuBarIconStyle: String, Codable, CaseIterable {
    case monochrome, yellow, hidden

    var title: String {
        switch self {
        case .monochrome: return "Monochrome"
        case .yellow: return "Yellow"
        case .hidden: return "Hidden"
        }
    }
}

struct MenuBarConfig: Codable, Equatable {
    var icon: MenuBarIconStyle = .monochrome
    var separators = false
    var items: [Metric: MenuBarDisplay] = [:]

    func display(_ m: Metric) -> MenuBarDisplay { items[m] ?? .off }
    var hasItems: Bool { items.values.contains { $0 != .off } }
    var hasGraphs: Bool { items.values.contains { $0 == .graph || $0 == .both } }

    static let defaultsKey = "menuBarConfig"

    static func load() -> MenuBarConfig {
        let d = UserDefaults.standard
        if let data = d.data(forKey: defaultsKey), let c = try? JSONDecoder().decode(MenuBarConfig.self, from: data) { return c }
        // Migrate the two checkboxes from 1.2–1.5.
        var c = MenuBarConfig()
        if d.bool(forKey: "menuBarShowTemp") { c.items[.cpuTemp] = .text }
        if d.bool(forKey: "menuBarShowPower") { c.items[.cpuPower] = .text }
        return c
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}

// MARK: - Menu bar image

enum MenuBarRenderer {
    static let height: CGFloat = 18
    static let graphWidth: CGFloat = 30
    static let graphSamples = 30

    struct Item { let metric: Metric; let display: MenuBarDisplay }

    /// Draws the whole status item: optional bolt, then each enabled metric (label + value and/or graph).
    static func image(config: MenuBarConfig, history: MetricsHistory, active: Bool, fanCount: Int) -> NSImage {
        let items = Metric.allCases
            .filter { $0.fanIndex.map { $0 < fanCount } ?? true }
            .map { Item(metric: $0, display: config.display($0)) }
            .filter { $0.display != .off }
        // Never leave the status item empty.
        let showIcon = config.icon != .hidden || items.isEmpty
        let iconWidth: CGFloat = showIcon ? 16 : 0

        let labelFont = NSFont.systemFont(ofSize: 7, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

        let sideLabelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)

        // Fixed per metric (widest possible value), so changing numbers never resize the status item.
        func valueWidth(_ m: Metric) -> CGFloat {
            ceil((m.widestCompactValue as NSString).size(withAttributes: [.font: valueFont]).width)
        }
        func drawValue(_ m: Metric, x: CGFloat, width: CGFloat, y: CGFloat, color: NSColor) {
            let s = m.format(history.latest(m), compact: true) as NSString
            let w = s.size(withAttributes: [.font: valueFont]).width
            s.draw(at: NSPoint(x: x + width - w, y: y), withAttributes: [.font: valueFont, .foregroundColor: color])
        }
        func textWidth(_ m: Metric) -> CGFloat {
            let l = (m.shortLabel as NSString).size(withAttributes: [.font: labelFont]).width
            return ceil(max(valueWidth(m), l))
        }
        /// Label drawn to the left of a graph, so it's clear what the graph shows.
        func sideLabelWidth(_ m: Metric) -> CGFloat {
            ceil((m.shortLabel as NSString).size(withAttributes: [.font: sideLabelFont]).width)
        }
        func itemWidth(_ it: Item) -> CGFloat {
            switch it.display {
            case .off: return 0
            case .text: return textWidth(it.metric)
            case .graph: return sideLabelWidth(it.metric) + 3 + graphWidth
            case .both: return sideLabelWidth(it.metric) + 3 + graphWidth + 3 + valueWidth(it.metric)
            }
        }

        let gap: CGFloat = config.separators ? 9 : 6
        var width = iconWidth
        for (i, it) in items.enumerated() { width += ((i == 0 && !showIcon) ? 0 : gap) + itemWidth(it) }
        width = max(width, 16)

        let isTemplate = config.icon != .yellow
        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let fg = isTemplate ? NSColor.black : NSColor.labelColor
            var x: CGFloat = 0
            if showIcon {
                let name = active ? "bolt.fill" : "bolt"
                if let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
                    let tint = config.icon == .yellow ? NSColor.systemYellow : fg
                    let tinted = NSImage(size: sym.size, flipped: false) { r in
                        sym.draw(in: r)
                        tint.set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: NSRect(x: (16 - sym.size.width) / 2, y: (height - sym.size.height) / 2,
                                           width: sym.size.width, height: sym.size.height))
                }
                x = iconWidth
            }
            for (i, it) in items.enumerated() {
                if !(i == 0 && !showIcon) {
                    if config.separators {
                        fg.withAlphaComponent(0.35).set()
                        NSRect(x: x + gap / 2 - 0.5, y: 3, width: 1, height: height - 6).fill()
                    }
                    x += gap
                }
                if it.display == .graph || it.display == .both {
                    let label = it.metric.shortLabel as NSString
                    let lw = sideLabelWidth(it.metric)
                    let lh = label.size(withAttributes: [.font: sideLabelFont]).height
                    label.draw(at: NSPoint(x: x, y: (height - lh) / 2),
                               withAttributes: [.font: sideLabelFont, .foregroundColor: fg.withAlphaComponent(0.85)])
                    x += lw + 3
                    drawGraph(it.metric, history: history, in: NSRect(x: x, y: 2, width: graphWidth, height: height - 4), color: fg)
                    x += graphWidth
                }
                if it.display == .both {
                    x += 3
                    let vh = ("8" as NSString).size(withAttributes: [.font: valueFont]).height
                    drawValue(it.metric, x: x, width: valueWidth(it.metric), y: (height - vh) / 2, color: fg)
                    x += valueWidth(it.metric)
                }
                if it.display == .text {
                    let w = textWidth(it.metric)
                    let label = it.metric.shortLabel as NSString
                    let lw = label.size(withAttributes: [.font: labelFont]).width
                    label.draw(at: NSPoint(x: x + w - lw, y: 9.5),
                               withAttributes: [.font: labelFont, .foregroundColor: fg.withAlphaComponent(0.85)])
                    drawValue(it.metric, x: x, width: w, y: -1, color: fg)
                    x += w
                }
            }
            return true
        }
        img.isTemplate = isTemplate
        return img
    }

    private static func drawGraph(_ m: Metric, history: MetricsHistory, in r: NSRect, color: NSColor) {
        let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
        color.withAlphaComponent(0.12).setFill()
        path.fill()
        color.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 0.75
        path.stroke()
        let vals = history.values(m, last: graphSamples)
        let range = history.range(m, last: graphSamples)
        let span = max(0.0001, range.upperBound - range.lowerBound)
        let barW = (r.width - 2) / CGFloat(graphSamples)
        color.withAlphaComponent(0.9).setFill()
        let offset = graphSamples - vals.count
        for (i, v) in vals.enumerated() {
            guard let v = v else { continue }
            let f = CGFloat(min(1, max(0, (v - range.lowerBound) / span)))
            let h = max(0.5, f * (r.height - 2))
            NSRect(x: r.minX + 1 + CGFloat(i + offset) * barW, y: r.minY + 1, width: max(0.5, barW - 0.25), height: h).fill()
        }
    }
}
