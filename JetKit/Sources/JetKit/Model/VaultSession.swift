import Foundation
import Observation
import UniformTypeIdentifiers

public enum NoteKind: String, Sendable {
    case ink, markdown

    var fileExtension: String { self == .ink ? "ink" : "md" }

    /// Handwriting first on iPad, typing first on the Mac.
    public static var platformDefault: NoteKind {
        #if os(iOS)
        .ink
        #else
        .markdown
        #endif
    }
}

/// A file or folder in the vault, identified by its path relative to the vault root.
public struct FileNode: Identifiable, Hashable, Sendable {
    public let path: String
    public let isDirectory: Bool
    public var children: [FileNode]?

    public var id: String { path }
    public var fileName: String { (path as NSString).lastPathComponent }
    public var fileExtension: String { (path as NSString).pathExtension.lowercased() }
    public var title: String {
        isDirectory || !VaultSession.noteExtensions.contains(fileExtension)
            ? fileName
            : (fileName as NSString).deletingPathExtension
    }
}

public struct NewNoteRequest: Equatable, Sendable {
    public let kind: NoteKind
    public let folder: String
}

public struct SearchHit: Identifiable, Hashable, Sendable {
    public let path: String
    public let snippet: String
    public var id: String { path }
}

public enum SyncState: Equatable {
    case idle
    case syncing
    case failed(String)
}

/// Everything about one open vault: its file tree, selection, and git sync.
@MainActor
@Observable
public final class VaultSession {
    public nonisolated static let noteExtensions: Set<String> = ["md", "markdown", "ink"]

    public let ref: VaultRef
    public let root: URL

    public var tree: [FileNode] = []
    /// The open note. Remembered per vault so the app reopens where you left off.
    public var selection: String? { didSet { defaults.set(selection, forKey: key("lastNote")) } }
    /// Bumped whenever sync rewrote files, so open editors reload.
    public var contentVersion = 0

    public var syncState: SyncState = .idle
    public var lastSync: Date?
    public var lastSyncSummary = ""
    public var pendingChanges = 0
    public var remoteURL = ""
    public var username: String { didSet { defaults.set(username, forKey: key("username")) } }
    public var autoSync: Bool { didSet { defaults.set(autoSync, forKey: key("autoSync")) } }

    /// Lowercased note title -> relative path.
    public private(set) var notesByTitle: [String: String] = [:]
    /// Links, tags and aliases across the vault's Markdown notes.
    public private(set) var index = LinkIndex()
    /// Bumped each time `index` is rebuilt.
    public private(set) var indexVersion = 0
    /// The sidebar's search field. Tapping a `#tag` in a note fills it with that tag.
    public var sidebarQuery = ""
    /// A note waiting for its name in the "New note" prompt (iPad).
    public var pendingNewNote: NewNoteRequest?

    @ObservationIgnored private var flushHandlers: [UUID: () -> Void] = [:]
    @ObservationIgnored private var lastLocalWrite = Date.distantPast
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    #if os(macOS)
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var externalChangeTask: Task<Void, Never>?
    #endif
    @ObservationIgnored private var indexGeneration = 0

    private func key(_ name: String) -> String { "vault.\(ref.id.uuidString).\(name)" }

    public init(ref: VaultRef) {
        self.ref = ref
        self.root = ref.url
        self.username = UserDefaults.standard.string(forKey: "vault.\(ref.id.uuidString).username") ?? ""
        self.autoSync = UserDefaults.standard.object(forKey: "vault.\(ref.id.uuidString).autoSync") as? Bool ?? true
        if GitRepository.isRepository(at: root.path), let repo = try? GitRepository.open(at: root.path) {
            remoteURL = repo.remoteURL ?? ""
        }
        refreshTree()
        refreshStatus()
        #if os(macOS)
        // Notes changed by other programs (an AI assistant, a text editor, git) show up right away.
        watcher = FolderWatcher(path: root.path) { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
        #endif
        if let last = UserDefaults.standard.string(forKey: "vault.\(ref.id.uuidString).lastNote"), exists(last) {
            selection = last
        }
    }

    #if os(macOS)
    private func folderChanged() {
        externalChangeTask?.cancel()
        externalChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.refreshTree()
            // Open editors reload only if the file differs from what they last saved, so Jet's own
            // saves don't disturb typing.
            self.contentVersion += 1
            self.refreshStatus()
        }
    }
    #endif

