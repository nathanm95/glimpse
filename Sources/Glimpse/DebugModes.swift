import AppKit

/// Offline checks that need no Screen Recording permission:
///   Glimpse --render-test out.png   exported image (crop + every annotation type)
///   Glimpse --ui-snapshot out.png   the overlay UI (selection, toolbars, palette) on a fake desktop
@MainActor
enum DebugModes {
    static func run(_ arguments: [String]) -> Bool {
        for flag in ["--render-test", "--ui-snapshot", "--history-test"] {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { continue }
            let url = URL(fileURLWithPath: arguments[index + 1])
            let ok = switch flag {
            case "--render-test": renderTest(to: url)
            case "--ui-snapshot": uiSnapshot(to: url)
            default: historyTest(thumbnailTo: url)
            }
            print(ok ? "OK \(flag) → \(url.path)" : "FAILED \(flag)")
            return true
        }
        return false
    }

    /// Run with GLIMPSE_HISTORY_DIR set to an empty scratch folder. Adds more screenshots than
    /// the limit, checks only the newest are kept, writes the newest's menu thumbnail to `url`,
    /// and copies it to a private pasteboard (not the real clipboard).
    private static func historyTest(thumbnailTo url: URL) -> Bool {
        guard ProcessInfo.processInfo.environment["GLIMPSE_HISTORY_DIR"] != nil,
              let image = fakeDesktop(size: viewSize, scale: 2) else {
            print("Set GLIMPSE_HISTORY_DIR to a scratch folder first")
            return false
        }
        let widths: [CGFloat] = [100, 200, 300, 400, 500, 600, 700]
        for width in widths {
            let selection = CGRect(x: 100, y: 100, width: width, height: 300)
            guard let rendered = Renderer.render(image: image, viewSize: viewSize, selection: selection,
                                                 annotations: [], downscale: false) else { return false }
            History.add(rendered)
            History.waitForPendingWork()
            Thread.sleep(forTimeInterval: 0.01) // distinct millisecond timestamps
        }
        let entries = History.entries()
        let sizes = entries.map { "\(Int($0.pixelSize.width))×\(Int($0.pixelSize.height))" }
        print("entries (newest first): \(sizes.joined(separator: ", "))")
        let expected = widths.suffix(History.limit).reversed().map { "\(Int($0 * 2))×600" }
        guard sizes == Array(expected) else {
            print("expected: \(expected.joined(separator: ", "))")
            return false
        }

        guard let newest = entries.first,
              let thumbnail = History.thumbnail(for: newest),
              let tiff = thumbnail.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
              (try? png.write(to: url)) != nil else { return false }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Glimpse.HistoryTest"))
        defer { pasteboard.releaseGlobally() }
        guard History.copyToPasteboard(newest, pasteboard: pasteboard),
              let pasted = pasteboard.data(forType: .png),
              let rep = NSBitmapImageRep(data: pasted) else { return false }
        print("pasteboard types: \(pasteboard.types?.map(\.rawValue) ?? [])")
        print("pasted image: \(rep.pixelsWide)×\(rep.pixelsHigh) px, \(Int(rep.size.width))×\(Int(rep.size.height)) pt")
        return rep.pixelsWide == 1400 && rep.pixelsHigh == 600
    }

    private static let viewSize = CGSize(width: 1000, height: 620)
    private static let selection = CGRect(x: 160, y: 150, width: 560, height: 330)

    private static func renderTest(to url: URL) -> Bool {
        guard let image = fakeDesktop(size: viewSize, scale: 2),
              let rendered = Renderer.render(image: image, viewSize: viewSize, selection: selection,
                                             annotations: sampleAnnotations(), downscale: false),
              let data = ImageExport.data(for: rendered, format: .png) else { return false }
        return (try? data.write(to: url)) != nil
    }

    private static func uiSnapshot(to url: URL) -> Bool {
        _ = NSApplication.shared
        guard let image = fakeDesktop(size: viewSize, scale: 2) else { return false }
        let session = CaptureSession(grabs: [], onEnd: {})
        let view = OverlayView(frame: CGRect(origin: .zero, size: viewSize), image: image, session: session)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        session.toggleTool(.arrow)
        view.toolDidChange()
        view.debugConfigure(selection: selection, annotations: sampleAnnotations(), showingPalette: true)
        view.layoutSubtreeIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let ui = rep.cgImage else { return false }

        // The frozen image and dimming live in a layer-hosting view that cacheDisplay skips,
        // so composite them underneath here.
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let scale = CGFloat(width) / viewSize.width
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return false }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.draw(image, in: full)
        let dim = CGMutablePath()
        dim.addRect(full)
        dim.addRect(CGRect(x: selection.minX * scale, y: selection.minY * scale,
                           width: selection.width * scale, height: selection.height * scale))
        ctx.addPath(dim)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.draw(ui, in: full)
        guard let output = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    private static func sampleAnnotations() -> [Annotation] {
        let red = Palette.colors[0]
        let wiggle = (0...40).map { i -> CGPoint in
            let t = CGFloat(i) / 40
            return CGPoint(x: 200 + t * 160, y: 420 + sin(t * .pi * 3) * 18)
        }
        return [
            Annotation(tool: .rectangle, color: red, width: 3, points: [CGPoint(x: 400, y: 330), CGPoint(x: 560, y: 410)]),
            Annotation(tool: .ellipse, color: Palette.colors[5], width: 3, points: [CGPoint(x: 590, y: 200), CGPoint(x: 690, y: 260)]),
            Annotation(tool: .arrow, color: red, width: 4, points: [CGPoint(x: 260, y: 230), CGPoint(x: 395, y: 325)]),
            Annotation(tool: .line, color: Palette.colors[3], width: 2, points: [CGPoint(x: 190, y: 180), CGPoint(x: 360, y: 180)]),
            Annotation(tool: .marker, color: Palette.colors[2], width: 3, points: [CGPoint(x: 420, y: 300), CGPoint(x: 600, y: 300)]),
            Annotation(tool: .pencil, color: Palette.colors[7], width: 3, points: wiggle),
            Annotation(tool: .text, color: red, width: 3, points: [CGPoint(x: 200, y: 360)], text: "Check this bit"),
            // Runs past the selection to prove annotations are clipped to it.
            Annotation(tool: .line, color: red, width: 3, points: [CGPoint(x: 650, y: 440), CGPoint(x: 820, y: 560)])
        ]
    }

    /// A stand-in desktop: gradient wallpaper, a window with a title bar and some text.
    private static func fakeDesktop(size: CGSize, scale: CGFloat) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.32, blue: 0.55, alpha: 1),
                   ending: NSColor(srgbRed: 0.55, green: 0.33, blue: 0.62, alpha: 1))?
            .draw(in: CGRect(origin: .zero, size: size), angle: 35)

        let window = CGRect(x: 120, y: 110, width: 640, height: 420)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: window, xRadius: 10, yRadius: 10).fill()
        NSColor(white: 0.93, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(x: window.minX, y: window.maxY - 30, width: window.width, height: 20)).fill()
        NSBezierPath(roundedRect: CGRect(x: window.minX, y: window.maxY - 30, width: window.width, height: 30), xRadius: 10, yRadius: 10).fill()
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: window.minX + 12 + CGFloat(i) * 20, y: window.maxY - 21, width: 12, height: 12)).fill()
        }
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.darkGray]
        let lines = [
            "Release checklist",
            "Write the release notes",
            "Update the screenshots",
            "Tag version 1.0",
            "Celebrate"
        ]
        for (i, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: body).draw(at: CGPoint(x: window.minX + 40, y: window.maxY - 80 - CGFloat(i) * 34))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
