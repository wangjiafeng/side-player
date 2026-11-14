import AppKit
import SwiftUI

@main
struct SidePlayerApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

private final class DesktopPanel: NSPanel {
    var showContextMenu: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown ||
            (event.type == .otherMouseDown && event.buttonNumber == 1) ||
            (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            showContextMenu?(event)
            return
        }
        super.sendEvent(event)
    }
}

private final class SidebarHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "sidebarVerticalOffsetMM") == nil {
            let previous = defaults.double(forKey: "sidebarVerticalOffset")
            defaults.set((previous * 25.4 / 72 * 10).rounded() / 10, forKey: "sidebarVerticalOffsetMM")
        }
        PlayerModel.shared.restoreSongLists()
        makeSidebar()
        PlayerModel.shared.refreshSelectedSources()
        makeStatusItem()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateSidebarGeometry() }
        }
        if UserDefaults.standard.object(forKey: "startupSettings") == nil || UserDefaults.standard.bool(forKey: "startupSettings") {
            showSettings()
        }
    }

    private func makeSidebar() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height: CGFloat = min(760, screen.height - 80)
        let frame = NSRect(x: screen.minX, y: screen.midY - height / 2, width: 300, height: height)
        let window = DesktopPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isFloatingPanel = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.becomesKeyOnlyIfNeeded = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
        window.hidesOnDeactivate = false
        window.showContextMenu = { [weak self] event in self?.showSidebarMenu(event) }
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces]
        window.contentView = SidebarHostingView(rootView: SidebarView().environmentObject(PlayerModel.shared))
        window.orderFrontRegardless()
        panel = window
        updateSidebarGeometry()
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let iconURL = Bundle.module.url(forResource: "slide-player-menu", withExtension: "svg", subdirectory: "Resources"),
           let icon = NSImage(contentsOf: iconURL) {
            icon.size = NSSize(width: 18, height: 14)
            icon.isTemplate = false
            item.button?.image = icon
        }

        let menu = NSMenu()
        for (title, action, key) in [
            ("刷新", #selector(refresh), ""),
            ("设置", #selector(showSettings), ",")
        ] {
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func showSettings() {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "设置"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: SettingsRootView().environmentObject(PlayerModel.shared))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    private func showSidebarMenu(_ event: NSEvent) {
        guard let view = panel?.contentView else { return }
        let menu = NSMenu()
        for (title, action) in [("刷新", #selector(refresh)), ("设置", #selector(showSettings)), ("退出", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
    }

    @objc private func refresh() { PlayerModel.shared.refreshSelectedSources() }

    @objc private func quit() { NSApp.terminate(nil) }

    private func updateSidebarGeometry() {
        guard let panel, let screen = NSScreen.main?.visibleFrame else { return }
        let height = min(760, screen.height - 80)
        let offset = CGFloat(UserDefaults.standard.double(forKey: "sidebarVerticalOffsetMM") * 72 / 25.4)
        let x = UserDefaults.standard.string(forKey: "sidebarSide") == "右侧" ? screen.maxX - panel.frame.width : screen.minX
        let y = min(max(screen.midY - height / 2 + offset, screen.minY), max(screen.minY, screen.maxY - height))
        panel.setFrame(NSRect(x: x, y: y, width: panel.frame.width, height: height), display: true)
        panel.alphaValue = max(0.1, min(1, UserDefaults.standard.double(forKey: "sidebarOpacity") == 0 ? 1 : UserDefaults.standard.double(forKey: "sidebarOpacity") / 100))
    }
}
