#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Mac's Markdown editor: still plain Markdown underneath, styled as you type the way Bear,
/// iA Writer and Obsidian's live preview do it. A centred column of comfortable width, real headings,
/// bold and italic, links in the accent colour, code on a tinted block, quotes with a bar, lists with
/// hanging indents, and the markup itself (`**`, `[[ ]]`, link addresses) hidden except on the line
/// you're editing. Pictures dropped on it go in where they're dropped.
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    /// Text to put in at the cursor (a picture's embed), on a line of its own.
    @Binding var insertion: String?
    /// The picture file an embed (`![[a.png]]`) shows, to draw it under its line.
    var image: (String) -> URL? = { _ in nil }
    /// Saves dropped picture files in the vault and returns the embeds to insert for them.
    let embedPictures: ([URL]) -> [String]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = MarkdownLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let textView = MarkdownNSTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.typingAttributes = MarkdownTheme.base
        textView.insertionPointColor = .controlAccentColor
        textView.setAccessibilityIdentifier("markdown-editor")

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView

        context.coordinator.textView = textView
        textView.string = text
        context.coordinator.restyle()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.string != text {
            // Changed on disk (a sync, another app): keep the cursor where it was, as far as it goes.
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            coordinator.restyle()
        }
        if let snippet = insertion {
            DispatchQueue.main.async {
                insertion = nil
                coordinator.insertOnOwnLine(snippet)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: MarkdownNSTextView?
        /// The paragraphs the cursor touches, whose hidden markup is shown.
        private var editingRange = NSRange(location: NSNotFound, length: 0)
        /// Pictures shown under their embeds, by file (loaded once; reloaded when the file changes).
        private var images: [URL: (date: Date?, image: NSImage)] = [:]

        func picture(for embed: String) -> NSImage? {
            guard let url = parent.image(embed) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let cached = images[url], cached.date == date { return cached.image }
            guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return nil }
            images[url] = (date, image)
            return image
        }

        init(_ parent: MarkdownTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            restyle()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let paragraphs = (textView.string as NSString).paragraphRange(for: textView.selectedRange())
            if paragraphs != editingRange { restyle() }
        }

        /// Restyles the whole note. Notes are small; past about 300,000 characters it stays plain.
        func restyle() {
            guard let textView, let storage = textView.textStorage else { return }
            let ns = textView.string as NSString
            editingRange = ns.paragraphRange(for: textView.selectedRange())
            guard ns.length < 300_000 else { return }
            let width = min(textView.textContainer?.size.width ?? 600, 640)
            MarkdownTheme.apply(MarkdownStyling.spans(in: textView.string), to: storage, editing: editingRange,
                                imageWidth: width > 0 ? width : 600) { [weak self] in self?.picture(for: $0) }
        }

        /// Puts `snippet` at the cursor on a line of its own, undoably.
        func insertOnOwnLine(_ snippet: String) {
            guard let textView else { return }
            let ns = textView.string as NSString
            let range = textView.selectedRange()
            let before = range.location == 0 || ns.character(at: range.location - 1) == 10 ? "" : "\n"
            let after = NSMaxRange(range) >= ns.length || ns.character(at: NSMaxRange(range)) == 10 ? "" : "\n"
            let piece = before + snippet + after
            guard textView.shouldChangeText(in: range, replacementString: piece) else { return }
            textView.textStorage?.replaceCharacters(in: range, with: piece)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: range.location + (piece as NSString).length, length: 0))
        }

        /// Pictures dropped at `index`: saved in the vault, then embedded there.
        func dropPictures(_ files: [URL], at index: Int) {
            guard let textView else { return }
            textView.setSelectedRange(NSRange(location: min(index, (textView.string as NSString).length), length: 0))
            for embed in parent.embedPictures(files) { insertOnOwnLine(embed) }
            textView.window?.makeFirstResponder(textView)
        }
    }
}

// MARK: - Text view

