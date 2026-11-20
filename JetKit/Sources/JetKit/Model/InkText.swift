import Foundation
import CoreGraphics
import CoreText

/// Typed text on a handwritten page: plain, multiline text in the system font, laid out in lines
/// `lineHeight` apart so it sits on the paper's ruled lines. It wraps at `width` and is as tall as
/// its lines. Kept in page points like strokes and pictures, so it lines up on every device.
public struct InkText: Codable, Equatable, Identifiable, Sendable {
    public static let fontSize: CGFloat = 22
    public static let lineHeight: CGFloat = InkDocument.lineSpacing
    public static let minimumWidth: CGFloat = 120
    /// Space kept between text and the page's left and right edges.
    public static let margin: CGFloat = 16

    public var id: String
    public var text: String
    /// Top-left corner, in page points.
    public var x: Double
    public var y: Double
    /// The width the text wraps at, in page points.
    public var width: Double

    public init(id: String = UUID().uuidString, text: String, origin: CGPoint, width: CGFloat) {
        self.id = id
        self.text = text
        x = Double(origin.x)
        y = Double(origin.y)
        self.width = Double(max(width, Self.minimumWidth))
    }

    public var origin: CGPoint {
        get { CGPoint(x: x, y: y) }
        set {
            x = Double(newValue.x)
            y = Double(newValue.y)
        }
    }

    /// Where the text is on the page: its wrap width, and as many whole lines as it takes (at least one).
    public var frame: CGRect {
        CGRect(origin: origin, size: InkTextLayout.size(text, width: CGFloat(width)))
    }

    /// Whether `point` (page points) is on the text: on one of its written lines, give or take a few
    /// points, rather than anywhere in its wrap width. Empty text counts its first line.
    public func contains(_ point: CGPoint) -> Bool {
        let slack = InkText.hitSlack
        let lines = InkTextLayout.lineFrames(self)
        guard !lines.isEmpty else {
            return CGRect(x: x, y: y, width: Self.minimumWidth / 2, height: Self.lineHeight)
                .insetBy(dx: -slack, dy: 0).contains(point)
        }
        return lines.contains { $0.insetBy(dx: -slack, dy: -slack / 2).contains(point) }
    }

    /// How far beside its letters a press still picks up typed text.
    public static let hitSlack: CGFloat = 8

    /// `text` with its top-left corner at `origin`, kept on the page. Its wrap width shrinks (it
    /// rewraps) when it would otherwise run past the right margin, and never grows.
    public static func moved(_ text: InkText, to origin: CGPoint) -> InkText {
        let pageWidth = InkDocument.pageWidth
        var moved = text
        let x = min(max(origin.x, 0), pageWidth - margin - minimumWidth)
        moved.x = Double(x)
        moved.y = Double(max(origin.y, 0))
        moved.width = Double(max(minimumWidth, min(CGFloat(text.width), pageWidth - margin - x)))
        return moved
    }

    /// Whether there is nothing but white space (such text is removed rather than kept).
    public var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// `y` moved up onto the top of the ruled line it is in, so text sits on the paper's lines.
    public static func lineAligned(_ y: CGFloat) -> CGFloat {
        max(0, (y / lineHeight).rounded(.down) * lineHeight)
    }

    /// Where new text goes when the page is clicked or tapped at `point`: starting at the point, on
    /// the line it is in, wrapping at the page's right margin.
    public static func placement(at point: CGPoint) -> (origin: CGPoint, width: CGFloat) {
        let pageWidth = InkDocument.pageWidth
        let x = min(max(point.x, margin), pageWidth - margin - minimumWidth)
        return (CGPoint(x: x, y: lineAligned(point.y)), pageWidth - margin - x)
    }
}

/// Lays out and draws typed text with Core Text, the same way on iPad, Mac and in previews, so what
/// is typed in an editor looks the same on the page, in embeds and in what the AI is shown.
public enum InkTextLayout {
    private static let font: CTFont = CTFontCreateUIFontForLanguage(.system, InkText.fontSize, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, InkText.fontSize, nil)

    private static let paragraph = paragraphStyle(lineHeight: InkText.lineHeight)

