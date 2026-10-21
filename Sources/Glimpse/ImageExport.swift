import AppKit

enum ImageExport {
    static func data(for image: RenderedImage, format: ImageFormat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image.cgImage)
        rep.size = image.pointSize
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }

    static func copyToPasteboard(_ image: RenderedImage) {
        let item = NSPasteboardItem()
        if let png = data(for: image, format: .png) {
            item.setData(png, forType: .png)
        }
        let rep = NSBitmapImageRep(cgImage: image.cgImage)
        rep.size = image.pointSize
        if let tiff = rep.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    static func write(_ image: RenderedImage, to url: URL, format: ImageFormat) throws {
        guard let data = data(for: image, format: format) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        try data.write(to: url, options: .atomic)
        Settings.saveFormat = format
    }

    /// Lightshot's file name pattern: "Screenshot at Oct 20 14-05-33.png".
    static func defaultFileName(format: ImageFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd HH-mm-ss"
        return "Screenshot at \(formatter.string(from: Date())).\(format.fileExtension)"
    }

    @MainActor
    static func chooseSaveLocation() -> (URL, ImageFormat)? {
        let panel = NSSavePanel()
        panel.title = "Save Screenshot"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        // Always start in Downloads rather than wherever the last screenshot went.
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = defaultFileName(format: Settings.saveFormat)
        let picker = FormatPicker(panel: panel, format: Settings.saveFormat)
        panel.level = .modalPanel
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, picker.format)
    }

    @MainActor
    static func print(_ image: RenderedImage) -> Bool {
        let view = NSImageView(frame: CGRect(origin: .zero, size: image.pointSize))
        view.image = NSImage(cgImage: image.cgImage, size: image.pointSize)
        view.imageScaling = .scaleProportionallyUpOrDown
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.orientation = image.pointSize.width > image.pointSize.height ? .landscape : .portrait
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation.run()
    }
}

/// The PNG/JPEG pop-up under the save panel; switching it changes the file extension.
@MainActor
private final class FormatPicker: NSObject {
    private weak var panel: NSSavePanel?
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private(set) var format: ImageFormat

    init(panel: NSSavePanel, format: ImageFormat) {
        self.panel = panel
        self.format = format
        super.init()
        popup.addItems(withTitles: ["PNG", "JPEG"])
        popup.selectItem(at: format == .png ? 0 : 1)
        popup.target = self
        popup.action = #selector(formatChanged)

        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 44))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        panel.accessoryView = container
        apply()
        // The panel holds the accessory view but not this controller.
        objc_setAssociatedObject(panel, &FormatPicker.associationKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static var associationKey: UInt8 = 0

    @objc private func formatChanged() {
        format = popup.indexOfSelectedItem == 0 ? .png : .jpeg
        apply()
    }

    private func apply() {
        guard let panel else { return }
        panel.allowedContentTypes = [format.contentType]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
    }
}
