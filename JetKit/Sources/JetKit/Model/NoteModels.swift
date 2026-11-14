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
    @ObservationIgnored public var undo: () -> Void = {}
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
        lastSaved = data
        dirty = false
        generation += 1
    }

    public func drawingChanged(_ newDrawing: PKDrawing) {
        guard newDrawing != drawing else { return }
        drawing = newDrawing
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
        let data = InkDocument(paper: paper, drawing: drawing.dataRepresentation()).encoded()
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
