import AppKit

/// A square toolbar button drawn with an SF Symbol, or a colour swatch.
final class ToolButton: NSView {
    static let side: CGFloat = 30

    var symbolName: String? { didSet { needsDisplay = true } }
    var swatch: NSColor? { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    private let action: () -> Void
    private var isHovered = false
    private var isPressed = false

    init(symbol: String?, tooltip: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        symbolName = symbol
        toolTip = tooltip
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { isPressed = true; needsDisplay = true }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != isPressed { isPressed = inside; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        needsDisplay = true
        if inside { action() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected || isPressed || isHovered {
            let tint = isSelected ? NSColor.controlAccentColor : NSColor.labelColor
            tint.withAlphaComponent(isSelected ? 0.25 : (isPressed ? 0.18 : 0.08)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        if let swatch {
            let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 8, dy: 8))
            swatch.setFill()
            circle.fill()
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            circle.lineWidth = 1
            circle.stroke()
        } else if let symbolName,
                  let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)?
                      .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) {
            let size = image.size
            let target = backingAlignedRect(
                CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height),
                options: .alignAllEdgesNearest
            )
            image.tinted(isSelected ? .controlAccentColor : .labelColor).draw(in: target)
        }
    }
}

/// A rounded bar of tool buttons, laid out top-to-bottom or left-to-right.
final class ToolbarView: NSView {
    enum Item {
        case button(ToolButton)
        case separator
    }

    private let vertical: Bool
    private let items: [Item]
    private var separatorRects: [CGRect] = []
    private let padding: CGFloat = 4
    private let separatorLength: CGFloat = 9

    init(vertical: Bool, items: [Item]) {
        self.vertical = vertical
        self.items = items
        super.init(frame: .zero)
        wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        self.shadow = shadow
        for case .button(let button) in items {
            addSubview(button)
        }
        layOutItems()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layOutItems() {
        let along = items.reduce(padding * 2) { total, item in
            if case .button = item { return total + ToolButton.side }
            return total + separatorLength
        }
        let across = ToolButton.side + padding * 2
        setFrameSize(vertical ? NSSize(width: across, height: along) : NSSize(width: along, height: across))

        var offset = padding
        separatorRects = []
        for item in items {
            let length: CGFloat
            if case .button = item { length = ToolButton.side } else { length = separatorLength }
            let slot = vertical
                ? CGRect(x: padding, y: frame.height - offset - length, width: ToolButton.side, height: length)
                : CGRect(x: offset, y: padding, width: length, height: ToolButton.side)
            switch item {
            case .button(let button): button.frame = slot
            case .separator: separatorRects.append(slot)
            }
            offset += length
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Swallow clicks on the padding so they don't start a new selection underneath.
    override func mouseDown(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.setFill()
        background.fill()
        NSColor.separatorColor.setStroke()
        background.lineWidth = 1
        background.stroke()

        NSColor.separatorColor.setFill()
        for slot in separatorRects {
            let line = vertical
                ? CGRect(x: slot.minX + 5, y: slot.midY - 0.5, width: slot.width - 10, height: 1)
                : CGRect(x: slot.midX - 0.5, y: slot.minY + 5, width: 1, height: slot.height - 10)
            line.fill()
        }
    }
}

/// The swatch grid shown by the colour button, with a way out to the system colour panel.
final class ColorPaletteView: NSView {
    var onPick: ((NSColor) -> Void)?
    var onCustom: (() -> Void)?

    private let selected: NSColor
    private let swatchSize: CGFloat = 22
    private let gap: CGFloat = 6
    private let padding: CGFloat = 10
    private let columns = 6
    private let customHeight: CGFloat = 24

    init(selected: NSColor) {
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        self.shadow = shadow
        let rows = (Palette.colors.count + columns - 1) / columns
        let width = padding * 2 + CGFloat(columns) * swatchSize + CGFloat(columns - 1) * gap
        let height = padding * 2 + CGFloat(rows) * swatchSize + CGFloat(rows - 1) * gap + gap + customHeight
        setFrameSize(NSSize(width: width, height: height))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func swatchRect(_ index: Int) -> CGRect {
        let row = index / columns
        let column = index % columns
        return CGRect(
            x: padding + CGFloat(column) * (swatchSize + gap),
            y: bounds.height - padding - swatchSize - CGFloat(row) * (swatchSize + gap),
            width: swatchSize,
            height: swatchSize
        )
    }

    private var customRect: CGRect {
        CGRect(x: padding, y: padding, width: bounds.width - padding * 2, height: customHeight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = Palette.colors.indices.first(where: { swatchRect($0).insetBy(dx: -2, dy: -2).contains(point) }) {
            onPick?(Palette.colors[index])
        } else if customRect.contains(point) {
            onCustom?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.setFill()
        background.fill()
        NSColor.separatorColor.setStroke()
        background.stroke()

        for (index, color) in Palette.colors.enumerated() {
            let rect = swatchRect(index)
            let circle = NSBezierPath(ovalIn: rect)
            color.setFill()
            circle.fill()
            NSColor.labelColor.withAlphaComponent(0.3).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            if color.isEqualIgnoringSpace(selected) {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -3, dy: -3))
                NSColor.controlAccentColor.setStroke()
                ring.lineWidth = 2
                ring.stroke()
            }
        }

        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: customRect, xRadius: 5, yRadius: 5).fill()
        let label = NSAttributedString(string: "Custom…", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor
        ])
        let size = label.size()
        label.draw(at: CGPoint(x: customRect.midX - size.width / 2, y: customRect.midY - size.height / 2))
    }
}

extension NSImage {
    /// A copy filled with `color`, resolved at draw time so it follows light and dark mode.
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

extension NSColor {
    func isEqualIgnoringSpace(_ other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01
            && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }
}
