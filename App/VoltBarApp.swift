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
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        // Build and lay out the view now, not on the first click.
        hosting.view.layoutSubtreeIfNeeded()

        model.$status
            .combineLatest(model.$menuBarShowTemp, model.$menuBarShowPower)
            .map { status, showTemp, showPower -> MenuBarLabel in
                MenuBarLabel(active: status?.enforcing == true,
                             text: Self.metricsText(status, temp: showTemp, power: showPower))
            }
            .removeDuplicates()
            .sink { [weak self] label in self?.updateStatusItem(label) }
            .store(in: &cancellables)
    }

    private struct MenuBarLabel: Equatable {
        var active: Bool
        var text: String
    }

    private static func metricsText(_ s: Status?, temp: Bool, power: Bool) -> String {
        var parts: [String] = []
        if temp { parts.append(s?.tempC.map { "\($0)°" } ?? "–°") }
        if power { parts.append(s?.packageW.map { String(format: "%.1fW", $0) } ?? "–W") }
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
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        model.popoverVisible = false
    }

    // MARK: Settings window

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsWindowView().environmentObject(model))
            hosting.sizingOptions = [.preferredContentSize]
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
