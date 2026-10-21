import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var captureItem: NSMenuItem!
    private var hotKey: HotKey?
    private var session: CaptureSession?
    private var isCapturing = false
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        buildStatusItem()
        registerHotKey()
        if !Settings.hasLaunchedBefore {
            Settings.hasLaunchedBefore = true
            showSettings(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(nil)
        return false
    }

    // MARK: - Menus

    private static let statusImage = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Glimpse")

    private static let recentDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.statusImage
        captureItem = NSMenuItem(title: "Take Screenshot", action: #selector(captureFromMenu(_:)), keyEquivalent: "")
        captureItem.target = self
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu(menu)
    }

    /// Rebuilt every time the menu opens so the Recent list is current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(captureItem)
        menu.addItem(.separator())

        if Settings.keepHistory {
            menu.addItem(.sectionHeader(title: "Recent"))
            let entries = History.entries()
            if entries.isEmpty {
                let empty = NSMenuItem(title: "No screenshots yet", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            } else {
                for entry in entries {
                    menu.addItem(recentItem(for: entry))
                }
                menu.addItem(withTitle: "Clear Recent", action: #selector(clearRecent(_:)), keyEquivalent: "").target = self
            }
            menu.addItem(.separator())
        }

        menu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "About Glimpse", action: #selector(showAbout(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Glimpse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func recentItem(for entry: History.Entry) -> NSMenuItem {
        let item = NSMenuItem(title: Self.recentDateFormatter.string(from: entry.date),
                              action: #selector(copyRecent(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = entry
        item.image = History.thumbnail(for: entry)
        let size = "\(Int(entry.pixelSize.width)) × \(Int(entry.pixelSize.height))"
        if #available(macOS 14.4, *) {
            item.subtitle = size
        }
        item.toolTip = "\(size) · Click to copy to the clipboard"
        return item
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? History.Entry, History.copyToPasteboard(entry) else {
            NSSound.beep()
            return
        }
        // Brief tick in the menu bar so it's clear the copy happened.
        statusItem.button?.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.statusItem.button?.image = Self.statusImage
        }
    }

    @objc private func clearRecent(_ sender: Any?) {
        History.clear()
    }

    /// Never shown (Glimpse has no Dock icon) but gives the Settings window ⌘W, ⌘Q and editing keys.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Glimpse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Glimpse", action: nil, keyEquivalent: "").submenu = appMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        return main
    }

    private func updateCaptureItem() {
        let shortcut = Settings.shortcut
        if hotKey != nil, let equivalent = shortcut.menuKeyEquivalent {
            captureItem.keyEquivalent = equivalent.key
            captureItem.keyEquivalentModifierMask = equivalent.modifiers
        } else {
            captureItem.keyEquivalent = ""
        }
        captureItem.title = hotKey == nil ? "Take Screenshot (\(shortcut.display) is taken)" : "Take Screenshot"
    }

    // MARK: - Hotkey

    @discardableResult
    private func registerHotKey() -> Bool {
        hotKey?.unregister()
        hotKey = HotKey(shortcut: Settings.shortcut) { [weak self] in self?.capture() }
        updateCaptureItem()
        return hotKey != nil
    }

    // MARK: - Capture

    @objc private func captureFromMenu(_ sender: Any?) {
        // Let the menu finish fading out so it isn't in the screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.capture()
        }
    }

    private func capture() {
        guard session == nil, !isCapturing else { return }
        guard ScreenGrabber.hasPermission else {
            ScreenAccess.requestAccess()
            return
        }
        isCapturing = true
        Task { @MainActor in
            defer { isCapturing = false }
            do {
                let grabs = try await ScreenGrabber.grabAllScreens()
                guard !grabs.isEmpty else { return }
                begin(CaptureSession(grabs: grabs) { self.session = nil })
            } catch {
                NSApp.activate()
                let alert = NSAlert()
                alert.messageText = "Couldn't capture the screen"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    func begin(_ newSession: CaptureSession) {
        session = newSession
        newSession.begin()
    }

    // MARK: - Windows

    @objc private func showSettings(_ sender: Any?) {
        if settings == nil {
            let controller = SettingsWindowController()
            controller.onShortcutChange = { [unowned self] shortcut in
                let previous = Settings.shortcut
                Settings.shortcut = shortcut
                if registerHotKey() { return true }
                Settings.shortcut = previous
                registerHotKey()
                return false
            }
            controller.onRecordingChange = { [unowned self] recording in
                // Stop the current hotkey from firing while the user types a new one.
                if recording {
                    hotKey?.unregister()
                    hotKey = nil
                } else if hotKey == nil {
                    registerHotKey()
                }
            }
            settings = controller
        }
        settings?.show()
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "A native Apple Silicon screenshot tool. Nothing leaves your Mac.",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            )
        ])
    }
}
