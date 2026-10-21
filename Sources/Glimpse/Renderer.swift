import AppKit

struct RenderedImage {
    let cgImage: CGImage
    /// Size in points, so Retina images carry 144 dpi like macOS's own screenshots.
    let pointSize: CGSize
}

enum Renderer {
    /// Crops `selection` (view points) out of the frozen screen image and draws the annotations on top.
    static func render(image: CGImage, viewSize: CGSize, selection: CGRect, annotations: [Annotation], downscale: Bool) -> RenderedImage? {
        let scale = CGFloat(image.width) / viewSize.width
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // CGImage cropping counts from the top-left; the view counts from the bottom-left.
        let crop = CGRect(
            x: selection.minX * scale,
            y: (viewSize.height - selection.maxY) * scale,
            width: selection.width * scale,
            height: selection.height * scale
        ).integral.intersection(imageBounds)
        guard crop.width >= 1, crop.height >= 1, let cropped = image.cropping(to: crop) else { return nil }

        // The selection snapped to whole pixels, back in view points.
        let snapped = CGRect(
            x: crop.minX / scale,
            y: viewSize.height - crop.maxY / scale,
            width: crop.width / scale,
            height: crop.height / scale
        )
        if annotations.isEmpty && !downscale {
            return RenderedImage(cgImage: cropped, pointSize: snapped.size)
        }

        let outputScale = downscale ? 1 : scale
        let width = max(1, Int((snapped.width * outputScale).rounded()))
        let height = max(1, Int((snapped.height * outputScale).rounded()))
        let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: bitmapInfo) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))

        ctx.scaleBy(x: CGFloat(width) / snapped.width, y: CGFloat(height) / snapped.height)
        ctx.translateBy(x: -snapped.minX, y: -snapped.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for annotation in annotations {
            annotation.draw(in: ctx)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let output = ctx.makeImage() else { return nil }
        return RenderedImage(cgImage: output, pointSize: snapped.size)
    }
}