    private static func paragraphStyle(lineHeight: CGFloat) -> CTParagraphStyle {
        var minimum = lineHeight
        var maximum = lineHeight
        return withUnsafePointer(to: &minimum) { minimumPointer in
            withUnsafePointer(to: &maximum) { maximumPointer in
                let settings = [
                    CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: minimumPointer),
                    CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: maximumPointer),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }

    private static func attributed(_ text: String, color: CGColor, font: CTFont = InkTextLayout.font,
                                   paragraph: CTParagraphStyle = InkTextLayout.paragraph) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
    }

    /// The number of lines `string` takes wrapped at `width`, at least one.
    private static func lineCount(_ string: NSAttributedString, text: String, width: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let setter = CTFramesetterCreateWithAttributedString(string)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        var lines = max(1, (fitted.height / lineHeight - 0.01).rounded(.up))
        // A trailing newline starts a line Core Text does not count.
        if text.hasSuffix("\n") { lines += 1 }
        return lines
    }

    /// The size `text` takes wrapped at `width`: that width, and whole lines (at least one).
    public static func size(_ text: String, width: CGFloat) -> CGSize {
        let width = max(width, 1)
        guard !text.isEmpty else { return CGSize(width: width, height: InkText.lineHeight) }
        let lines = lineCount(attributed(text, color: CGColor(gray: 0, alpha: 1)), text: text, width: width,
                              lineHeight: InkText.lineHeight)
        return CGSize(width: width, height: lines * InkText.lineHeight)
    }

    /// The size, in page points, an editor showing `text` at `zoom` view points per page point needs.
    /// Type doesn't scale exactly with zoom, so at some zooms the editor's font wraps a line sooner
    /// than the page's does; this is never smaller than either, so the editor never cuts off a line.
    public static func editorSize(_ text: String, width: CGFloat, zoom: CGFloat) -> CGSize {
        let pageSize = size(text, width: width)
        let zoom = max(zoom, 0.01)
        guard !text.isEmpty, abs(zoom - 1) > 0.001 else { return pageSize }
        let lineHeight = InkText.lineHeight * zoom
        let zoomedFont = CTFontCreateCopyWithAttributes(font, InkText.fontSize * zoom, nil, nil)
        let zoomed = attributed(text, color: CGColor(gray: 0, alpha: 1), font: zoomedFont,
                                paragraph: paragraphStyle(lineHeight: lineHeight))
        let lines = lineCount(zoomed, text: text, width: max(width, 1) * zoom, lineHeight: lineHeight)
        return CGSize(width: pageSize.width, height: max(pageSize.height, lines * InkText.lineHeight))
    }

    /// Where each written line of `text` is, in page points: as wide as its letters (trailing spaces
    /// left out), one ruled line tall. Empty lines are left out.
    public static func lineFrames(_ text: InkText) -> [CGRect] {
        guard !text.text.isEmpty else { return [] }
        let width = CGFloat(text.width)
        let height = size(text.text, width: width).height + InkText.lineHeight
        let setter = CTFramesetterCreateWithAttributedString(attributed(text.text, color: CGColor(gray: 0, alpha: 1)))
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var result: [CGRect] = []
        for (index, line) in lines.enumerated() {
            let used = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            guard used > 0.5 else { continue }
            result.append(CGRect(x: CGFloat(text.x), y: CGFloat(text.y) + CGFloat(index) * InkText.lineHeight,
                                 width: min(used, width), height: InkText.lineHeight))
        }
        return result
    }

    /// Draws `text` into `context`, whose coordinates are page points with y pointing down.
    public static func draw(_ text: InkText, in context: CGContext, color: CGColor) {
        guard !text.text.isEmpty else { return }
        let width = CGFloat(text.width)
        // Room for every line and one spare, so Core Text never drops the last one.
        let height = size(text.text, width: width).height + InkText.lineHeight
        let setter = CTFramesetterCreateWithAttributedString(attributed(text.text, color: color))
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        context.saveGState()
        context.translateBy(x: CGFloat(text.x), y: CGFloat(text.y) + height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    /// Ink-like text colour: black on paper, white on a dark page (as PencilKit shows black ink).
    public static func color(dark: Bool) -> CGColor {
        CGColor(gray: dark ? 1 : 0, alpha: 1)
    }
}