final class MarkdownNSTextView: NSTextView {
    weak var coordinator: MarkdownTextView.Coordinator?
    /// The widest the text column gets; wider windows centre it, like a page.
    static let columnWidth: CGFloat = 720
    private var pictureDrag = false

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let side = max(28, (newSize.width - Self.columnWidth) / 2)
        if textContainerInset.width != side {
            textContainerInset = NSSize(width: side, height: 28)
        }
    }

    // A plain text view would type a dropped picture's path or web address. Pictures go in as
    // embeds instead, at the spot they're dropped; text and links still drop as text.

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + PictureDrag.extraTypes
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pictureDrag = PictureDrag.carriesPicture(sender.draggingPasteboard)
        return pictureDrag ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard pictureDrag else { return super.draggingUpdated(sender) }
        // Show where it will go.
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: index, length: 0))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if !pictureDrag { super.draggingExited(sender) }
        pictureDrag = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        pictureDrag ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard pictureDrag else { return super.performDragOperation(sender) }
        pictureDrag = false
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        let pasteboard = sender.draggingPasteboard
        Task { @MainActor [weak self] in
            let files = await PictureDrag.files(from: pasteboard)
            self?.coordinator?.dropPictures(files, at: index)
        }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if !pictureDrag { super.concludeDragOperation(sender) }
    }
}

/// Reading pictures off a drag's pasteboard (where an `NSTextView` gets its drops, not item providers).
@MainActor
enum PictureDrag {
    static let extraTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .png, .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier), NSPasteboard.PasteboardType(UTType.webP.identifier),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        NSPasteboard.PasteboardType("Apple files promise pasteboard type"),
    ]

    /// Checked from types alone: no promised file is fetched while dragging.
    static func carriesPicture(_ pasteboard: NSPasteboard) -> Bool {
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return FileDrop.carriesImage(types: pasteboard.types?.map(\.rawValue) ?? [], fileURLs: fileURLs)
    }

    /// The dropped pictures as files: Finder's files where they are, a browser's promised file once
    /// it's written, or raw image data saved to a temporary file.
    static func files(from pasteboard: NSPasteboard) async -> [URL] {
        let isImage = { (url: URL) in UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
        if !fileURLs.isEmpty { return fileURLs.filter(isImage) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("JetDrops").appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            var received: [URL] = []
            for receiver in receivers {
                let urls: [URL] = await withCheckedContinuation { continuation in
                    let state = PromiseState(expected: max(receiver.fileNames.count, 1), continuation: continuation)
                    let queue = OperationQueue()
                    queue.maxConcurrentOperationCount = 1
                    receiver.receivePromisedFiles(atDestination: folder, operationQueue: queue) { url, error in
                        state.received(error == nil ? url : nil)
                    }
                    // A source that never delivers mustn't leave the drop waiting for ever.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 20) { state.finish() }
                }
                received += urls
            }
            let pictures = received.filter(isImage)
            if !pictures.isEmpty { return pictures }
        }

        // Image data on the pasteboard itself.
        for raw in pasteboard.types?.map(\.rawValue) ?? [] {
            guard let type = UTType(raw), !type.isDynamic, type.conforms(to: .image),
                  let data = pasteboard.data(forType: NSPasteboard.PasteboardType(raw)) else { continue }
            let url = folder.appendingPathComponent("Pasted image").appendingPathExtension(type.preferredFilenameExtension ?? "png")
            if (try? data.write(to: url)) != nil { return [url] }
        }
        return []
    }
}

/// Collects a promise's files and resumes once, when all have arrived or on timeout.
private final class PromiseState: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var remaining: Int
    private var continuation: CheckedContinuation<[URL], Never>?

    init(expected: Int, continuation: CheckedContinuation<[URL], Never>) {
        remaining = expected
        self.continuation = continuation
    }

    func received(_ url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        remaining -= 1
        let done = remaining <= 0
        lock.unlock()
        if done { finish() }
    }

    func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let urls = self.urls
        lock.unlock()
        continuation?.resume(returning: urls)
    }
}

// MARK: - Look

/// Fonts, colours and spacing for the editor.
@MainActor
enum MarkdownTheme {
    static let bodySize: CGFloat = 15
    static var bodyFont: NSFont { .systemFont(ofSize: bodySize) }
    static var monoFont: NSFont { .monospacedSystemFont(ofSize: bodySize - 1.5, weight: .regular) }

