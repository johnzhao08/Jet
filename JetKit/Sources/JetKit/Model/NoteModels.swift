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

    // The Mac's writing surface (mouse, trackpad or tablet). The toolbar sets these, the surface reads them.
    public var surfaceTool: InkSurfaceTool = .pen
    public var penSwatch: InkSwatch = .black
    public var highlighterSwatch: InkSwatch = .yellow
    public var thickness: InkThickness = .medium
    /// Page zoom, in view points per page point (0 until the page first lays out). Not saved: it is how
    /// this window shows the page. Change it with `setZoom(_:)`, `zoomIn()`, `zoomOut()` or `zoomToFit()`.
    public internal(set) var zoom: CGFloat = 0
    /// The zoom at which the page's width just fills the view, as the view last laid it out.
    public internal(set) var fitZoom: CGFloat = 0
    /// Whether `zoom` was chosen with the whole page width in view. Then a narrower view zooms out to keep
    /// it in view, and a wider one goes back to `zoom`; otherwise the zoom stays and the page scrolls sideways.
    var zoomFitsWidth = true
    /// Whether there is something to undo or redo, for the toolbar. The canvas owns them.
    public var canUndo = false
    public var canRedo = false
    /// Bumped on every change to the strokes, so views that draw them know to redraw.
    public private(set) var revision = 0
    /// Changes whenever the page needs redrawing: its strokes changed, or it was reloaded from disk.
    public var renderVersion: Int { generation + revision }

    @ObservationIgnored public private(set) var drawing = PKDrawing()
    /// Pictures on the page. Observed, so the Mac's read-only view redraws when they change.
    public private(set) var images: [InkImage] = []
    /// Typed text on the page (Add Text). Observed, so the page redraws when it changes.
    public private(set) var texts: [InkText] = []
    /// The text being typed in an editor right now, which the page leaves out so it isn't shown twice.
    public var editingTextID: String?
    /// True while Add Text is waiting for a place on the page or text is being typed, for the toolbar.
    public var isAddingText = false
    /// The text in an open editor as typed so far. It is saved with the note (a save or a sync while
    /// typing keeps it) but only becomes an undoable change when the editor closes. Set it through
    /// `updateTextDraft(_:)`, so each change also schedules a save.
    @ObservationIgnored public var textDraft: InkText?
    /// The bottom of the open text editor, in page points (nil when none is open). Observed, so the
    /// page grows to fit text typed near its end. Set by the canvas.
    public var textEditorBottom: CGFloat?
    @ObservationIgnored public var undo: () -> Void = {}
    /// Places a picture (a vault-relative path) in view on the page. Set by the canvas.
    @ObservationIgnored public var insertImage: (_ path: String, _ pixelSize: CGSize) -> Void = { _, _ in }
    @ObservationIgnored public var redo: () -> Void = {}
    /// Turns lasso or insert space on (or back off to the previous tool). Set by the canvas.
    @ObservationIgnored public var toggleTool: (InkMode) -> Void = { _ in }
    /// The Add Text command: lets the writer place a text box on the page and type in it. Set by the canvas.
    @ObservationIgnored public var beginAddingText: () -> Void = {}
    /// Told after each text change made through `addText`, `updateText`, `moveText` or `removeText`,
    /// with the texts as they were before, so the canvas can make it undoable and redraw.
    @ObservationIgnored public var textsEdited: (_ before: [InkText], _ actionName: String) -> Void = { _, _ in }
    /// Told, synchronously, when a reload from disk replaced the open editor's draft (see
    /// `reconcileTextDraft()`): with the new draft, or nil when the text was deleted on another device,
    /// so the editor shows it (or closes without putting it back) before anything else can save or close it.
    @ObservationIgnored public var textDraftReloaded: (_ draft: InkText?) -> Void = { _ in }
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
        texts = document.texts ?? []
        lastSaved = data
        dirty = false
        generation += 1
        reconcileTextDraft()
    }

    /// After a reload, the file is the truth for the open editor's text too: a reload only happens
    /// when nothing is waiting to save, so the draft was written before the sync and the file holds it
    /// merged with the other device's changes (its rewording, moving or deleting of the same text).
    /// - on the page: the draft becomes that text, so closing the editor untouched changes nothing;
    /// - not on the page but blank (new text not typed in yet, never saved): it stays as it is;
    /// - not on the page otherwise: it was deleted on another device, so the draft is dropped.
    private func reconcileTextDraft() {
        guard let draft = textDraft else { return }
        let reloaded: InkText?
        if let onPage = texts.first(where: { $0.id == draft.id }) {
            reloaded = onPage
        } else {
            reloaded = draft.isBlank ? draft : nil
        }
        // Set directly, not through `updateTextDraft`: the file already holds this, so nothing needs saving.
        textDraft = reloaded
        if reloaded == nil { editingTextID = nil }
        textDraftReloaded(reloaded)
    }

    public func drawingChanged(_ newDrawing: PKDrawing) {
        guard newDrawing != drawing else { return }
        drawing = newDrawing
        revision += 1
        scheduleSave()
    }

    public func imagesChanged(_ newImages: [InkImage]) {
        guard newImages != images else { return }
        images = newImages
        scheduleSave()
    }

    /// Replaces the page's typed text as is (undo and redo, live dragging). Blank entries are dropped.
    public func textsChanged(_ newTexts: [InkText]) {
        let kept = newTexts.filter { !$0.isBlank }
        guard kept != texts else { return }
        texts = kept
        scheduleSave()
    }

    /// Adds typed text starting where the page was clicked or tapped (see `InkText.placement`).
    /// Returns nil, adding nothing, when the text is blank.
    @discardableResult
    public func addText(_ string: String, at point: CGPoint, id: String = UUID().uuidString) -> InkText? {
        let placement = InkText.placement(at: point)
        let text = InkText(id: id, text: string, origin: placement.origin, width: placement.width)
        guard !text.isBlank else { return nil }
        commitTexts(texts + [text], name: "Add Text")
        return text
    }

    /// Changes the wording of a text; blank wording removes it.
    public func updateText(_ id: String, to string: String) {
        guard let index = texts.firstIndex(where: { $0.id == id }), texts[index].text != string else { return }
        var updated = texts
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.remove(at: index)
            commitTexts(updated, name: "Delete Text")
        } else {
            updated[index].text = string
            commitTexts(updated, name: "Edit Text")
        }
    }

    /// Moves a text so its top-left corner is at `origin` (kept on the page). Moving it right narrows
    /// its wrap width to fit inside the right margin, so it rewraps; moving it left keeps its width.
    public func moveText(_ id: String, to origin: CGPoint) {
        guard let index = texts.firstIndex(where: { $0.id == id }) else { return }
        var updated = texts
        updated[index] = InkText.moved(updated[index], to: origin)
        guard updated != texts else { return }
        commitTexts(updated, name: "Move Text")
    }

    public func removeText(_ id: String) {
        guard texts.contains(where: { $0.id == id }) else { return }
        commitTexts(texts.filter { $0.id != id }, name: "Delete Text")
    }

    /// The typed text at a page point, the topmost when they overlap. Only its written lines count,
    /// not the empty rest of its wrap width, so writing beside short text still makes ink.
    public func text(at point: CGPoint) -> InkText? {
        texts.last { $0.contains(point) }
    }

    /// Sets the open editor's text as typed so far (nil when the editor closes). The draft is saved
    /// with the note after the usual pause, so what is being typed survives a crash or a sync.
    public func updateTextDraft(_ draft: InkText?) {
        guard draft != textDraft else { return }
        textDraft = draft
        // Also when it closes, so a draft saved earlier never outlives an editor that was emptied.
        scheduleSave()
    }

    private func commitTexts(_ newTexts: [InkText], name: String) {
        let before = texts
        textsChanged(newTexts)
        if texts != before { textsEdited(before, name) }
    }

    /// Adds a picture (a vault-relative path) centred on `point`, kept inside `bounds` (the page, or
    /// one PDF page), at about half its pixel size and never wider than most of the page.
    public func addPicture(_ path: String, pixelSize: CGSize, at point: CGPoint, within bounds: CGRect) {
        let frame = Self.pictureFrame(pixelSize: pixelSize, at: point, within: bounds)
        imagesChanged(images + [InkImage(path: path, frame: frame)])
    }

    public nonisolated static func pictureFrame(pixelSize: CGSize, at point: CGPoint, within bounds: CGRect) -> CGRect {
        let natural = CGSize(width: max(pixelSize.width, 1) / 2, height: max(pixelSize.height, 1) / 2)
        let fit = min(1, 560 / natural.width, 600 / natural.height, (bounds.width - 80) / natural.width)
        let size = CGSize(width: max(natural.width * fit, 40), height: max(natural.height * fit, 40 * natural.height / natural.width))
        var origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        origin.x = min(max(origin.x, bounds.minX + 16), max(bounds.minX + 16, bounds.maxX - 16 - size.width))
        origin.y = max(origin.y, bounds.minY + 16)
        if bounds.height.isFinite {
            origin.y = min(origin.y, max(bounds.minY + 16, bounds.maxY - 16 - size.height))
        }
        return CGRect(origin: origin, size: size)
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

    /// The page's typed text with the editor's draft in it.
    private var textsForSaving: [InkText] {
        guard let draft = textDraft else { return texts }
        var result = texts
        if let index = result.firstIndex(where: { $0.id == draft.id }) { result[index] = draft } else { result.append(draft) }
        return result.filter { !$0.isBlank }
    }

    public func saveNow() {
        saveTask?.cancel()
        guard dirty || textDraft != nil else { return }
        dirty = false
        let data = InkDocument(paper: paper, drawing: drawing.dataRepresentation(), images: images,
                               texts: textsForSaving).encoded()
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