    // MARK: Files

    public func url(for path: String) -> URL { root.appendingPathComponent(path) }

    public func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url(for: path).path, isDirectory: &isDir) && isDir.boolValue
    }

    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: path).path)
    }

    nonisolated static func scan(root: URL, relative: String) -> [FileNode] {
        let fm = FileManager.default
        let directory = relative.isEmpty ? root : root.appendingPathComponent(relative)
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var nodes: [FileNode] = []
        for name in names where !name.hasPrefix(".") {
            let child = relative.isEmpty ? name : relative + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                nodes.append(FileNode(path: child, isDirectory: true, children: scan(root: root, relative: child)))
            } else {
                nodes.append(FileNode(path: child, isDirectory: false, children: nil))
            }
        }
        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
        }
    }

    nonisolated static func flatten(_ nodes: [FileNode]) -> [FileNode] {
        nodes.flatMap { node in node.isDirectory ? flatten(node.children ?? []) : [node] }
    }

    public var allNotes: [FileNode] {
        Self.flatten(tree).filter { Self.noteExtensions.contains($0.fileExtension) }
    }

    public func refreshTree() {
        tree = Self.scan(root: root, relative: "")
        if let selected = selection, !exists(selected) { selection = nil }

        var titles: [String: String] = [:]
        for note in allNotes where titles[note.title.lowercased()] == nil {
            titles[note.title.lowercased()] = note.path
        }
        notesByTitle = titles
        rebuildIndex()
    }

    /// Re-reads every Markdown note for links and tags, after `delay` (later calls replace earlier ones).
    public func rebuildIndex(after delay: Duration = .zero) {
        indexTask?.cancel()
        indexGeneration += 1
        let generation = indexGeneration
        let root = root
        let titles = notesByTitle
        let markdown = allNotes.filter { $0.fileExtension != "ink" }.map(\.path)
        indexTask = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let built = await Task.detached(priority: .utility) {
                LinkIndex.build(root: root, markdown: markdown, titles: titles)
            }.value
            guard generation == indexGeneration else { return }
            index = built
            indexVersion += 1
        }
    }

    private func uniquePath(folder: String, base: String, ext: String) -> String {
        var candidate = base
        var counter = 2
        while true {
            let name = ext.isEmpty ? candidate : "\(candidate).\(ext)"
            let path = folder.isEmpty ? name : "\(folder)/\(name)"
            if !exists(path) { return path }
            candidate = "\(base) \(counter)"
            counter += 1
        }
    }

    /// The folder a new item should land in, given what is selected.
    public var targetFolder: String {
        guard let selected = selection else { return "" }
        return isDirectory(selected) ? selected : (selected as NSString).deletingLastPathComponent
    }

    @discardableResult
    public func createNote(kind: NoteKind, in folder: String? = nil, named name: String = "Untitled") -> String? {
        let folder = folder ?? targetFolder
        let path = uniquePath(folder: folder, base: name, ext: kind.fileExtension)
        let data = kind == .ink ? InkDocument().encoded() : Data()
        do {
            try FileManager.default.createDirectory(at: url(for: folder), withIntermediateDirectories: true)
            try data.write(to: url(for: path))
        } catch { return nil }
        didWriteFile()
        refreshTree()
        selection = path
        return path
    }

    /// Creates a folder (renamed "Name 2", "Name 3"… if taken) and returns its path.
    @discardableResult
    /// Starts a new note from a button or shortcut. On iPad this asks for a name first;
    /// on the Mac the note is created right away as "Untitled" and renamed by editing its title.
    public func requestNewNote(kind: NoteKind, in folder: String? = nil) {
        #if os(iOS)
        pendingNewNote = NewNoteRequest(kind: kind, folder: folder ?? targetFolder)
        #else
        createNote(kind: kind, in: folder)
        #endif
    }

    /// Finishes a `requestNewNote`; an empty name means "Untitled".
    public func createPendingNote(named name: String) {
        guard let request = pendingNewNote else { return }
        pendingNewNote = nil
        var clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        while clean.hasPrefix(".") { clean.removeFirst() }
        createNote(kind: request.kind, in: request.folder, named: clean.isEmpty ? "Untitled" : clean)
    }

    public func createFolder(in folder: String? = nil, named name: String = "New Folder") -> String? {
        var clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        while clean.hasPrefix(".") { clean.removeFirst() }
        let path = uniquePath(folder: folder ?? targetFolder, base: clean.isEmpty ? "New Folder" : clean, ext: "")
        do {
            try FileManager.default.createDirectory(at: url(for: path), withIntermediateDirectories: true)
            // Git doesn't track empty folders; a hidden placeholder lets the new folder sync right away.
            try Data().write(to: url(for: path).appendingPathComponent(".gitkeep"))
        } catch { return nil }
        didWriteFile()
        refreshTree()
        return path
    }

    public func rename(_ path: String, to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty, !clean.hasPrefix(".") else { return }
        flushEditors()
        let folder = (path as NSString).deletingLastPathComponent
        let ext = isDirectory(path) ? "" : (path as NSString).pathExtension
        let name = ext.isEmpty ? clean : "\(clean).\(ext)"
        let newPath = folder.isEmpty ? name : "\(folder)/\(name)"
        guard newPath != path, !exists(newPath) else { return }
        let wasSelected = selection == path
        if wasSelected { selection = nil }
        do {
            try FileManager.default.moveItem(at: url(for: path), to: url(for: newPath))
        } catch { return }
        // A PDF's annotations travel with it.
        let notes = Self.annotationsPath(for: path)
        if exists(notes) {
            try? FileManager.default.moveItem(at: url(for: notes), to: url(for: Self.annotationsPath(for: newPath)))
        }
        didWriteFile()
        refreshTree()
        if wasSelected { selection = newPath }
    }

    /// Moves a file or folder into `folder` ("" is the vault's top level), renamed "Name 2" if the
    /// name is taken there. A PDF's annotations go with it; an open note stays open. Returns the new path.
    @discardableResult
    public func move(_ path: String, into folder: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        guard exists(path), parent != folder, folder != path, !folder.hasPrefix(path + "/"),
              folder.isEmpty || isDirectory(folder) else { return nil }
        flushEditors()
        let name = (path as NSString).lastPathComponent
        let ext = isDirectory(path) ? "" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let newPath = uniquePath(folder: folder, base: base, ext: ext)
        let selected = selection
        if let selected, selected == path || selected.hasPrefix(path + "/") { selection = nil }
        do {
            try FileManager.default.moveItem(at: url(for: path), to: url(for: newPath))
        } catch {
            selection = selected
            return nil
        }
        let notes = Self.annotationsPath(for: path)
        if exists(notes) {
            try? FileManager.default.moveItem(at: url(for: notes), to: url(for: Self.annotationsPath(for: newPath)))
        }
        didWriteFile()
        refreshTree()
        if let selected {
            if selected == path { selection = newPath }
            else if selected.hasPrefix(path + "/") { selection = newPath + selected.dropFirst(path.count) }
            else { selection = selected }
        }
        return newPath
    }

    public func delete(_ path: String) {
        if let selected = selection, selected == path || selected.hasPrefix(path + "/") { selection = nil }
        try? FileManager.default.removeItem(at: url(for: path))
        try? FileManager.default.removeItem(at: url(for: Self.annotationsPath(for: path)))
        didWriteFile()
        refreshTree()
    }

    // MARK: Attachments

    public nonisolated static let attachmentsFolder = "Attachments"

    /// Saves a picked or pasted picture in `Attachments/` and returns its path. `name` is a suggested
    /// file name (without extension); pictures with no name of their own get a dated one.
    public func addImage(_ data: Data, type: UTType?, named name: String? = nil) -> String? {
        guard let prepared = ImageFiles.prepareForVault(data, type: type) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        var base = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "Image \(formatter.string(from: Date()))" }
        let path = uniquePath(folder: Self.attachmentsFolder, base: base, ext: prepared.ext)
        do {
            try FileManager.default.createDirectory(at: url(for: Self.attachmentsFolder), withIntermediateDirectories: true)
            try prepared.data.write(to: url(for: path))
        } catch { return nil }
        didWriteFile()
        refreshTree()
        return path
    }

    /// GitHub refuses files over 100 MB, which would stop the vault syncing; it warns from 50 MB.
    public nonisolated static let largeFileWarning = 50_000_000
    public nonisolated static let largestSyncableFile = 100_000_000

    /// Files waiting on a decision because some are big (see `requestImport`).
    public struct ImportReview: Identifiable, Sendable {
        public let id = UUID()
        public var folder: String
        public var normal: [URL]
        public var large: [(url: URL, size: Int)]
        public var tooLarge: [(url: URL, size: Int)]
    }

    /// Imports that need the user's say-so: shown by the vault window.
    public var importReview: ImportReview?

    /// Imports files, checking sizes first: anything over 100 MB is refused (git sync would fail on
    /// it), and 50–100 MB files are only imported once the user confirms.
    public func requestImport(_ urls: [URL], into folder: String? = nil) {
        let folder = folder ?? targetFolder
        var review = ImportReview(folder: folder, normal: [], large: [], tooLarge: [])
        for url in urls {
            let size = Self.size(of: url)
            if size > Self.largestSyncableFile { review.tooLarge.append((url, size)) }
            else if size > Self.largeFileWarning { review.large.append((url, size)) }
            else { review.normal.append(url) }
        }
        if review.large.isEmpty && review.tooLarge.isEmpty {
            finishImport(review.normal, into: folder)
        } else {
            importReview = review
        }
    }

    /// Completes an `importReview`, with or without its large files.
    public func resolveImport(includeLarge: Bool) {
        guard let review = importReview else { return }
        importReview = nil
        finishImport(review.normal + (includeLarge ? review.large.map(\.url) : []), into: review.folder)
    }

    private func finishImport(_ urls: [URL], into folder: String) {
        guard !urls.isEmpty else { return }
        importFiles(urls, into: folder)
        // Copies iPadOS left in Documents/Inbox, or that a drop made in the temporary folder.
        let inbox = AppModel.vaultsDirectory.appendingPathComponent("Inbox").standardizedFileURL.path + "/"
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("JetDrops").standardizedFileURL.path + "/"
        for url in urls where url.standardizedFileURL.path.hasPrefix(inbox) || url.standardizedFileURL.path.hasPrefix(temporary) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Bytes in a file, or in everything inside a folder.
    nonisolated static func size(of url: URL) -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileSizeKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true { return values.totalFileSize ?? values.fileSize ?? 0 }
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        var total = 0
        while let item = items?.nextObject() as? URL {
            total += (try? item.resourceValues(forKeys: keys)).flatMap { $0.totalFileSize ?? $0.fileSize } ?? 0
        }
        return total
    }

    /// Copies files from elsewhere (Files, another app, Finder) into `folder`, keeping their names
    /// (made unique), and opens the last one. Returns the new paths.
    @discardableResult
    public func importFiles(_ urls: [URL], into folder: String? = nil) -> [String] {
        let folder = folder ?? targetFolder
        var added: [String] = []
        for source in urls {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            var base = source.deletingPathExtension().lastPathComponent
            while base.hasPrefix(".") { base.removeFirst() }
            if base.isEmpty { base = "Imported" }
            let path = uniquePath(folder: folder, base: base, ext: source.pathExtension)
            do {
                try FileManager.default.createDirectory(at: url(for: folder), withIntermediateDirectories: true)
                // Coordinated, so files still downloading from iCloud or another provider arrive whole.
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
                    do { try FileManager.default.copyItem(at: readable, to: self.url(for: path)) } catch { copyError = error }
                }
                if let error = coordinationError ?? copyError { throw error }
                added.append(path)
            } catch {
                continue
            }
        }
        guard !added.isEmpty else { return [] }
        didWriteFile()
        refreshTree()
        selection = added.last
        return added
    }

    /// How a note should name a file in a `![[…]]` embed: just its file name when that's unique in
    /// the vault (like Obsidian), otherwise its full path.
    public func linkTarget(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let sameName = Self.flatten(tree).filter { $0.fileName.lowercased() == name.lowercased() }
        return sameName.count <= 1 ? name : path
    }

    // MARK: Links & tags

    /// The note a link target names: its title, or one of its `aliases`.
    public func path(forTitle title: String) -> String? {
        notesByTitle[title.lowercased()] ?? index.aliases[title.lowercased()]
    }

    /// Opens the note a `[[wikilink]]` points at, creating it next to the current note if it does not exist.
    public func openLink(_ target: String) {
        let name = target.split(separator: "#").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? target
        let bare = Self.noteExtensions.contains((name as NSString).pathExtension.lowercased())
            ? (name as NSString).deletingPathExtension : name
        if let path = path(forTitle: (bare as NSString).lastPathComponent) {
            selection = path
        } else if !bare.isEmpty {
            createNote(kind: .markdown, named: (bare as NSString).lastPathComponent)
        }
    }

    public func resolve(_ target: String) -> String? {
        if exists(target), !isDirectory(target) { return target }
        let name = (target as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        if Self.noteExtensions.contains(ext) || ext.isEmpty {
            return path(forTitle: (name as NSString).deletingPathExtension)
        }
        return Self.flatten(tree).first { $0.fileName.lowercased() == name.lowercased() }?.path
    }

    /// Notes with this tag or one nested under it (`#project` also finds `#project/jet`).
    public func notes(taggedWith tag: String) -> [String] {
        let tag = String(tag.drop { $0 == "#" }).lowercased()
        guard !tag.isEmpty else { return [] }
        var seen = Set<String>()
        return index.tags
            .filter { $0.key == tag || $0.key.hasPrefix(tag + "/") }
            .flatMap(\.value)
            .filter { seen.insert($0).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Every tag in the vault with how many notes use it, alphabetically.
    public var allTags: [(name: String, count: Int)] {
        index.tags
            .map { (name: index.tagNames[$0.key] ?? $0.key, count: $0.value.count) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Notes that mention this note's title or an alias as plain text, without linking to it.
    public func unlinkedMentions(of path: String) async -> [SearchHit] {
        let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        // Longest first, so "Jet app" wins over "Jet" when both would match.
        let names = ([title] + (index.noteAliases[path] ?? [])).sorted { $0.count > $1.count }
        let linked = Set(index.backlinks[path] ?? [])
        let candidates = allNotes.filter { $0.fileExtension != "ink" && $0.path != path && !linked.contains($0.path) }
        let root = root
        return await Task.detached(priority: .utility) {
            var hits: [SearchHit] = []
            for note in candidates {
                if Task.isCancelled { return [] }
                guard let text = try? String(contentsOf: root.appendingPathComponent(note.path), encoding: .utf8) else { continue }
                for name in names {
                    guard let range = NoteSyntax.unlinkedMentionRanges(of: name, in: text).first else { continue }
                    let line = (text as NSString).lineRange(for: range)
                    let snippet = (text as NSString).substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
                    hits.append(SearchHit(path: note.path, snippet: snippet))
                    break
                }
            }
            return hits.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }.value
    }

    /// Turns the first plain-text mention of `target`'s title (or an alias) in `source` into a link.
    public func linkMention(in source: String, to target: String) {
        flushEditors()
        let title = ((target as NSString).lastPathComponent as NSString).deletingPathExtension
        let url = url(for: source)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for name in ([title] + (index.noteAliases[target] ?? [])).sorted(by: { $0.count > $1.count }) {
            if let linked = NoteSyntax.linkingFirstMention(of: name, in: text) {
                guard (try? linked.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
                didWriteFile()
                contentVersion += 1
                rebuildIndex()
                return
            }
        }
    }

    // MARK: Daily notes

    public nonisolated static let dailyFolder = "Daily"
    public nonisolated static let dailyTemplate = "Templates/Daily.md"

    /// Opens the note for `date` in `Daily/`, creating it (from `Templates/Daily.md` if there is one).
    public func openDailyNote(for date: Date = .now) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let name = formatter.string(from: date)
        let path = "\(Self.dailyFolder)/\(name).md"
        if !exists(path) {
            var text = (try? String(contentsOf: url(for: Self.dailyTemplate), encoding: .utf8)) ?? ""
            text = text.replacingOccurrences(of: "{{date}}", with: name)
                .replacingOccurrences(of: "{{title}}", with: name)
                .replacingOccurrences(of: "{{weekday}}", with: date.formatted(.dateTime.weekday(.wide)))
            do {
                try FileManager.default.createDirectory(at: url(for: Self.dailyFolder), withIntermediateDirectories: true)
                try text.write(to: url(for: path), atomically: true, encoding: .utf8)
            } catch { return }
            didWriteFile()
            refreshTree()
        }
        selection = path
    }

    /// The day a daily note is for, if `path` is one.
    public nonisolated static func dailyDate(of path: String) -> Date? {
        guard (path as NSString).deletingLastPathComponent == dailyFolder else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: ((path as NSString).lastPathComponent as NSString).deletingPathExtension)
    }

    // MARK: Search

    /// Full-text search of note titles and Markdown. A query starting with `#` lists notes with that tag.
    public func search(_ query: String) async -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        if needle.hasPrefix("#"), !needle.contains(" ") {
            return notes(taggedWith: needle).map { path in
                SearchHit(path: path, snippet: (index.noteTags[path] ?? []).map { "#" + $0 }.joined(separator: " "))
            }
        }
        let notes = allNotes
        let root = root
        return await Task.detached(priority: .userInitiated) {
            var hits: [SearchHit] = []
            for note in notes {
                if Task.isCancelled { return [] }
                var snippet: String?
                if note.fileExtension != "ink",
                   let text = try? String(contentsOf: root.appendingPathComponent(note.path), encoding: .utf8),
                   let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
                    snippet = String(text[text.lineRange(for: range)]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if snippet == nil, note.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    snippet = ""
                }
                if let snippet { hits.append(SearchHit(path: note.path, snippet: snippet)) }
            }
            return hits
        }.value
    }

    // MARK: Editors

    /// Open editors register a closure that writes their unsaved changes to disk.
    public func registerEditor(_ flush: @escaping () -> Void) -> UUID {
        let id = UUID()
        flushHandlers[id] = flush
        return id
    }

    public func unregisterEditor(_ id: UUID?) {
        if let id { flushHandlers[id] = nil }
    }

    public func flushEditors() {
        flushHandlers.values.forEach { $0() }
    }

    public func didWriteFile() {
        lastLocalWrite = Date()
        if pendingChanges == 0 { pendingChanges = 1 }
        rebuildIndex(after: .seconds(1))
    }

    // MARK: Sync

    public var hasRemote: Bool { !remoteURL.isEmpty }

    public var token: String {
        get { Keychain.get(ref.id.uuidString) ?? "" }
        set { Keychain.set(newValue, for: ref.id.uuidString) }
    }

    public func setRemote(_ url: String) throws {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        try GitRepository.openOrCreate(at: root.path).setRemoteURL(url)
        remoteURL = url
    }

    public func refreshStatus() {
        let path = root.path
        Task.detached(priority: .utility) {
            let count = GitRepository.isRepository(at: path) ? ((try? GitRepository.open(at: path))?.changeCount() ?? 0) : 0
            await MainActor.run { self.pendingChanges = count }
        }
    }

    public func sync(author: GitAuthor) async {
        guard syncState != .syncing else { return }
        flushEditors()
        syncState = .syncing

        let path = root.path
        let token = token
        let credentials = token.isEmpty ? nil : GitCredentials(username: username.isEmpty ? "git" : username, password: token)
        let device = AppModel.deviceName
        do {
            let report = try await Task.detached(priority: .userInitiated) {
                try SyncEngine.sync(vaultPath: path, credentials: credentials, author: author, deviceName: device)
            }.value
            lastSync = Date()
            lastSyncSummary = report.summary
            syncState = .idle
            if report.workingTreeChanged {
                refreshTree()
                contentVersion += 1
            }
        } catch {
            syncState = .failed(error.localizedDescription)
        }
        refreshStatus()
    }

    /// Runs for as long as the vault is on screen: syncs on open, after edits settle, and periodically to pull.
    public func autoSyncLoop(author: @escaping @MainActor () -> GitAuthor) async {
        if hasRemote, autoSync { await sync(author: author()) }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, autoSync, hasRemote, syncState != .syncing else { continue }
            let editsSettled = Date().timeIntervalSince(lastLocalWrite) > 45
            let stale = lastSync.map { Date().timeIntervalSince($0) > 300 } ?? true
            if (pendingChanges > 0 && editsSettled) || (stale && syncState == .idle) {
                await sync(author: author())
            }
        }
    }
}