    static func paragraph(lineHeight: CGFloat = 1.32, spacingBefore: CGFloat = 0, spacing: CGFloat = 5,
                          indent: CGFloat = 0, firstLine: CGFloat? = nil) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeight
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacing
        style.headIndent = indent
        style.firstLineHeadIndent = firstLine ?? 0
        return style
    }

    /// A colour that follows light and dark mode when drawn (a tinted system colour made once wouldn't).
    static func adaptive(_ make: @escaping @Sendable () -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var color = NSColor.labelColor
            appearance.performAsCurrentDrawingAppearance { color = make().usingColorSpace(.deviceRGB) ?? make() }
            return color
        }
    }
    static let codeBackground = adaptive { NSColor.labelColor.withAlphaComponent(0.07) }
    static let tagBackground = adaptive { NSColor.controlAccentColor.withAlphaComponent(0.13) }

    static var base: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph()]
    }

    static func headingFont(_ level: Int) -> NSFont {
        let sizes: [CGFloat] = [28, 23, 19, 17, 15.5, 15]
        let weights: [NSFont.Weight] = [.bold, .bold, .semibold, .semibold, .semibold, .semibold]
        let index = min(max(level, 1), 6) - 1
        return .systemFont(ofSize: sizes[index], weight: weights[index])
    }

    /// Markup that's out of the way: as good as gone, though still there to move the cursor through.
    static let hidden: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear, .kern: -0.01,
    ]

    static func apply(_ spans: [MarkdownStyling.Span], to storage: NSTextStorage, editing: NSRange,
                      imageWidth: CGFloat = 600, picture: (String) -> NSImage? = { _ in nil }) {
        func isEditing(_ range: NSRange) -> Bool {
            NSIntersectionRange(range, editing).length > 0 || NSLocationInRange(range.location, editing)
                || (range.length == 0 && NSMaxRange(editing) == range.location)
        }
        let all = NSRange(location: 0, length: storage.length)
        let text = storage.string as NSString
        storage.beginEditing()
        storage.setAttributes(base, range: all)

        // Blocks first, then inline styles on top, then markup last so it wins.
        let order: (MarkdownStyling.Role) -> Int = { role in
            switch role {
            case .frontmatter, .codeBlock, .quote, .heading, .rule, .listMarker, .taskDone: return 0
            case .markup: return 2
            default: return 1
            }
        }
        for span in spans.sorted(by: { order($0.role) < order($1.role) }) {
            let range = span.range
            switch span.role {
            case .heading(let level):
                storage.addAttribute(.font, value: headingFont(level), range: range)
                storage.addAttribute(.paragraphStyle,
                                     value: paragraph(lineHeight: 1.15, spacingBefore: level == 1 ? 10 : 6, spacing: 6),
                                     range: text.paragraphRange(for: range))
            case .bold:
                storage.applyFontTraits(.boldFontMask, range: range)
            case .italic:
                storage.applyFontTraits(.italicFontMask, range: range)
            case .strike:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .foregroundColor: NSColor.secondaryLabelColor], range: range)
            case .code:
                storage.addAttributes([.font: monoFont, .backgroundColor: codeBackground,
                                       .foregroundColor: NSColor.systemPink], range: range)
            case .codeBlock:
                storage.addAttributes([.font: monoFont, .foregroundColor: NSColor.labelColor,
                                       MarkdownLayoutManager.block: MarkdownLayoutManager.Block.code,
                                       .paragraphStyle: paragraph(lineHeight: 1.2, spacing: 0, indent: 14, firstLine: 14)],
                                      range: text.paragraphRange(for: range))
            case .quote:
                storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor,
                                       MarkdownLayoutManager.block: MarkdownLayoutManager.Block.quote,
                                       .paragraphStyle: paragraph(indent: 16, firstLine: 16)], range: text.paragraphRange(for: range))
            case .link, .wikilink:
                storage.addAttributes([.foregroundColor: NSColor.controlAccentColor], range: range)
            case .url:
                storage.addAttributes([.foregroundColor: NSColor.controlAccentColor,
                                       .underlineStyle: NSUnderlineStyle.single.rawValue,
                                       .underlineColor: adaptive { NSColor.controlAccentColor.withAlphaComponent(0.4) }], range: range)
            case .embed:
                storage.addAttributes([.foregroundColor: NSColor.systemTeal,
                                       .font: NSFont.systemFont(ofSize: bodySize - 1, weight: .medium)], range: range)
                // The picture is drawn in room made above its line (room below the last line of a note
                // wouldn't count); the embed itself only shows while you're on that line.
                if let image = picture(text.substring(with: range)) {
                    let scale = min(1, imageWidth / max(image.size.width, 1), 420 / max(image.size.height, 1))
                    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                    let line = text.paragraphRange(for: range)
                    storage.addAttribute(MarkdownLayoutManager.image, value: MarkdownLayoutManager.Picture(image: image, size: size),
                                         range: NSRange(location: NSMaxRange(range) - 1, length: 1))
                    storage.addAttribute(.paragraphStyle, value: paragraph(spacingBefore: size.height + 16, spacing: 8), range: line)
                    if !isEditing(range) { storage.addAttributes(hidden, range: range) }
                }
            case .tag:
                storage.addAttributes([.foregroundColor: NSColor.controlAccentColor,
                                       .backgroundColor: tagBackground], range: range)
            case .listMarker:
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
                // Hanging indent: wrapped lines line up with the item's text, not its bullet.
                let line = text.paragraphRange(for: range)
                let prefix = text.substring(with: NSRange(location: line.location, length: NSMaxRange(range) - line.location)) + " "
                let width = (prefix as NSString).size(withAttributes: [.font: bodyFont]).width
                storage.addAttribute(.paragraphStyle, value: paragraph(spacing: 2, indent: width), range: line)
            case .taskDone:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .foregroundColor: NSColor.secondaryLabelColor], range: range)
            case .rule:
                // A drawn line; the dashes only show while you're on it.
                storage.addAttribute(MarkdownLayoutManager.block, value: MarkdownLayoutManager.Block.rule, range: range)
                let ruleStyle = NSMutableParagraphStyle()
                ruleStyle.minimumLineHeight = 26
                ruleStyle.maximumLineHeight = 26
                ruleStyle.paragraphSpacing = 4
                storage.addAttribute(.paragraphStyle, value: ruleStyle, range: text.paragraphRange(for: range))
                storage.addAttributes(isEditing(range) ? [.foregroundColor: NSColor.tertiaryLabelColor] : hidden, range: range)
            case .frontmatter:
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: bodySize - 3, weight: .regular),
                                       .foregroundColor: NSColor.secondaryLabelColor,
                                       .paragraphStyle: paragraph(lineHeight: 1.15, spacing: 0)], range: range)
            case .markup(let hideable):
                if hideable && !isEditing(range) {
                    storage.addAttributes(hidden, range: range)
                } else {
                    storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
                }
            }
        }
        storage.endEditing()
    }
}

