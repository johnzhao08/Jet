import Foundation
import Observation
import PencilKit

/// What a finger or the Pencil does on a handwritten page, besides writing with the picked tool.
public enum InkMode: Equatable, Sendable {
    /// Write, erase, etc. with the tool chosen in the tool picker.
    case draw
    /// Lasso-select strokes, then drag, copy or delete them.
    case lasso
    /// Drag down from a point to push everything below it down (or up to close a gap), like OneNote.
    case insertSpace
}

/// An open handwritten note. Saves are debounced; identical content is never rewritten,
/// so git only sees a change when a stroke actually changed.
@MainActor
@Observable
public final class InkNoteModel {
    public let url: URL
    public var paper: PaperStyle = .lined {
        didSet {
            guard paper != oldValue, !isLoading else { return }
            dirty = true
            saveNow()
        }
    }
    /// Bumped when the drawing was replaced from disk (first load, or after a sync).
    public var generation = 0
    public var showsToolPicker = true
    /// The canvas's current tool mode, for showing in the toolbar. The canvas owns it.
    public var mode: InkMode = .draw

    @ObservationIgnored public private(set) var drawing = PKDrawing()
    /// Pictures on the page. Observed, so the Mac's read-only view redraws when they change.
    public private(set) var images: [InkImage] = []
    @ObservationIgnored public var undo: () -> Void = {}
    /// Places a picture (a vault-relative path) in view on the page. Set by the canvas.
    @ObservationIgnored public var insertImage: (_ path: String, _ pixelSize: CGSize) -> Void = { _, _ in }
    @ObservationIgnored public var redo: () -> Void = {}
    /// Turns lasso or insert space on (or back off to the previous tool). Set by the canvas.
    @ObservationIgnored public var toggleTool: (InkMode) -> Void = { _ in }
    @ObservationIgnored public var onWrite: () -> Void = {}

    @ObservationIgnored private var lastSaved: Data?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    public init(url: URL) {
        self.url = url
        load()
    }

    private func load() {
        let data = try? Data(contentsOf: url)
        let document = InkDocument.decode(data ?? Data()) ?? InkDocument()
        isLoading = true
        paper = document.paper
        isLoading = false
        drawing = document.pkDrawing
        images = document.images ?? []
        lastSaved = data
        dirty = false
        generation += 1
    }

    public func drawingChanged(_ newDrawing: PKDrawing) {
        guard newDrawing != drawing else { return }
        drawing = newDrawing
        scheduleSave()
    }

    public func imagesChanged(_ newImages: [InkImage]) {
        guard newImages != images else { return }
        images = newImages
        scheduleSave()
    }

    private func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    public func saveNow() {
        saveTask?.cancel()
        guard dirty else { return }
        dirty = false
        let data = InkDocument(paper: paper, drawing: drawing.dataRepresentation(), images: images).encoded()
        guard data != lastSaved else { return }
        do {
            try data.write(to: url, options: .atomic)
            lastSaved = data
            onWrite()
        } catch {
            dirty = true
        }
    }

    public func reloadIfChangedOnDisk() {
        guard !dirty, let disk = try? Data(contentsOf: url), disk != lastSaved else { return }
        load()
    }
}

/// An open Markdown note.
@MainActor
@Observable
public final class MarkdownNoteModel {
    public let url: URL
    public var text = "" {
        didSet {
            guard text != oldValue, !isLoading else { return }
            dirty = true
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.saveNow()
            }
        }
    }

    @ObservationIgnored public var onWrite: () -> Void = {}
    @ObservationIgnored private var lastSaved = ""
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    public init(url: URL) {
        self.url = url
        load()
    }

    private func load() {
        let disk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        isLoading = true
        text = disk
        isLoading = false
        lastSaved = disk
        dirty = false
    }

    public func saveNow() {
        saveTask?.cancel()
        guard dirty else { return }
        dirty = false
        guard text != lastSaved else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            lastSaved = text
            onWrite()
        } catch {
            dirty = true
        }
    }

    public func reloadIfChangedOnDisk() {
        guard !dirty, let disk = try? String(contentsOf: url, encoding: .utf8), disk != lastSaved else { return }
        load()
    }

    /// Flips the `- [ ]` checkbox on the given source line.
    public func toggleTask(atLine line: Int) {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return }
        if let range = lines[line].range(of: "[ ]") {
            lines[line].replaceSubrange(range, with: "[x]")
        } else if let range = lines[line].range(of: "[x]", options: .caseInsensitive) {
            lines[line].replaceSubrange(range, with: "[ ]")
        }
        text = lines.joined(separator: "\n")
    }
}

