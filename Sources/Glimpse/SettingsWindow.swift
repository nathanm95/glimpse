import AppKit
import ServiceManagement

/// A button that records the next key combination pressed while it is active.
final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut { didSet { title = shortcut.display } }
    var onChange: ((Shortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private var monitor: Any?

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .push
        title = shortcut.display
        target = self
        action = #selector(toggleRecording)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func toggleRecording() {
        if monitor == nil { startRecording() } else { stopRecording() }
    }

    private func startRecording() {
        title = "Type shortcut…"
        onRecordingChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        if Int(event.keyCode) == 53 { // Escape
            stopRecording()
            return
        }
        guard let newShortcut = Shortcut(event: event) else {
            NSSound.beep()
            return
        }
        shortcut = newShortcut
        stopRecording()
        onChange?(newShortcut)
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        title = shortcut.display
        onRecordingChange?(false)
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Returns false when the shortcut couldn't be registered.
    var onShortcutChange: ((Shortcut) -> Bool)?
    var onRecordingChange: ((Bool) -> Void)?

    private let recorder = ShortcutRecorder(shortcut: Settings.shortcut)
    private let downscale = NSButton(checkboxWithTitle: "Save Retina screenshots at standard resolution (1×)", target: nil, action: nil)
    private let openAtLogin = NSButton(checkboxWithTitle: "Open Glimpse at login", target: nil, action: nil)
    private let keepHistory = NSButton(checkboxWithTitle: "Keep the last \(History.limit) screenshots in the menu bar menu", target: nil, action: nil)
    private let permissionStatus = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Glimpse Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent() {
        recorder.onChange = { [unowned self] shortcut in
            if onShortcutChange?(shortcut) == false {
                let alert = NSAlert()
                alert.messageText = "\(shortcut.display) can't be used"
                alert.informativeText = "Another app or macOS is already using that shortcut. Try a different one."
                alert.runModal()
            }
            recorder.shortcut = Settings.shortcut
        }
        recorder.onRecordingChange = { [unowned self] recording in onRecordingChange?(recording) }

        downscale.target = self
        downscale.action = #selector(toggleDownscale(_:))
        downscale.state = Settings.downscaleRetina ? .on : .off
        openAtLogin.target = self
        openAtLogin.action = #selector(toggleOpenAtLogin(_:))
        openAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        keepHistory.target = self
        keepHistory.action = #selector(toggleKeepHistory(_:))
        keepHistory.state = Settings.keepHistory ? .on : .off

        let openPrivacy = NSButton(title: "Open Privacy Settings…", target: self, action: #selector(openPrivacySettings))
        openPrivacy.bezelStyle = .push
        let permissionRow = NSStackView(views: [permissionStatus, openPrivacy])
        permissionRow.spacing = 10

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Screenshot shortcut:"), recorder],
            [NSGridCell.emptyContentView, downscale],
            [NSGridCell.emptyContentView, keepHistory],
            [NSGridCell.emptyContentView, openAtLogin],
            [NSTextField(labelWithString: "Screen Recording:"), permissionRow]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.row(at: 0).cell(at: 1).xPlacement = .leading

        let note = NSTextField(wrappingLabelWithString: "Screenshots stay on your Mac. Glimpse has no upload or online gallery.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let stack = NSStackView(views: [grid, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            note.widthAnchor.constraint(equalTo: grid.widthAnchor)
        ])
        window?.contentView = content
        window?.setContentSize(content.fittingSize)
        refreshPermission()
    }

    func show() {
        refreshPermission()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshPermission()
        openAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func refreshPermission() {
        let granted = ScreenGrabber.hasPermission
        permissionStatus.stringValue = granted ? "Allowed" : "Not allowed yet"
        permissionStatus.textColor = granted ? .secondaryLabelColor : .systemRed
    }

    @objc private func toggleDownscale(_ sender: NSButton) {
        Settings.downscaleRetina = sender.state == .on
    }

    @objc private func toggleKeepHistory(_ sender: NSButton) {
        Settings.keepHistory = sender.state == .on
        if !Settings.keepHistory {
            History.clear()
        }
    }

    @objc private func toggleOpenAtLogin(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            NSAlert(error: error).runModal()
        }
    }

    @objc private func openPrivacySettings() {
        ScreenAccess.openPrivacySettings()
    }
}

enum ScreenAccess {
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The first time, macOS shows its own prompt. After that, explain where the switch is.
    @MainActor
    static func requestAccess() {
        let firstAsk = !Settings.askedForScreenAccess
        Settings.askedForScreenAccess = true
        CGRequestScreenCaptureAccess()
        guard !firstAsk else { return }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Glimpse needs Screen Recording permission"
        alert.informativeText = """
        In System Settings → Privacy & Security → Screen & System Audio Recording, turn on Glimpse. \
        If macOS asks, quit and reopen Glimpse.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openPrivacySettings()
        }
    }
}
