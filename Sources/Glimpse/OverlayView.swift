import AppKit
import Carbon.HIToolbox

/// A borderless full-screen panel above everything, including the menu bar and Dock.
/// It is non-activating so it can take key presses without pulling focus from other apps.
final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The frozen screen image with a dimming layer that leaves the selection clear.
private final class BackgroundView: NSView {
    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()

    init(frame: NSRect, image: CGImage) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        imageLayer.contents = image
        imageLayer.contentsGravity = .resize
        imageLayer.frame = bounds
        dimLayer.frame = bounds
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(dimLayer)
        setClearArea(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setClearArea(_ rect: CGRect?) {
        let path = CGMutablePath()
        path.addRect(bounds)
        if let rect { path.addRect(rect) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.path = path
        CATransaction.commit()
    }
}

/// Transparent layer for annotations and the selection frame; the overlay does the drawing.
private final class CanvasView: NSView {
    weak var overlay: OverlayView?

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        overlay?.drawCanvas()
    }
}

private enum Handle: CaseIterable {
    case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left

    var isLeft: Bool { self == .bottomLeft || self == .left || self == .topLeft }
    var isRight: Bool { self == .bottomRight || self == .right || self == .topRight }
    var isBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var isTop: Bool { self == .topLeft || self == .top || self == .topRight }

    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: isLeft ? rect.minX : (isRight ? rect.maxX : rect.midX),
                y: isBottom ? rect.minY : (isTop ? rect.maxY : rect.midY))
    }

    /// Corners within a few points, or anywhere along an edge.
    static func hit(_ p: CGPoint, in rect: CGRect) -> Handle? {
        let cornerReach: CGFloat = 8
        let edgeReach: CGFloat = 5
        for corner in [Handle.bottomLeft, .bottomRight, .topRight, .topLeft]
        where Geometry.distance(p, corner.point(in: rect)) <= cornerReach {
            return corner
        }
        let withinX = p.x >= rect.minX - edgeReach && p.x <= rect.maxX + edgeReach
        let withinY = p.y >= rect.minY - edgeReach && p.y <= rect.maxY + edgeReach
        if withinY && abs(p.x - rect.minX) <= edgeReach { return .left }
        if withinY && abs(p.x - rect.maxX) <= edgeReach { return .right }
        if withinX && abs(p.y - rect.minY) <= edgeReach { return .bottom }
        if withinX && abs(p.y - rect.maxY) <= edgeReach { return .top }
        return nil
    }

    func resize(_ rect: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if isLeft { minX += dx }
        if isRight { maxX += dx }
        if isBottom { minY += dy }
        if isTop { maxY += dy }
        return Geometry.rect(from: CGPoint(x: minX, y: minY), to: CGPoint(x: maxX, y: maxY))
    }

    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition = switch self {
            case .bottomLeft: .bottomLeft
            case .bottom: .bottom
            case .bottomRight: .bottomRight
            case .right: .right
            case .topRight: .topRight
            case .top: .top
            case .topLeft: .topLeft
            case .left: .left
            }
            return .frameResize(position: position, directions: .all)
        }
        switch self {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }
}

private enum DragState {
    case idle
    /// `active` turns true once the pointer has moved far enough to count as a drag.
    case selecting(start: CGPoint, active: Bool)
    case moving(start: CGPoint, original: CGRect)
    case resizing(handle: Handle, original: CGRect, start: CGPoint)
    case drawing
}

/// One screen's worth of the capture UI: frozen image, selection, annotations and toolbars.
final class OverlayView: NSView, NSTextFieldDelegate {
    unowned let session: CaptureSession
    let image: CGImage

    private let background: BackgroundView
    private let canvas: CanvasView
    private var drawBar: ToolbarView!
    private var actionBar: ToolbarView!
    private var toolButtons: [Tool: ToolButton] = [:]
    private var colorButton: ToolButton!
    private var palette: ColorPaletteView?
    private var textField: NSTextField?

    private(set) var selection: CGRect?
    private var annotations: [Annotation] = []
    private var current: Annotation?
    private var drag = DragState.idle
    private var widthHintPoint: CGPoint?
    private var widthHintTimer: Timer?
    private var scrollAccumulator: CGFloat = 0

