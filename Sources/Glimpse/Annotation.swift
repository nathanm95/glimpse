import AppKit

enum Tool: CaseIterable {
    case pencil, line, arrow, rectangle, ellipse, marker, text

    var symbolName: String {
        switch self {
        case .pencil: "pencil"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .marker: "highlighter"
        case .text: "textformat"
        }
    }

    var name: String {
        switch self {
        case .pencil: "Pencil"
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .marker: "Marker"
        case .text: "Text"
        }
    }

    /// Single-key shortcut while a selection is showing.
    var key: Character {
        switch self {
        case .pencil: "p"
        case .line: "l"
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "e"
        case .marker: "m"
        case .text: "t"
        }
    }
}

/// One drawn mark. Points are in the overlay view's coordinates (points, origin bottom-left),
/// so the same drawing code serves the live overlay and the exported image.
struct Annotation {
    var tool: Tool
    var color: NSColor
    var width: CGFloat
    var points: [CGPoint]
    var text = ""

    static func font(forWidth width: CGFloat) -> NSFont {
        .systemFont(ofSize: max(12, 10 + width * 3), weight: .semibold)
    }

    static func textAttributes(color: NSColor, width: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: font(forWidth: width), .foregroundColor: color]
    }

    static func markerWidth(for width: CGFloat) -> CGFloat { width * 3 + 8 }

    /// Whether the mark is worth keeping (a click with the line tool draws nothing, for example).
    var isMeaningful: Bool {
        switch tool {
        case .pencil, .marker: return !points.isEmpty
        case .text: return !text.isEmpty
        case .line, .arrow, .rectangle, .ellipse:
            guard let a = points.first, let b = points.last else { return false }
            return Geometry.distance(a, b) >= 2
        }
    }

    private var rect: CGRect {
        guard let a = points.first, let b = points.last else { return .zero }
        return Geometry.rect(from: a, to: b)
    }

    /// Draws the mark. Text needs `NSGraphicsContext.current` to wrap `ctx`.
    func draw(in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(width)

        switch tool {
        case .pencil:
            strokeFreehand(in: ctx, color: color, width: width)
        case .marker:
            strokeFreehand(in: ctx, color: color.withAlphaComponent(0.4), width: Annotation.markerWidth(for: width))
        case .line:
            guard let a = points.first, let b = points.last else { return }
            ctx.strokeLineSegments(between: [a, b])
        case .arrow:
            drawArrow(in: ctx)
        case .rectangle:
            ctx.setLineJoin(.miter)
            ctx.stroke(rect)
        case .ellipse:
            ctx.strokeEllipse(in: rect)
        case .text:
            guard let origin = points.first else { return }
            NSAttributedString(string: text, attributes: Annotation.textAttributes(color: color, width: width)).draw(at: origin)
        }
    }

    private func strokeFreehand(in ctx: CGContext, color: NSColor, width: CGFloat) {
        guard let first = points.first else { return }
        if points.allSatisfy({ $0 == first }) {
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
            return
        }
        // Quadratic curves through the midpoints keep fast strokes smooth.
        let path = CGMutablePath()
        path.move(to: first)
        if points.count > 2 {
            for i in 1..<(points.count - 1) {
                let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
                path.addQuadCurve(to: mid, control: points[i])
            }
        }
        path.addLine(to: points[points.count - 1])
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.addPath(path)
        ctx.strokePath()
    }

    private func drawArrow(in ctx: CGContext) {
        guard let a = points.first, let b = points.last else { return }
        let length = Geometry.distance(a, b)
        guard length > 0 else { return }
        let headLength = min(max(12, width * 3.5), length)
        let halfHead = headLength * 0.5
        let ux = (b.x - a.x) / length
        let uy = (b.y - a.y) / length
        let base = CGPoint(x: b.x - ux * headLength, y: b.y - uy * headLength)

        // Stop the shaft just inside the head so its round cap doesn't poke out of the tip.
        ctx.strokeLineSegments(between: [a, CGPoint(x: base.x + ux, y: base.y + uy)])
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(x: base.x - uy * halfHead, y: base.y + ux * halfHead))
        ctx.addLine(to: CGPoint(x: base.x + uy * halfHead, y: base.y - ux * halfHead))
        ctx.closePath()
        ctx.fillPath()
    }
}

enum Geometry {
    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Moves `b` so the rectangle from `a` is a square (Shift-drag).
    static func squared(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let side = max(abs(b.x - a.x), abs(b.y - a.y))
        return CGPoint(x: a.x + (b.x >= a.x ? side : -side), y: a.y + (b.y >= a.y ? side : -side))
    }

    /// Moves `b` onto the nearest 45° line through `a` (Shift-drag).
    static func snapped45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let length = distance(a, b)
        let step = CGFloat.pi / 4
        let angle = (atan2(b.y - a.y, b.x - a.x) / step).rounded() * step
        return CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
    }
}
