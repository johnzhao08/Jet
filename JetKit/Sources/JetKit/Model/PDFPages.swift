import Foundation
import CoreGraphics
import ImageIO
import PencilKit

/// A PDF laid out for annotating: its pages stacked top to bottom, each scaled to the handwriting
/// page width (`InkDocument.pageWidth`), so ink drawn over it is stored in the same page points as
/// a handwritten note. The ink lives next to the PDF in a hidden `.Name.pdf.ink`; the PDF itself is
/// never changed.
public final class PDFPages: @unchecked Sendable {
    public static let gap: CGFloat = 24

    public let document: CGPDFDocument
    /// Each page's place, in page points.
    public let frames: [CGRect]
    public let height: CGFloat

    public convenience init?(url: URL) {
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        self.init(document: document)
    }

    /// An image file as a single page, so pictures and ink can go on top of it the way they do on a PDF,
    /// kept in the same hidden `.Name.png.ink`. The image is wrapped in a PDF in memory; the file is
    /// never changed.
    public convenience init?(imageAt url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,   // upright, as photos are shown
                  kCGImageSourceThumbnailMaxPixelSize: 8192,
              ] as CFDictionary)
        else { return nil }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        context.interpolationQuality = .high
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        guard let provider = CGDataProvider(data: data), let document = CGPDFDocument(provider) else { return nil }
        self.init(document: document)
    }

    init?(document: CGPDFDocument) {
        guard document.numberOfPages > 0, !document.isEncrypted || document.isUnlocked else { return nil }
        self.document = document
        var frames: [CGRect] = []
        var y = Self.gap
        for number in 1...document.numberOfPages {
            let size = document.page(at: number).map(Self.displaySize) ?? CGSize(width: 612, height: 792)
            let height = InkDocument.pageWidth * size.height / max(size.width, 1)
            frames.append(CGRect(x: 0, y: y, width: InkDocument.pageWidth, height: height))
            y += height + Self.gap
        }
        self.frames = frames
        height = y
    }

    public var count: Int { frames.count }

    /// Page `index` (0-based).
    public func page(_ index: Int) -> CGPDFPage? { document.page(at: index + 1) }

    /// The page's size as displayed (its crop box, turned by its rotation), in PDF points.
    public static func displaySize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        return rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Draws `page` to fill `rect` in a context with y pointing up (Core Graphics' own orientation).
    public static func draw(_ page: CGPDFPage, in context: CGContext, rect: CGRect) {
        let box = page.getBoxRect(.cropBox)
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        let size = displaySize(of: page)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / max(size.width, 1), y: rect.height / max(size.height, 1))
        switch rotation {
        case 90:
            context.translateBy(x: 0, y: box.width)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: box.width, y: box.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: box.height, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)
        context.clip(to: box)
        context.interpolationQuality = .high
        context.drawPDFPage(page)
        context.restoreGState()
    }

    /// Page `index` with its annotations (pictures, then ink in light-mode colours), as a bitmap
    /// `scale` pixels per page point, on white.
    public func render(_ index: Int, drawing: PKDrawing, images: [InkImage], root: URL, scale: CGFloat) -> CGImage? {
        guard frames.indices.contains(index), let page = page(index) else { return nil }
        let frame = frames[index]
        let width = max(1, Int((frame.width * scale).rounded())), height = max(1, Int((frame.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(full)
        Self.draw(page, in: context, rect: full)
        if hasAnnotations(on: index, drawing: drawing, images: images),
           let overlay = InkRenderer.compose(drawing, images: images, root: root, rect: frame, scale: scale, dark: false) {
            context.draw(overlay, in: full)
        }
        return context.makeImage()
    }

    func hasAnnotations(on index: Int, drawing: PKDrawing, images: [InkImage]) -> Bool {
        let frame = frames[index]
        return drawing.strokes.contains { $0.renderBounds.intersects(frame) } || images.contains { $0.frame.intersects(frame) }
    }

    /// The PDF with its annotations drawn on: pages stay vector, the ink goes on top as an image.
    public func annotatedPDF(drawing: PKDrawing, images: [InkImage], root: URL) -> Data? {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { return nil }
        for index in frames.indices {
            guard let page = page(index) else { continue }
            var box = CGRect(origin: .zero, size: Self.displaySize(of: page))
            context.beginPage(mediaBox: &box)
            Self.draw(page, in: context, rect: box)
            if hasAnnotations(on: index, drawing: drawing, images: images) {
                // About 300 dpi on a letter-sized page.
                let scale = 2560 / InkDocument.pageWidth
                if let overlay = InkRenderer.compose(drawing, images: images, root: root, rect: frames[index], scale: scale, dark: false) {
                    context.draw(overlay, in: box)
                }
            }
            context.endPage()
        }
        context.closePDF()
        return output as Data
    }
}

extension VaultSession {
    /// Where a PDF's (or an image file's) annotations are kept: a hidden `.Name.pdf.ink` beside it.
    public nonisolated static func annotationsPath(for path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let name = "." + (path as NSString).lastPathComponent + ".ink"
        return folder.isEmpty ? name : folder + "/" + name
    }
}
