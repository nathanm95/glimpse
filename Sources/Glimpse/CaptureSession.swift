import AppKit

/// One capture, from hotkey to copy/save/close. Owns an overlay per screen and the drawing
/// style they share.
@MainActor
final class CaptureSession: NSObject {
    private(set) var tool: Tool?
    private(set) var color = Settings.toolColor
    private(set) var lineWidth = Settings.lineWidth

    private var panels: [OverlayPanel] = []
    private var views: [OverlayView] = []
    private var previousApp: NSRunningApplication?
    private let onEnd: () -> Void
    private var finished = false

    init(grabs: [ScreenGrab], onEnd: @escaping () -> Void) {
        self.onEnd = onEnd
        super.init()
        for grab in grabs {
            let panel = OverlayPanel(screen: grab.screen)
            let view = OverlayView(frame: CGRect(origin: .zero, size: grab.screen.frame.size), image: grab.image, session: self)
            panel.contentView = view
            panels.append(panel)
            views.append(view)
        }
    }

    func begin() {
        previousApp = NSWorkspace.shared.frontmostApplication
        if previousApp == NSRunningApplication.current { previousApp = nil }
        for panel in panels {
            panel.orderFrontRegardless()
        }
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        if let index = panels.firstIndex(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? panels.indices.first {
            panels[index].makeKey()
            panels[index].makeFirstResponder(views[index])
        }
        NSCursor.crosshair.set()
    }

    // MARK: - Shared style

    func toggleTool(_ newTool: Tool) {
        tool = tool == newTool ? nil : newTool
        views.forEach { $0.toolDidChange() }
    }

    func setColor(_ newColor: NSColor) {
        color = newColor
        Settings.toolColor = newColor
        views.forEach { $0.styleDidChange() }
    }

    func adjustWidth(by delta: CGFloat) {
        lineWidth = min(max(lineWidth + delta, 1), 30)
        Settings.lineWidth = lineWidth
        views.forEach { $0.styleDidChange() }
    }

    func selectionDidBegin(in view: OverlayView) {
        for other in views where other !== view {
            other.clearSelection()
        }
    }

    func showColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        setColor(sender.color)
    }

    // MARK: - Actions

    private func renderSelection() -> RenderedImage? {
        guard let image = views.first(where: { $0.selection != nil })?.render() else {
            NSSound.beep()
            return nil
        }
        return image
    }

    func copyToClipboard() {
        guard let image = renderSelection() else { return }
        ImageExport.copyToPasteboard(image)
        History.add(image)
        finish()
    }

    func save() {
        guard let image = renderSelection() else { return }
        setOverlaysVisible(false)
        NSApp.activate()
        if let (url, format) = ImageExport.chooseSaveLocation() {
            do {
                try ImageExport.write(image, to: url, format: format)
                History.add(image)
                finish()
                return
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        setOverlaysVisible(true)
    }

    func printImage() {
        guard let image = renderSelection() else { return }
        setOverlaysVisible(false)
        NSApp.activate()
        if ImageExport.print(image) {
            History.add(image)
            finish()
        } else {
            setOverlaysVisible(true)
        }
    }

    func cancel() {
        finish()
    }

    private func setOverlaysVisible(_ visible: Bool) {
        guard visible else {
            panels.forEach { $0.orderOut(nil) }
            return
        }
        for panel in panels {
            panel.orderFrontRegardless()
        }
        if let index = views.firstIndex(where: { $0.selection != nil }) ?? panels.indices.first {
            panels[index].makeKey()
            panels[index].makeFirstResponder(views[index])
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        if NSColorPanel.sharedColorPanelExists {
            let colorPanel = NSColorPanel.shared
            colorPanel.setTarget(nil)
            colorPanel.setAction(nil)
            colorPanel.orderOut(nil)
            colorPanel.level = .floating
        }
        panels.forEach { $0.orderOut(nil) }
        if let previousApp {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate(from: .current, options: [])
        }
        // Tear down on the next turn of the run loop: this is often called from a button
        // inside one of the overlays, which must outlive its own click handler.
        DispatchQueue.main.async { [panels, onEnd] in
            panels.forEach { $0.close() }
            onEnd()
        }
    }
}
