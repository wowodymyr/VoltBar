// VoltBar.app — entry point. Plain AppKit status item + popover (much faster than SwiftUI MenuBarExtra):
// the popover content is built once at launch and reused, so it opens instantly.

import AppKit
import Combine
import SwiftUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Self.icon(active: false)
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let root = CompactMenuView(openSettings: { [weak self] in self?.showSettings() })
            .environmentObject(model)
        let hosting = NSHostingController(rootView: root)
        if #available(macOS 13.0, *) { hosting.sizingOptions = [.preferredContentSize] }
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        // Build and lay out the view now, not on the first click.
        hosting.view.layoutSubtreeIfNeeded()

        let metrics = model.live.$tempC.combineLatest(model.live.$packageW)
        model.$status.map { $0?.enforcing == true }
            .combineLatest(metrics, model.$menuBarShowTemp, model.$menuBarShowPower)
            .map { active, m, showTemp, showPower -> MenuBarLabel in
                MenuBarLabel(active: active, text: Self.metricsText(temp: showTemp ? m.0 : nil, showTemp: showTemp,
                                                                    power: showPower ? m.1 : nil, showPower: showPower))
            }
            .removeDuplicates()
            .sink { [weak self] label in self?.updateStatusItem(label) }
            .store(in: &cancellables)

        // macOS 12 has no NSHostingController.sizingOptions: resize popover/window by hand
        // after SwiftUI has applied each model change.
        if #unavailable(macOS 13.0) {
            model.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.fitToContent() }
                .store(in: &cancellables)
        }
    }

    private func fitToContent() {
        if popover.isShown, let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            if size != popover.contentSize { popover.contentSize = size }
        }
        if let w = settingsWindow, w.isVisible, let view = w.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            let current = w.contentRect(forFrameRect: w.frame).size
            if size != current {
                // Keep the top edge in place while the height changes.
                var frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
                frame.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - frame.height)
                w.setFrame(frame, display: true)
            }
        }
    }

    private struct MenuBarLabel: Equatable {
        var active: Bool
        var text: String
    }

    private static func metricsText(temp: Int?, showTemp: Bool, power: Double?, showPower: Bool) -> String {
        var parts: [String] = []
        if showTemp { parts.append(temp.map { "\($0)°" } ?? "–°") }
        if showPower { parts.append(power.map { String(format: "%.1fW", $0) } ?? "–W") }
        return parts.joined(separator: " ")
    }

    private func updateStatusItem(_ label: MenuBarLabel) {
        guard let button = statusItem.button else { return }
        button.image = Self.icon(active: label.active)
        if label.text.isEmpty {
            statusItem.length = NSStatusItem.squareLength
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            statusItem.length = NSStatusItem.variableLength
            button.imagePosition = .imageLeading
            // Plain title (not attributed) so the menu bar picks the right text color for light/dark.
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.title = " " + label.text
        }
    }

    private static func icon(active: Bool) -> NSImage? {
        let img = NSImage(systemSymbolName: active ? "bolt.fill" : "bolt", accessibilityDescription: "VoltBar")
        img?.isTemplate = true
        return img
    }

    // MARK: Popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem.button else { return }
        model.popoverVisible = true
        if #unavailable(macOS 13.0), let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            popover.contentSize = view.fittingSize
        }
        // Show first, activate afterwards: app activation can take a moment and shouldn't delay the popover.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        model.popoverVisible = false
    }

    // MARK: Settings window

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsWindowView().environmentObject(model))
            if #available(macOS 13.0, *) { hosting.sizingOptions = [.preferredContentSize] }
            let w = NSWindow(contentViewController: hosting)
            w.title = "VoltBar Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        model.windowVisible = true
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        if #unavailable(macOS 13.0) { fitToContent() }
    }

    func windowWillClose(_ notification: Notification) {
        model.windowVisible = false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening VoltBar.app again (Finder / Spotlight) shows the settings window.
        showSettings()
        return false
    }
}
