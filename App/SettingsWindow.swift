// VoltBar.app — Settings window in the classic macOS preferences style: a toolbar with one item per
// tab; picking a tab swaps the content at once and animates the window to the new size, keeping its
// top-left corner in place. NSTabViewController isn't used because it resizes the window in one jump.

import AppKit
import Combine
import SwiftUI

/// Resizes in 0.15 s, like classic macOS settings windows.
final class SettingsWindow: NSWindow {
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.15 }
}

final class SettingsWindowController: NSObject, NSToolbarDelegate {
    let window: SettingsWindow
    private let container = FlippedView()
    private var tabs: [SettingsTab]
    private var current: SettingsTab?
    private var controllers: [SettingsTab: NSHostingController<AnyView>] = [:]
    private var sizeObservation: NSKeyValueObservation?
    private let makeView: (SettingsTab) -> AnyView

    init(tabs: [SettingsTab], makeView: @escaping (SettingsTab) -> AnyView) {
        self.tabs = tabs
        self.makeView = makeView
        window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = container
        let toolbar = NSToolbar(identifier: "VoltBarSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        // Build every tab up front so switching only swaps finished views (no layout during the animation).
        for t in tabs { controller(t).view.layoutSubtreeIfNeeded() }
    }

    private static func id(_ t: SettingsTab) -> NSToolbarItem.Identifier { .init("voltbar.tab.\(t.rawValue)") }

    // MARK: Tabs

    func select(_ tab: SettingsTab) {
        let tab = tabs.contains(tab) ? tab : (tabs.last ?? .general)
        window.toolbar?.selectedItemIdentifier = Self.id(tab)
        guard tab != current else { return }
        current = tab
        window.title = tab.title

        let vc = controller(tab)
        container.subviews.forEach { $0.removeFromSuperview() }
        vc.view.layoutSubtreeIfNeeded()
        let size = contentSize(of: vc)
        vc.view.frame = NSRect(origin: .zero, size: size)
        container.addSubview(vc.view)
        resize(to: size, animate: window.isVisible)

        // Follow size changes inside the tab (e.g. fan cards appearing) with the same animation.
        sizeObservation = vc.observe(\.preferredContentSize, options: [.new]) { [weak self, weak vc] _, _ in
            DispatchQueue.main.async {
                guard let self = self, let vc = vc, self.current == tab else { return }
                self.refit(vc)
            }
        }
    }

    /// Shows or hides tabs (modules switched on/off in General).
    func setTabs(_ new: [SettingsTab]) {
        guard new != tabs, let toolbar = window.toolbar else { return }
        for t in new where controllers[t] == nil { controller(t).view.layoutSubtreeIfNeeded() }
        for (i, item) in toolbar.items.enumerated().reversed() where !new.map(Self.id).contains(item.itemIdentifier) {
            toolbar.removeItem(at: i)
        }
        for (pos, t) in new.enumerated() where !toolbar.items.contains(where: { $0.itemIdentifier == Self.id(t) }) {
            toolbar.insertItem(withItemIdentifier: Self.id(t), at: pos)
        }
        tabs = new
        for t in controllers.keys where !new.contains(t) { controllers[t] = nil }
        if let c = current, !new.contains(c) { current = nil; select(.general) }
        else if let c = current { window.toolbar?.selectedItemIdentifier = Self.id(c) }
    }

    /// Re-measures the current tab (macOS 12, where hosting controllers don't report size changes).
    func refitCurrent() {
        guard let c = current, let vc = controllers[c] else { return }
        refit(vc)
    }

    private func refit(_ vc: NSHostingController<AnyView>) {
        vc.view.layoutSubtreeIfNeeded()
        let size = contentSize(of: vc)
        guard size != vc.view.frame.size else { return }
        vc.view.frame = NSRect(origin: .zero, size: size)
        resize(to: size, animate: window.isVisible)
    }

    private func controller(_ t: SettingsTab) -> NSHostingController<AnyView> {
        if let c = controllers[t] { return c }
        let c = NSHostingController(rootView: makeView(t))
        if #available(macOS 13.0, *) { c.sizingOptions = [.preferredContentSize] }
        controllers[t] = c
        return c
    }

    private func contentSize(of vc: NSHostingController<AnyView>) -> NSSize {
        let p = vc.preferredContentSize
        return (p.width > 0 && p.height > 0) ? p : vc.view.fittingSize
    }

    private func resize(to size: NSSize, animate: Bool) {
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var frame = window.frame
        frame.origin.y = frame.maxY - target.height      // keep the top edge
        frame.size = target.size
        guard animate else { window.setFrame(frame, display: true); return }
        // Core Animation-driven and asynchronous: smooth even while SwiftUI is busy, and it doesn't block.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            window.animator().setFrame(frame, display: true)
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { SettingsTab.allCases.map(Self.id) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { tabs.map(Self.id) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { SettingsTab.allCases.map(Self.id) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = SettingsTab.allCases.first(where: { Self.id($0) == id }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        if let tab = SettingsTab.allCases.first(where: { Self.id($0) == sender.itemIdentifier }) { select(tab) }
    }
}

/// Top-left origin so tab content stays pinned to the top while the window animates.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