/// A tool that can sit in the iPad's tool picker, besides the lasso and Insert Space (always there).
public enum InkPickerTool: String, CaseIterable, Identifiable, Sendable {
    case pen, monoline, fountainPen, marker, pencil, watercolor, crayon, eraser, ruler

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .pen: "Pen"
        case .monoline: "Monoline"
        case .fountainPen: "Fountain pen"
        case .marker: "Highlighter"
        case .pencil: "Pencil"
        case .watercolor: "Watercolor"
        case .crayon: "Crayon"
        case .eraser: "Eraser"
        case .ruler: "Ruler"
        }
    }

    public var detail: String {
        switch self {
        case .pen: "Smooth ink that varies with pressure"
        case .monoline: "Even-width ink, like a ballpoint"
        case .fountainPen: "Ink that varies with the angle of the Pencil"
        case .marker: "See-through marker for highlighting"
        case .pencil: "Textured graphite; tilt to shade"
        case .watercolor: "Soft colour that blends"
        case .crayon: "Waxy, textured colour"
        case .eraser: "Erases whole strokes or pixels"
        case .ruler: "Draw straight lines along it"
        }
    }

    public var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .monoline: "pencil.line"
        case .fountainPen: "pencil.and.scribble"
        case .marker: "highlighter"
        case .pencil: "pencil"
        case .watercolor: "paintbrush"
        case .crayon: "paintbrush.pointed"
        case .eraser: "eraser"
        case .ruler: "ruler"
        }
    }

    /// Whether this tool puts ink on the page (the picker needs at least one).
    public var inks: Bool { self != .eraser && self != .ruler }

    public static let defaults: [InkPickerTool] = [.pen, .monoline, .marker, .pencil, .eraser, .ruler]
    public static let storageKey = "jet.ink.tools"

    /// The tools in the picker, in order, from their stored form ("pen,marker,eraser").
    public static func decode(_ stored: String) -> [InkPickerTool] {
        var seen = Set<InkPickerTool>()
        let tools = stored.split(separator: ",").compactMap { InkPickerTool(rawValue: String($0)) }.filter { seen.insert($0).inserted }
        return tools.contains(where: \.inks) ? tools : defaults
    }

    public static func encode(_ tools: [InkPickerTool]) -> String {
        tools.map(\.rawValue).joined(separator: ",")
    }
}

/// How Jet opens a file, by its extension.
public enum FileKind: Sendable {
    case ink, markdown, text, pdf, image, other

    public nonisolated static let textExtensions: Set<String> = [
        "txt", "text", "csv", "tsv", "json", "yaml", "yml", "toml", "xml", "log", "ini", "cfg", "conf", "env",
        "sh", "zsh", "bash", "fish", "py", "js", "mjs", "ts", "tsx", "jsx", "swift", "c", "h", "cc", "cpp", "hpp",
        "m", "mm", "java", "kt", "kts", "go", "rs", "rb", "php", "css", "scss", "less", "sql", "tex", "bib",
        "org", "rst", "adoc", "lua", "r", "dart", "scala", "gradle", "properties", "srt", "vtt",
    ]

    public init(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "ink": self = .ink
        case "md", "markdown": self = .markdown
        case "pdf": self = .pdf
        case _ where ImageFiles.extensions.contains(ext): self = .image
        case _ where Self.textExtensions.contains(ext): self = .text
        default: self = .other
        }
    }

    public var symbol: String {
        switch self {
        case .ink: "pencil.tip"
        case .markdown: "doc.text"
        case .text: "doc.plaintext"
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .other: "doc"
        }
    }
}
