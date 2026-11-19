#if os(macOS)
import AppKit
import Foundation
import PDFKit
import PencilKit

/// What AI assistants can do with a vault through Jet's MCP helper (`jet-mcp`).
///
/// Everything works on the files directly, so it also works while Jet is closed; the Mac app watches
/// the vault folder and shows changes live. Note moves use the same link updater as the app.
public struct VaultTools {
    private let indexedFiles: VaultIndexFiles
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.indexedFiles = VaultIndexFiles(root: self.root)
    }

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    /// A tool result in MCP's shape: text and image content blocks.
    public struct Result {
        public var content: [[String: Any]] = []
        public var isError = false

        static func text(_ text: String) -> Result {
            Result(content: [["type": "text", "text": text]])
        }

        mutating func addText(_ text: String) { content.append(["type": "text", "text": text]) }

        mutating func addPNG(_ data: Data) {
            content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"])
        }
    }

    // MARK: Tool catalogue

    public static let definitions: [[String: Any]] = [
        tool("list_notes",
             "List the notes and folders in the Jet vault (or in one folder of it). Markdown notes end in .md; handwritten notes end in .ink and are drawn with Apple Pencil on iPad. PDFs (which may have handwritten annotations) and other files are listed too.",
             ["folder": ["type": "string", "description": "Folder path relative to the vault root. Omit for the whole vault."]]),
        tool("read_note",
             "Read a note. Markdown and other text files come back as text. Handwritten (.ink) notes come back as images of their pages: read the handwriting and drawings from the images. PDFs come back as their text plus images of their pages, including any handwriting on them. Long handwritten notes and PDFs are split into pages; ask for later pages with `page`. A note can be given by path (\"Projects/Jet.md\") or just its title (\"Jet\").",
             ["path": ["type": "string", "description": "Note path relative to the vault root, or the note's title."],
              "page": ["type": "integer", "description": "Handwritten notes and PDFs only: the first page to return (1-based). Default 1."]],
             required: ["path"]),
        tool("search_notes",
             "Search note titles, Markdown and recognized handwriting. Combine text, quoted phrases, /regex/, path:, tag:, [property:value] and task-todo: filters. #project also includes nested tags.",
             ["query": ["type": "string"]], required: ["query"]),
        tool("note_links",
             "Show how a note connects to the rest of the vault: the notes it links to with [[wikilinks]], the notes that link to it (backlinks), its #tags and its aliases.",
             ["path": ["type": "string", "description": "Note path or title."]], required: ["path"]),
        tool("list_tags",
             "List every #tag in the vault with how many notes use it.", [:]),
        tool("create_note",
             "Create a new Markdown note. Refused if a note already exists at that path. Missing folders are created. Use [[Note title]] to link notes and #tags to tag them, as in Obsidian.",
             ["path": ["type": "string", "description": "Path for the new note, e.g. \"Ideas/Reading list.md\". .md is added if missing."],
              "content": ["type": "string", "description": "The note's Markdown text."]],
             required: ["path", "content"], mutates: true),
        tool("edit_note",
             "Edit a Markdown note by replacing one exact piece of its text. `old_text` must appear exactly once in the note (copy it from read_note, whitespace included); include more surrounding text if it appears more than once. Handwritten notes cannot be edited.",
             ["path": ["type": "string", "description": "Note path or title."],
              "old_text": ["type": "string"],
              "new_text": ["type": "string"]],
             required: ["path", "old_text", "new_text"], mutates: true),
        tool("append_to_note",
             "Add text to the end of a Markdown note, creating the note if it doesn't exist. Good for logs, inboxes and daily notes (Daily/YYYY-MM-DD.md).",
             ["path": ["type": "string", "description": "Note path or title."],
              "text": ["type": "string"]],
             required: ["path", "text"], mutates: true),
        tool("move_note", "Move or rename a note and update its incoming links. Use an unused destination path including its extension.",
             ["path": ["type": "string"], "destination": ["type": "string"]], required: ["path", "destination"], mutates: true),
        tool("check_links", "List unresolved wikilinks by source note, optionally restricted to one note.",
             ["path": ["type": "string"]]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any],
                             required: [String] = [], mutates: Bool = false) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return [
            "name": name,
            "description": description,
            "inputSchema": schema,
            "annotations": ["readOnlyHint": !mutates, "destructiveHint": false],
        ]
    }

    // MARK: Dispatch

    public func call(_ name: String, _ arguments: [String: Any]) -> Result {
        do {
            switch name {
            case "list_notes": return try listNotes(folder: arguments["folder"] as? String)
            case "read_note": return try readNote(string(arguments, "path"), page: arguments["page"] as? Int ?? 1)
            case "search_notes": return try search(string(arguments, "query"))
            case "note_links": return try noteLinks(string(arguments, "path"))
            case "list_tags": return listTags()
            case "create_note": return try createNote(string(arguments, "path"), content: string(arguments, "content"))
            case "edit_note":
                return try editNote(string(arguments, "path"), old: string(arguments, "old_text"), new: string(arguments, "new_text"))
            case "append_to_note": return try append(string(arguments, "path"), text: string(arguments, "text"))
            case "move_note":
                let source = try existingNote(string(arguments, "path"))
                let destination = try clean(string(arguments, "destination"))
                guard VaultSession.noteExtensions.contains((source as NSString).pathExtension.lowercased()),
                      (source as NSString).pathExtension.lowercased() == (destination as NSString).pathExtension.lowercased()
                else { throw Failure("Move a note using the same file extension.") }
                try VaultRelocation.move(root: root, from: source, to: destination)
                return .text("Moved \(source) to \(destination).")
            case "check_links":
                let path = try (arguments["path"] as? String).map(existingNote)
                let links = buildIndex().brokenLinks
                let rows = links.keys.sorted().filter { path == nil || $0 == path }.flatMap { source in
                    (links[source] ?? []).map { "\(source): [[\($0)]]" }
                }
                return .text(rows.isEmpty ? "No unresolved links." : rows.joined(separator: "\n"))
            default: throw Failure("Unknown tool \(name).")
            }
        } catch {
            var result = Result.text(error.localizedDescription)
            result.isError = true
            return result
        }
    }

    private func string(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = arguments[key] as? String else { throw Failure("Missing `\(key)`.") }
        return value
    }

    // MARK: Paths

    private var allNotes: [FileNode] {
        VaultSession.flatten(VaultSession.scan(root: root, relative: ""))
            .filter { VaultSession.noteExtensions.contains($0.fileExtension) }
    }

    /// Lowercased title -> path, first one wins (like the app's link resolution).
    private var titles: [String: String] {
        var map: [String: String] = [:]
        for note in allNotes where map[note.title.lowercased()] == nil { map[note.title.lowercased()] = note.path }
        return map
    }

    /// A vault-relative path, refusing anything outside the vault or hidden (like `.git`).
    private func clean(_ path: String) throws -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(root.path + "/") { trimmed = String(trimmed.dropFirst(root.path.count + 1)) }
        while trimmed.hasPrefix("/") || trimmed.hasPrefix("./") { trimmed.removeFirst(trimmed.hasPrefix("/") ? 1 : 2) }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !trimmed.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == ".." || $0.hasPrefix(".") }) else {
            throw Failure("“\(path)” is not a valid path inside the vault.")
        }
        _ = try root.vaultFile(trimmed)
        return parts.joined(separator: "/")
    }

    /// An existing note, by path or by title (with or without extension).
    private func existingNote(_ path: String) throws -> String {
        let relative = try clean(path)
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path, isDirectory: &directory) {
            guard !directory.boolValue else { throw Failure("“\(relative)” is a folder.") }
            return relative
        }
        for ext in ["md", "ink"] where FileManager.default.fileExists(atPath: root.appendingPathComponent("\(relative).\(ext)").path) {
            return try clean("\(relative).\(ext)")
        }
        let name = ((relative as NSString).lastPathComponent as NSString)
        let title = VaultSession.noteExtensions.contains(name.pathExtension.lowercased()) ? name.deletingPathExtension : name as String
        if let found = titles[title.lowercased()] { return try clean(found) }
        throw Failure("No note “\(path)” in the vault. Use list_notes or search_notes to find it.")
    }

    private func markdownPath(_ path: String) throws -> String {
        let relative = try clean(path)
        let ext = (relative as NSString).pathExtension.lowercased()
        if ext == "ink" { throw Failure("“\(relative)” is a handwritten note; only Markdown notes can be changed.") }
        return ext == "md" || ext == "markdown" ? relative : relative + ".md"
    }

    private func readText(_ relative: String) throws -> String {
        guard let text = try? String(contentsOf: root.vaultFile(relative), encoding: .utf8) else {
            throw Failure("Couldn't read “\(relative)”.")
        }
        return text
    }

    private func write(_ text: String, to relative: String) throws {
        let url = try root.vaultFile(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Reading

    func listNotes(folder: String?) throws -> Result {
        let start = try folder.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : try clean($0) } ?? ""
        var lines: [String] = []
        func walk(_ nodes: [FileNode]) {
            for node in nodes where lines.count < 2000 {
                if node.isDirectory {
                    lines.append(node.path + "/")
                    walk(node.children ?? [])
                } else if VaultSession.noteExtensions.contains(node.fileExtension) {
                    lines.append(node.fileExtension == "ink" ? "\(node.path)  (handwritten)" : node.path)
                } else {
                    lines.append("\(node.path)  (\(FileKind(path: node.path) == .pdf ? "PDF" : "file"))")
                }
            }
        }
        walk(VaultSession.scan(root: root, relative: start))
        if lines.isEmpty { return .text(start.isEmpty ? "The vault is empty." : "“\(start)” is empty or doesn't exist.") }
        return .text(lines.joined(separator: "\n"))
    }

    func readNote(_ path: String, page: Int) throws -> Result {
        let relative = try existingNote(path)
        if relative.lowercased().hasSuffix(".ink") { return try readInk(relative, firstPage: max(1, page)) }
        let kind = FileKind(path: relative)
        if kind == .pdf { return try readPDF(relative, firstPage: max(1, page)) }
        guard [.markdown, .text].contains(kind) else {
            throw Failure("“\(relative)” isn't a note, text file or PDF.")
        }
        let text = try readText(relative)
        let limit = 200_000
        if text.count > limit {
            return .text("\(relative) (first \(limit) characters of \(text.count)):\n\n" + text.prefix(limit))
        }
        return .text(text.isEmpty ? "(\(relative) is empty)" : text)
    }

    /// Handwritten pages are this tall (the page is `InkDocument.pageWidth` wide), roughly A4/Letter.
    static let inkPageHeight: CGFloat = 1400
    static let pagesPerRead = 4

    func readInk(_ relative: String, firstPage: Int) throws -> Result {
        let data = (try? Data(contentsOf: root.appendingPathComponent(relative))) ?? Data()
        guard let document = InkDocument.decode(data) else { throw Failure("Couldn't read handwritten note “\(relative)”.") }
        let drawing = document.pkDrawing
        let images = document.images ?? []
        let bounds = document.contentBounds
        guard !bounds.isNull, !drawing.strokes.isEmpty || !images.isEmpty else {
            return .text("Handwritten note “\(relative)” is empty.")
        }
        let pageCount = max(1, Int((bounds.maxY / Self.inkPageHeight).rounded(.up)))
        guard firstPage <= pageCount else { throw Failure("“\(relative)” has \(pageCount) page(s).") }
        let last = min(pageCount, firstPage + Self.pagesPerRead - 1)
        var result = Result()
        var note = "Handwritten note “\(relative)”, \(document.paper.rawValue) paper"
        note += pageCount == 1 ? ", one page." : ", pages \(firstPage)–\(last) of \(pageCount)."
        note += " The images show the pages; read the handwriting and drawings from them."
        if last < pageCount { note += " Call read_note with page \(last + 1) for the rest." }
        result.addText(note)
        for index in (firstPage - 1)..<last {
            let rect = CGRect(x: 0, y: CGFloat(index) * Self.inkPageHeight, width: InkDocument.pageWidth, height: Self.inkPageHeight)
            guard drawing.strokes.contains(where: { $0.renderBounds.intersects(rect) })
                    || images.contains(where: { $0.frame.intersects(rect) }) else {
                result.addText("Page \(index + 1) is blank.")
                continue
            }
            if let png = InkSnapshot.png(drawing, images: images, root: root, rect: rect, pixelWidth: 1200) {
                if last > firstPage { result.addText("Page \(index + 1):") }
                result.addPNG(png)
            }
        }
        return result
    }

    /// A PDF's text and, as images, its pages with any handwriting on them.
    func readPDF(_ relative: String, firstPage: Int) throws -> Result {
        let url = root.appendingPathComponent(relative)
        guard let pages = PDFPages(url: url) else { throw Failure("Couldn't open “\(relative)” (it may be locked or damaged).") }
        guard firstPage <= pages.count else { throw Failure("“\(relative)” has \(pages.count) page(s).") }
        let notes = (try? Data(contentsOf: root.appendingPathComponent(VaultSession.annotationsPath(for: relative)))) ?? Data()
        let document = InkDocument.decode(notes) ?? InkDocument()
        let drawing = document.pkDrawing
        let images = document.images ?? []
        let text = PDFDocument(url: url)
        let last = min(pages.count, firstPage + Self.pagesPerRead - 1)

        var result = Result()
        var intro = "PDF “\(relative)”, "
        intro += pages.count == 1 ? "one page." : "pages \(firstPage)–\(last) of \(pages.count)."
        intro += " Each page's text is followed by an image of the page, which also shows any handwritten annotations."
        if last < pages.count { intro += " Call read_note with page \(last + 1) for the rest." }
        result.addText(intro)
        for index in (firstPage - 1)..<last {
            let pageText = (text?.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let annotated = drawing.strokes.contains { $0.renderBounds.intersects(pages.frames[index]) }
            var header = "Page \(index + 1)"
            if annotated { header += " (has handwritten annotations)" }
            result.addText(header + ":\n" + (pageText.isEmpty ? "(no text layer; read it from the image)" : String(pageText.prefix(8000))))
            var png: Data?
            (NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
                png = pages.render(index, drawing: drawing, images: images, root: root, scale: 1200 / InkDocument.pageWidth)
                    .flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
            }
            if let png { result.addPNG(png) }
        }
        return result
    }

    func search(_ query: String) throws -> Result {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { throw Failure("The query is empty.") }
        let notes = allNotes
        let index = buildIndex()
        let hits = index.search(needle, notes: notes)
        var lines: [String] = []
        for hit in hits {
            let text = index.text[hit.path] ?? ""
            var lineMatches = false
            for (number, line) in text.components(separatedBy: "\n").enumerated() where line.localizedStandardContains(needle) {
                lines.append("\(hit.path):\(number + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(240))")
                lineMatches = true
                if lines.count >= 100 { break }
            }
            if !lineMatches { lines.append("\(hit.path)  \(hit.snippet.prefix(240))") }
            if lines.count >= 100 { break }
        }
        return .text(lines.isEmpty ? "No matches for “\(needle)”." : lines.joined(separator: "\n"))
    }

    private func buildIndex() -> LinkIndex {
        let paths = VaultSession.flatten(VaultSession.scan(root: root, relative: "")).map(\.path)
        return indexedFiles.update(root: root, paths: paths)
    }

    func noteLinks(_ path: String) throws -> Result {
        let relative = try existingNote(path)
        let index = buildIndex()
        func list(_ paths: [String]?) -> String {
            guard let paths, !paths.isEmpty else { return "  (none)" }
            return paths.sorted().map { "  \($0)" }.joined(separator: "\n")
        }
        let tags = (index.noteTags[relative] ?? []).map { "#" + $0 }.joined(separator: " ")
        let aliases = (index.noteAliases[relative] ?? []).joined(separator: ", ")
        return .text("""
        \(relative)
        Links to:
        \(list(index.outgoing[relative]))
        Linked from:
        \(list(index.backlinks[relative]))
        Tags: \(tags.isEmpty ? "(none)" : tags)
        Aliases: \(aliases.isEmpty ? "(none)" : aliases)
        """)
    }

    func listTags() -> Result {
        let index = buildIndex()
        let lines = index.tags
            .map { (name: index.tagNames[$0.key] ?? $0.key, count: $0.value.count) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { "#\($0.name)  \($0.count)" }
        return .text(lines.isEmpty ? "No tags in the vault." : lines.joined(separator: "\n"))
    }

    // MARK: Changing

    func createNote(_ path: String, content: String) throws -> Result {
        let relative = try markdownPath(path)
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path) else {
            throw Failure("“\(relative)” already exists. Use edit_note or append_to_note to change it.")
        }
        try write(content, to: relative)
        return .text("Created \(relative).")
    }

    func editNote(_ path: String, old: String, new: String) throws -> Result {
        let relative = try existingNote(path)
        _ = try markdownPath(relative)
        guard !old.isEmpty else { throw Failure("`old_text` is empty; use append_to_note to add text.") }
        let text = try readText(relative)
        let count = text.components(separatedBy: old).count - 1
        guard count == 1 else {
            throw Failure(count == 0
                ? "`old_text` wasn't found in \(relative). Read the note again and copy the text exactly."
                : "`old_text` appears \(count) times in \(relative); include more surrounding text so it's unique.")
        }
        try write(text.replacingOccurrences(of: old, with: new), to: relative)
        return .text("Edited \(relative).")
    }

    func append(_ path: String, text: String) throws -> Result {
        let relative: String
        if let existing = try? existingNote(path) { relative = existing } else { relative = try markdownPath(path) }
        _ = try markdownPath(relative)
        let url = root.appendingPathComponent(relative)
        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let created = !FileManager.default.fileExists(atPath: url.path)
        if !existing.isEmpty, !existing.hasSuffix("\n") { existing += "\n" }
        try write(existing + text + (text.hasSuffix("\n") ? "" : "\n"), to: relative)
        return .text(created ? "Created \(relative)." : "Appended to \(relative).")
    }
}

/// Renders handwriting as a PNG on white paper, in light-mode ink colours.
enum InkSnapshot {
    static func png(_ drawing: PKDrawing, images: [InkImage] = [], root: URL? = nil, rect: CGRect, pixelWidth: CGFloat) -> Data? {
        let scale = pixelWidth / rect.width
        if let root, images.contains(where: { $0.frame.intersects(rect) }) {
            var output: CGImage?
            (NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
                output = InkRenderer.compose(drawing, images: images, root: root, rect: rect, scale: scale, dark: false,
                                             background: CGColor(gray: 1, alpha: 1))
            }
            return output.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        }
        let width = Int(rect.width * scale), height = Int(rect.height * scale)
        var image: NSImage?
        (NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            image = drawing.image(from: rect, scale: scale)
        }
        var proposed = CGRect(x: 0, y: 0, width: width, height: height)
        guard let ink = image?.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(ink, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])
    }
}
#endif
