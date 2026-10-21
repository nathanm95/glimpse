import AppKit
import ImageIO

/// The last few finished screenshots (copied, saved or printed), kept as PNGs in
/// Application Support so the menu bar menu can put them back on the clipboard.
enum History {
    static let limit = 5

    struct Entry {
        let url: URL
        let date: Date
        let pixelSize: CGSize
    }

    private static let queue = DispatchQueue(label: "Glimpse.History", qos: .utility)

    /// GLIMPSE_HISTORY_DIR points the offline test at a scratch folder.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["GLIMPSE_HISTORY_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glimpse/History", isDirectory: true)
    }

    /// Blocks until queued writes and deletes have finished (for the offline test).
    static func waitForPendingWork() {
        queue.sync {}
    }

    /// Encoding a full-screen PNG takes a moment, so it happens off the main thread.
    static func add(_ image: RenderedImage) {
        guard Settings.keepHistory else { return }
        let date = Date()
        queue.async {
            guard let data = ImageExport.data(for: image, format: .png) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            try? data.write(to: directory.appendingPathComponent("\(formatter.string(from: date)).png"), options: .atomic)
            prune()
        }
    }

    /// Newest first. File names are timestamps, so name order is date order.
    static func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .compactMap { url in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                return Entry(url: url, date: date, pixelSize: CGSize(width: width, height: height))
            }
    }

    @discardableResult
    static func copyToPasteboard(_ entry: Entry, pasteboard: NSPasteboard = .general) -> Bool {
        guard let png = try? Data(contentsOf: entry.url) else { return false }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A menu-sized thumbnail. Every thumbnail has the same footprint so the titles line up.
    static func thumbnail(for entry: Entry, fitting box: CGSize = CGSize(width: 72, height: 44)) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(box.width, box.height) * 3)
        ]
        guard let source = CGImageSourceCreateWithURL(entry.url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let aspect = CGFloat(thumb.width) / CGFloat(thumb.height)
        let size = aspect > box.width / box.height
            ? CGSize(width: box.width, height: box.width / aspect)
            : CGSize(width: box.height * aspect, height: box.height)
        return NSImage(size: box, flipped: false) { _ in
            let rect = CGRect(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2,
                              width: size.width, height: size.height)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSImage(cgImage: thumb, size: size).draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.separatorColor.setStroke()
            shape.lineWidth = 1
            shape.stroke()
            return true
        }
    }

    private static func prune() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls.filter({ $0.pathExtension == "png" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(limit) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