    init(frame: NSRect, image: CGImage, session: CaptureSession) {
        self.image = image
        self.session = session
        let local = CGRect(origin: .zero, size: frame.size)
        background = BackgroundView(frame: local, image: image)
        canvas = CanvasView(frame: local)
        super.init(frame: frame)
        wantsLayer = true
        canvas.wantsLayer = true
        canvas.overlay = self
        addSubview(background)
        addSubview(canvas)
        buildToolbars()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Output pixels per view point, which is what the size badge reports.
    private var outputScale: CGFloat {
        Settings.downscaleRetina ? 1 : CGFloat(image.width) / bounds.width
    }

    // MARK: - Toolbars

    private func buildToolbars() {
        var drawItems: [ToolbarView.Item] = []
        for tool in Tool.allCases {
            let button = ToolButton(symbol: tool.symbolName, tooltip: "\(tool.name) (\(tool.key.uppercased()))") { [unowned self] in
                session.toggleTool(tool)
            }
            toolButtons[tool] = button
            drawItems.append(.button(button))
        }
        colorButton = ToolButton(symbol: nil, tooltip: "Colour") { [unowned self] in togglePalette() }
        colorButton.swatch = session.color
        drawItems.append(.separator)
        drawItems.append(.button(colorButton))
        drawItems.append(.button(ToolButton(symbol: "arrow.uturn.backward", tooltip: "Undo (⌘Z)") { [unowned self] in undo() }))
        drawBar = ToolbarView(vertical: true, items: drawItems)

        actionBar = ToolbarView(vertical: false, items: [
            .button(ToolButton(symbol: "printer", tooltip: "Print (⌘P)") { [unowned self] in session.printImage() }),
            .button(ToolButton(symbol: "doc.on.doc", tooltip: "Copy (⌘C)") { [unowned self] in session.copyToClipboard() }),
            .button(ToolButton(symbol: "square.and.arrow.down", tooltip: "Save (⌘S)") { [unowned self] in session.save() }),
            .separator,
            .button(ToolButton(symbol: "xmark", tooltip: "Close (Esc)") { [unowned self] in session.cancel() })
        ])

        for bar in [drawBar!, actionBar!] {
            bar.isHidden = true
            addSubview(bar)
        }
    }

    /// Lightshot's placement: tools down the right of the selection, actions along the bottom,
    /// falling back to the other side or inside when the screen edge is in the way.
    private func layOutToolbars() {
        guard let selection, case .idle = drag else {
            drawBar.isHidden = true
            actionBar.isHidden = true
            return
        }
        let gap: CGFloat = 8
        let margin: CGFloat = 4
        let drawSize = drawBar.frame.size
        let actionSize = actionBar.frame.size

        var drawX = selection.maxX + gap
        if drawX + drawSize.width > bounds.maxX - margin {
            drawX = selection.minX - gap - drawSize.width
            if drawX < margin { drawX = selection.maxX - gap - drawSize.width }
        }
        var drawFrame = CGRect(origin: CGPoint(x: drawX, y: selection.minY), size: drawSize)

        var actionY = selection.minY - gap - actionSize.height
        if actionY < margin {
            actionY = selection.maxY + gap
            if actionY + actionSize.height > bounds.maxY - margin { actionY = selection.minY + gap }
        }
        var actionFrame = CGRect(origin: CGPoint(x: selection.maxX - actionSize.width, y: actionY), size: actionSize)
        actionFrame.origin.x = min(max(actionFrame.minX, margin), bounds.maxX - actionSize.width - margin)

        if drawFrame.intersects(actionFrame) {
            drawFrame.origin.y = actionFrame.maxY + gap
        }
        drawFrame.origin.y = min(max(drawFrame.minY, margin), bounds.maxY - drawSize.height - margin)

        drawBar.frame = drawFrame
        actionBar.frame = actionFrame
        drawBar.isHidden = false
        actionBar.isHidden = false
        positionPalette()
    }

    private func togglePalette() {
        if palette == nil { showPalette() } else { hidePalette() }
    }

    private func showPalette() {
        let palette = ColorPaletteView(selected: session.color)
        palette.onPick = { [unowned self] color in
            session.setColor(color)
            hidePalette()
        }
        palette.onCustom = { [unowned self] in
            hidePalette()
            session.showColorPanel()
        }
        addSubview(palette)
        self.palette = palette
        positionPalette()
    }

    private func hidePalette() {
        palette?.removeFromSuperview()
        palette = nil
    }

    private func positionPalette() {
        guard let palette else { return }
        let size = palette.frame.size
        let anchor = convert(colorButton.bounds, from: colorButton)
        var x = drawBar.frame.maxX + 8
        if x + size.width > bounds.maxX - 4 { x = drawBar.frame.minX - 8 - size.width }
        let y = min(max(anchor.midY - size.height / 2, 4), bounds.maxY - size.height - 4)
        palette.setFrameOrigin(CGPoint(x: x, y: y))
    }

    // MARK: - Session callbacks

    func toolDidChange() {
        commitText()
        for (tool, button) in toolButtons {
            button.isSelected = tool == session.tool
        }
        refreshCursor()
    }

    func styleDidChange() {
        colorButton.swatch = session.color
        if let textField {
            textField.textColor = session.color
            textField.font = Annotation.font(forWidth: session.lineWidth)
            fitTextField()
        }
        canvas.needsDisplay = true
    }

    /// Called when a selection starts on another screen.
    func clearSelection() {
        cancelText()
        hidePalette()
        annotations.removeAll()
        current = nil
        setSelection(nil)
    }

    func render() -> RenderedImage? {
        commitText()
        guard let selection else { return nil }
        return Renderer.render(image: image, viewSize: bounds.size, selection: selection,
                               annotations: annotations, downscale: Settings.downscaleRetina)
    }

    func debugConfigure(selection: CGRect, annotations: [Annotation], showingPalette: Bool) {
        self.annotations = annotations
        setSelection(selection)
        if showingPalette { showPalette() }
    }

    // MARK: - Selection

    private func setSelection(_ rect: CGRect?, interacting: Bool = false) {
        selection = rect
        background.setClearArea(rect)
        canvas.needsDisplay = true
        if interacting {
            drawBar.isHidden = true
            actionBar.isHidden = true
            hidePalette()
        } else {
            layOutToolbars()
        }
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func undo() {
        guard !annotations.isEmpty else { NSSound.beep(); return }
        annotations.removeLast()
        canvas.needsDisplay = true
    }

    private func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard var rect = selection else { return }
        rect.origin.x = min(max(rect.minX + dx, 0), bounds.width - rect.width)
        rect.origin.y = min(max(rect.minY + dy, 0), bounds.height - rect.height)
        setSelection(rect)
    }

    // MARK: - Mouse

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: location(of: event)) }
    override func mouseMoved(with event: NSEvent) { updateCursor(at: location(of: event)) }

    private func refreshCursor() {
        guard let window else { return }
        updateCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func updateCursor(at p: CGPoint) {
        switch drag {
        case .moving:
            NSCursor.closedHand.set()
            return
        case .drawing, .resizing:
            return
        case .idle, .selecting:
            break
        }
        let floating: [NSView] = [drawBar, actionBar, palette].compactMap { $0 }.filter { !$0.isHidden }
        if floating.contains(where: { $0.frame.contains(p) }) {
            NSCursor.arrow.set()
            return
        }
        guard let selection else {
            NSCursor.crosshair.set()
            return
        }
        if let handle = Handle.hit(p, in: selection) {
            handle.cursor.set()
        } else if let tool = session.tool {
            (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
        } else {
            (selection.contains(p) ? NSCursor.openHand : NSCursor.crosshair).set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = location(of: event)
        window?.makeKey()
        hidePalette()
        if textField != nil {
            commitText()
            return
        }
        if let selection {
            if let handle = Handle.hit(p, in: selection) {
                drag = .resizing(handle: handle, original: selection, start: p)
                return
            }
            if let tool = session.tool {
                if tool == .text {
                    beginText(at: p)
                } else {
                    current = Annotation(tool: tool, color: session.color, width: session.lineWidth, points: [p])
                    drag = .drawing
                    canvas.needsDisplay = true
                }
                return
            }
            if selection.contains(p) {
                drag = .moving(start: p, original: selection)
                NSCursor.closedHand.set()
                return
            }
        }
        drag = .selecting(start: p, active: false)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clamped(location(of: event))
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .idle:
            break
        case .selecting(let start, let active):
            guard active || Geometry.distance(start, p) > 2 else { return }
            if !active {
                session.selectionDidBegin(in: self)
                drag = .selecting(start: start, active: true)
            }
            let end = shift ? clamped(Geometry.squared(from: start, to: p)) : p
            setSelection(Geometry.rect(from: start, to: end), interacting: true)
        case .moving(let start, let original):
            var rect = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            rect.origin.x = min(max(rect.minX, 0), bounds.width - rect.width)
            rect.origin.y = min(max(rect.minY, 0), bounds.height - rect.height)
            setSelection(rect, interacting: true)
        case .resizing(let handle, let original, let start):
            setSelection(handle.resize(original, dx: p.x - start.x, dy: p.y - start.y), interacting: true)
        case .drawing:
            guard var annotation = current, let first = annotation.points.first else { return }
            switch annotation.tool {
            case .pencil, .marker:
                if let last = annotation.points.last, Geometry.distance(last, p) >= 1 {
                    annotation.points.append(p)
                }
            case .line, .arrow:
                annotation.points = [first, shift ? Geometry.snapped45(from: first, to: p) : p]
            case .rectangle, .ellipse:
                annotation.points = [first, shift ? Geometry.squared(from: first, to: p) : p]
            case .text:
                break
            }
            current = annotation
            canvas.needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .drawing = drag, let annotation = current {
            if annotation.isMeaningful { annotations.append(annotation) }
            current = nil
            canvas.needsDisplay = true
        }
        drag = .idle
        if let selection, selection.width < 2 || selection.height < 2 {
            setSelection(nil)
        } else {
            setSelection(selection)
        }
        updateCursor(at: location(of: event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard selection != nil else { return }
        scrollAccumulator += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 6 : event.scrollingDeltaY
        let steps = scrollAccumulator.rounded(.towardZero)
        guard steps != 0 else { return }
        scrollAccumulator -= steps
        session.adjustWidth(by: steps)
        showWidthHint(at: location(of: event))
    }

    private func showWidthHint(at point: CGPoint) {
        widthHintPoint = point
        canvas.needsDisplay = true
        widthHintTimer?.invalidate()
        widthHintTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.widthHintPoint = nil
                self?.canvas.needsDisplay = true
            }
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_Escape: session.cancel()
        case kVK_LeftArrow: nudgeSelection(dx: -step, dy: 0)
        case kVK_RightArrow: nudgeSelection(dx: step, dy: 0)
        case kVK_UpArrow: nudgeSelection(dx: 0, dy: step)
        case kVK_DownArrow: nudgeSelection(dx: 0, dy: -step)
        default:
            guard selection != nil,
                  event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
                  let key = event.charactersIgnoringModifiers?.lowercased().first else {
                super.keyDown(with: event)
                return
            }
            if let tool = Tool.allCases.first(where: { $0.key == key }) {
                session.toggleTool(tool)
            } else if key == "[" || key == "]" {
                session.adjustWidth(by: key == "]" ? 1 : -1)
                refreshWidthHint()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func refreshWidthHint() {
        guard let window else { return }
        showWidthHint(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        // While typing a label, the usual editing shortcuts belong to the text.
        if let editor = textField?.currentEditor() {
            switch key {
            case "c": editor.copy(nil)
            case "v": editor.paste(nil)
            case "x": editor.cut(nil)
            case "a": editor.selectAll(nil)
            case "z": editor.undoManager?.undo()
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        switch key {
        case "c": session.copyToClipboard()
        case "s": session.save()
        case "p": session.printImage()
        case "z": undo()
        case "w": session.cancel()
        case "a":
            session.selectionDidBegin(in: self)
            setSelection(bounds)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    // MARK: - Text

    private func beginText(at point: CGPoint) {
        let field = NSTextField(string: "")
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Annotation.font(forWidth: session.lineWidth)
        field.textColor = session.color
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        let height = ceil(field.cell?.cellSize.height ?? 24)
        field.frame = CGRect(x: point.x - 2, y: point.y - height / 2, width: 24, height: height)
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
        fitTextField()
    }

    private func fitTextField() {
        guard let field = textField, let font = field.font else { return }
        let width = (field.stringValue as NSString).size(withAttributes: [.font: font]).width
        let height = ceil(field.cell?.cellSize.height ?? field.frame.height)
        field.frame = CGRect(x: field.frame.minX, y: field.frame.midY - height / 2, width: max(24, ceil(width) + 14), height: height)
        canvas.needsDisplay = true
    }

    func controlTextDidChange(_ notification: Notification) {
        fitTextField()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitText()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commitText()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelText()
            return true
        }
        return false
    }

    private func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue
        if !text.isEmpty {
            let attributes = Annotation.textAttributes(color: field.textColor ?? session.color, width: session.lineWidth)
            let size = (text as NSString).size(withAttributes: attributes)
            // Borderless fields inset their text by the 2pt line fragment padding.
            let origin = CGPoint(x: field.frame.minX + 2, y: field.frame.midY - size.height / 2)
            annotations.append(Annotation(tool: .text, color: field.textColor ?? session.color,
                                          width: session.lineWidth, points: [origin], text: text))
        }
        window?.makeFirstResponder(self)
        field.removeFromSuperview()
        canvas.needsDisplay = true
    }

    private func cancelText() {
        guard let field = textField else { return }
        textField = nil
        window?.makeFirstResponder(self)
        field.removeFromSuperview()
        canvas.needsDisplay = true
    }

    // MARK: - Drawing

    fileprivate func drawCanvas() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if let selection {
            ctx.saveGState()
            ctx.clip(to: selection)
            for annotation in annotations {
                annotation.draw(in: ctx)
            }
            current?.draw(in: ctx)
            ctx.restoreGState()
            drawSelectionFrame(selection, in: ctx)
        }

        if let field = textField {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.stroke(field.frame.insetBy(dx: -3, dy: -2))
            ctx.restoreGState()
        }

        if let point = widthHintPoint {
            drawWidthHint(at: point, in: ctx)
        }
    }

    private func drawSelectionFrame(_ selection: CGRect, in ctx: CGContext) {
        let frame = selection.insetBy(dx: -0.5, dy: -0.5)
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.stroke(frame)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        ctx.stroke(frame)
        ctx.setLineDash(phase: 0, lengths: [])

        for handle in Handle.allCases {
            let center = handle.point(in: selection)
            let square = CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(square)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.stroke(square.insetBy(dx: 0.5, dy: 0.5))
        }
        ctx.restoreGState()

        let label = NSAttributedString(
            string: "\(Int((selection.width * outputScale).rounded())) × \(Int((selection.height * outputScale).rounded()))",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white
            ]
        )
        let size = label.size()
        var badge = CGRect(x: selection.minX, y: selection.maxY + 5, width: ceil(size.width) + 12, height: ceil(size.height) + 6)
        if badge.maxY > bounds.maxY { badge.origin.y = selection.maxY - badge.height - 5 }
        badge.origin.x = min(max(badge.minX, 0), bounds.maxX - badge.width)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        label.draw(at: CGPoint(x: badge.minX + 6, y: badge.minY + 3))
    }

    private func drawWidthHint(at point: CGPoint, in ctx: CGContext) {
        let tool = session.tool ?? .pencil
        let diameter = tool == .marker ? Annotation.markerWidth(for: session.lineWidth) : session.lineWidth
        let label = NSAttributedString(string: "\(Int(session.lineWidth)) px", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ])
        let labelSize = label.size()
        let box = CGRect(x: point.x + 14, y: point.y - 14 - max(diameter, labelSize.height) - 8,
                         width: diameter + labelSize.width + 22, height: max(diameter, labelSize.height) + 8)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        let dot = CGRect(x: box.minX + 6, y: box.midY - diameter / 2, width: diameter, height: diameter)
        ctx.setFillColor(session.color.withAlphaComponent(tool == .marker ? 0.4 : 1).cgColor)
        ctx.fillEllipse(in: dot)
        label.draw(at: CGPoint(x: dot.maxX + 6, y: box.midY - labelSize.height / 2))
    }
}