/// Draws what text attributes can't: a rounded panel behind code blocks, the full width of the
/// column, and a bar beside quotes.
final class MarkdownLayoutManager: NSLayoutManager {
    static let block = NSAttributedString.Key("JetMarkdownBlock")
    enum Block: Int { case code, quote, rule }
    /// A picture to draw under the line holding this attribute.
    static let image = NSAttributedString.Key("JetMarkdownImage")
    final class Picture: NSObject {
        let image: NSImage
        let size: NSSize
        init(image: NSImage, size: NSSize) {
            self.image = image
            self.size = size
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(Self.block, in: characters) { value, range, _ in
            guard let block = value as? Block else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = NSRect.null
            enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in rect = rect.union(fragment) }
            guard !rect.isNull else { return }
            rect = rect.offsetBy(dx: origin.x, dy: origin.y)
            switch block {
            case .code:
                let panel = NSRect(x: origin.x, y: rect.minY - 4, width: container.size.width, height: rect.height + 8)
                NSColor.quaternaryLabelColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: panel, xRadius: 7, yRadius: 7).fill()
            case .quote:
                let bar = NSRect(x: origin.x, y: rect.minY + 2, width: 3, height: rect.height - 4)
                NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            case .rule:
                let line = NSRect(x: origin.x, y: rect.midY.rounded() - 0.5, width: container.size.width, height: 1)
                NSColor.separatorColor.setFill()
                line.fill()
            }
        }
        storage.enumerateAttribute(Self.image, in: characters) { value, range, _ in
            guard let picture = value as? Picture else { return }
            // The line's fragment starts with the room made above it (its paragraph's spacing before).
            let glyph = glyphIndexForCharacter(at: range.location)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            let frame = NSRect(x: origin.x, y: line.minY + 8, width: picture.size.width, height: picture.size.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).addClip()
            picture.image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
#endif
