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
    private var settings: SettingsWindowController?
    private var settingsWindow: NSWindow? { settings?.window }
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt", accessibilityDescription: "VoltBar")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let root = CompactMenuView(openSettings: { [weak self] tab in self?.showSettings(tab) },
                                   openMonitor: { [weak self] in self?.showMonitor() })
            .environmentObject(model)
        let hosting = NSHostingController(rootView: root)
        if #available(macOS 13.0, *) { hosting.sizingOptions = [.preferredContentSize] }
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        // Build and lay out the view now, not on the first click.
        hosting.view.layoutSubtreeIfNeeded()

        // Redraw the menu bar item on every new sample, settings change or profile change.
        model.history.$tick.map { _ in () }
            .merge(with: model.$menuBarConfig.map { _ in () },
                   model.$features.map { _ in () },
                   model.gpu.$usingIntegrated.removeDuplicates().map { _ in () },
                   model.gpu.$settings.map(\.menuBarDot).removeDuplicates().map { _ in () },
                   model.$status.map { $0?.enforcing == true }.removeDuplicates().map { _ in () },
                   model.live.$fans.map { $0.count }.removeDuplicates().map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.renderStatusItem() }
            .store(in: &cancellables)

        // gSwitch-compatible launch arguments: --integrated, --dynamic, --discrete.
        let args = CommandLine.arguments
        if let mode = GPUMode.allCases.first(where: { args.contains("--\($0.rawValue)") }), model.features.gpu {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.gpu.apply(mode, confirmed: true) }
        }

        // Show or hide settings tabs when modules are switched on/off in General.
        model.$features.removeDuplicates().dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.settings?.setTabs(self.enabledTabs())
            }
            .store(in: &cancellables)

        // Monitoring switched off: close its window.
        model.$features.map(\.monitoring).removeDuplicates()
            .sink { [weak self] on in if !on { self?.monitorWindow?.close() } }
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
        if let s = settings, s.window.isVisible { s.refitCurrent() }
    }

    private var lastStatusItemKey = ""

    /// gSwitch-style indicator: a dot on the icon while the discrete GPU is active.
    private var discreteDot: Bool {
        model.features.gpu && model.gpu.available && model.gpu.settings.menuBarDot && !model.gpu.usingIntegrated
    }

    private func renderStatusItem() {
        guard let button = statusItem.button else { return }
        var cfg = model.menuBarConfig
        if !model.features.monitoring { cfg.items = [:] }   // monitoring off: icon only
        // Skip redraws that wouldn't change a pixel (graphs change with every sample, values only sometimes).
        let active = model.status?.enforcing == true
        if !cfg.hasGraphs {
            let values = Metric.allCases.filter { cfg.display($0) != .off }
                .map { $0.format(model.history.latest($0), compact: true) }.joined(separator: "|")
            let key = "\(active)|\(discreteDot)|\(cfg.icon)|\(cfg.separators)|\(cfg.items.count)|\(model.live.fans.count)|" + values
            if key == lastStatusItemKey { return }
            lastStatusItemKey = key
        } else {
            lastStatusItemKey = ""
        }
        let img = MenuBarRenderer.image(config: cfg, history: model.history,
                                        active: model.status?.enforcing == true, fanCount: model.live.fans.count,
                                        discreteDot: discreteDot)
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = img
        statusItem.length = img.size.width <= 18 ? NSStatusItem.squareLength : img.size.width + 8
    }

    // MARK: Monitor window

    private var monitorWindow: NSWindow?

    private func showMonitor() {
        guard model.features.monitoring else { return }
        popover.performClose(nil)
        if monitorWindow == nil {
            let view = MonitorView(history: model.history, live: model.live).environmentObject(model)
            let h = NSHostingController(rootView: view)
            if #available(macOS 13.0, *) { h.sizingOptions = [.preferredContentSize] }
            let w = NSWindow(contentViewController: h)
            w.title = "VoltBar Monitor"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("VoltBarMonitor")
            if !w.setFrameUsingName("VoltBarMonitor") { w.center() }
            monitorWindow = w
        }
        model.monitorVisible = true
        NSApp.activate(ignoringOtherApps: true)
        monitorWindow?.makeKeyAndOrderFront(nil)
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

    private func showSettings(_ tab: SettingsTab = .undervolting) {
        popover.performClose(nil)
        if settings == nil {
            let model = self.model
            let s = SettingsWindowController(tabs: enabledTabs()) { t in
                switch t {
                case .undervolting: return AnyView(UndervoltSettingsView().environmentObject(model))
                case .fans: return AnyView(FansSettingsView(live: model.live).environmentObject(model))
                case .gpu: return AnyView(GPUSettingsView(gpu: model.gpu))
                case .general: return AnyView(GeneralSettingsView().environmentObject(model))
                }
            }
            s.window.delegate = self
            settings = s
        }
        let wasVisible = settingsWindow?.isVisible ?? false
        settings?.select(tab)
        if !wasVisible { settingsWindow?.center() }
        model.windowVisible = true
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func enabledTabs() -> [SettingsTab] {
        SettingsTab.allCases.filter {
            switch $0 {
            case .undervolting: return model.features.undervolting
            case .fans: return model.features.fans
            case .gpu: return model.features.gpu && model.gpu.available
            case .general: return true
            }
        }
    }

    /// Closed windows are released, not just hidden: a hidden window keeps its (large) GPU backing
    /// stores and its SwiftUI content keeps updating and animating in the background.
    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === monitorWindow {
            model.monitorVisible = false
            DispatchQueue.main.async { [weak self] in
                self?.monitorWindow?.contentViewController = nil
                self?.monitorWindow = nil
            }
        } else if w === settingsWindow {
            model.windowVisible = false
            DispatchQueue.main.async { [weak self] in
                self?.settings?.window.contentView = nil
                self?.settings = nil
            }
        }
    }

    /// Monitor charts animate only while the window can actually be seen.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === monitorWindow else { return }
        model.monitorOnScreen = w.occlusionState.contains(.visible)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening VoltBar.app again (Finder / Spotlight) shows the settings window.
        showSettings()
        return false
    }
}
