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
    /// When the file was last changed (for sorting by date).
    public var modified: Date? = nil

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

    #if os(macOS)
    var wordCountRequest = 0
    #endif

    public var tree: [FileNode] = []
    /// The open note. Remembered per vault so the app reopens where you left off.
    public var selection: String? {
        didSet {
            defaults.set(selection, forKey: key("lastNote"))
            // Opening something makes its folder where new things go again.
            guard selection != oldValue else { return }
            workingFolder = nil
            guard let selection else { return }
            if !navigatingHistory {
                if let oldValue, exists(oldValue) { backPaths.append(oldValue) }
                forwardPaths.removeAll()
            }
            if Self.noteExtensions.contains((selection as NSString).pathExtension.lowercased()), !isDirectory(selection) {
                recentNotes.removeAll { $0 == selection }
                recentNotes.insert(selection, at: 0)
                recentNotes = Array(recentNotes.prefix(50))
                defaults.set(recentNotes, forKey: key("recentNotes"))
            }
        }
    }
    var headingJump: MarkdownHeadingJump?
    var showCommandPalette = false
    var backPaths: [String] = []
    var forwardPaths: [String] = []
    private var navigatingHistory = false
    private(set) var recentNotes: [String] = []

    func navigate(back: Bool) {
        var candidates = back ? backPaths : forwardPaths
        var destination: String?
        while let path = candidates.popLast() {
            if path != selection, exists(path) { destination = path; break }
        }
        if back { backPaths = candidates } else { forwardPaths = candidates }
        guard let destination else { return }
        if let selection {
            if back { forwardPaths.append(selection) } else { backPaths.append(selection) }
        }
        navigatingHistory = true
        selection = destination
        navigatingHistory = false
    }

    func remapNavigation(from old: String, to new: String) {
        func remap(_ path: String) -> String {
            path == old || path.hasPrefix(old + "/") ? new + path.dropFirst(old.count) : path
        }
        backPaths = backPaths.map(remap)
        forwardPaths = forwardPaths.map(remap)
        recentNotes = recentNotes.map(remap)
        defaults.set(recentNotes, forKey: key("recentNotes"))
    }

    /// Where new notes and folders go when chosen apart from what's open (the sidebar's Home, or a
    /// click on empty space: back to the top level, with the open note left open). Nil follows `selection`.
    public var workingFolder: String?
    /// Bumped whenever sync rewrote files, so open editors reload.
    public var contentVersion = 0

    public var syncState: SyncState = .idle
    public var lastSync: Date?
    public var lastSyncSummary = ""
    public private(set) var lastConflictPaths: [String] = []
    public var pendingChanges = 0
    public var remoteURL = ""
    public var username: String { didSet { defaults.set(username, forKey: key("username")) } }
    public var autoSync: Bool { didSet { defaults.set(autoSync, forKey: key("autoSync")) } }
    /// How the sidebar orders each folder. Manual follows the order you dragged things into.
    public var sortMode: SortMode = .name {
        didSet {
            guard sortMode != oldValue else { return }
            defaults.set(sortMode.rawValue, forKey: key("sortMode"))
            refreshTree()
        }
    }
    /// Manual order: folder path ("" for the top level) -> names in order. Kept in `.jet/order.json`
    /// so it syncs with the vault.
    @ObservationIgnored var manualOrder: [String: [String]] = [:]

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
    @ObservationIgnored private let indexStore: VaultIndexStore
    @ObservationIgnored private var lookup = VaultLinks(paths: [])

    private func key(_ name: String) -> String { "vault.\(ref.id.uuidString).\(name)" }

    public init(ref: VaultRef) {
        self.ref = ref
        self.root = ref.url
        self.indexStore = VaultIndexStore(root: ref.url)
        self.username = UserDefaults.standard.string(forKey: "vault.\(ref.id.uuidString).username") ?? ""
        self.autoSync = UserDefaults.standard.object(forKey: "vault.\(ref.id.uuidString).autoSync") as? Bool ?? true
        self.sortMode = (UserDefaults.standard.string(forKey: "vault.\(ref.id.uuidString).sortMode")).flatMap(SortMode.init) ?? .name
        self.recentNotes = UserDefaults.standard.stringArray(forKey: "vault.\(ref.id.uuidString).recentNotes") ?? []
        self.lastConflictPaths = UserDefaults.standard.stringArray(forKey: "vault.\(ref.id.uuidString).lastConflicts") ?? []
        self.manualOrder = Self.loadOrder(root: ref.url)
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
            let url = directory.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .contentModificationDateKey])
            guard values?.isSymbolicLink != true else { continue }
            let modified = values?.contentModificationDate
            if isDir.boolValue {
                nodes.append(FileNode(path: child, isDirectory: true, children: scan(root: root, relative: child), modified: modified))
            } else {
                nodes.append(FileNode(path: child, isDirectory: false, children: nil, modified: modified))
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
        tree = arranged(Self.scan(root: root, relative: ""), in: "")
        if let selected = selection, !exists(selected) { selection = nil }

        var titles: [String: String] = [:]
        for note in allNotes where titles[note.title.lowercased()] == nil {
            titles[note.title.lowercased()] = note.path
        }
        notesByTitle = titles
        lookup = VaultLinks(paths: Self.flatten(tree).map(\.path), aliases: index.aliases)
        rebuildIndex()
    }

    /// Reconciles changed note files against the saved index after edits settle.
    public func rebuildIndex(after delay: Duration = .zero) {
        indexTask?.cancel()
        indexGeneration += 1
        let generation = indexGeneration
        let root = root
        let paths = Self.flatten(tree).map(\.path)
        indexTask = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let built = await indexStore.update(root: root, paths: paths)
            guard generation == indexGeneration else { return }
            index = built
            lookup.aliases = built.aliases
            indexVersion += 1
        }
    }

    func uniquePath(folder: String, base: String, ext: String) -> String {
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
        if let workingFolder { return workingFolder }
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

    /// Creates a folder (renamed "Name 2", "Name 3"… if taken) and returns its path.
    @discardableResult
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
        _ = relocate(path, to: newPath)
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
        return relocate(path, to: newPath)
    }

    private func relocate(_ path: String, to newPath: String) -> String? {
        let selected = selection
        do {
            try VaultRelocation.move(root: root, from: path, to: newPath)
        } catch {
            fileOperationError = error.localizedDescription
            return nil
        }
        navigatingHistory = true
        defer { navigatingHistory = false }
        remapNavigation(from: path, to: newPath)
        contentVersion += 1
        orderRenamed(from: path, to: newPath)
        didWriteFile()
        refreshTree()
        if let selected {
            if selected == path { selection = newPath }
            else if selected.hasPrefix(path + "/") { selection = newPath + selected.dropFirst(path.count) }
            else { selection = selected }
        }
        return newPath
    }

    /// Copies only what's in a file or folder: not its owner, permissions, locks or access rules,
    /// which would come along with a plain copy and can make the copy impossible to delete.
    nonisolated static func copyContents(of source: URL, to destination: URL) throws {
        let flags = copyfile_flags_t(COPYFILE_DATA | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: destination)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    /// Deletes a file or folder even when it carries access rules that forbid deleting (for example
    /// a copy of ~/Downloads made by an older Jet): those rules are cleared first.
    nonisolated static func forceRemove(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            let fm = FileManager.default
            var paths = [url.path]
            if let items = fm.enumerator(atPath: url.path) {
                while let item = items.nextObject() as? String { paths.append(url.appendingPathComponent(item).path) }
            }
            for path in paths {
                if let empty = acl_init(0) {
                    acl_set_file(path, ACL_TYPE_EXTENDED, empty)
                    acl_free(UnsafeMutableRawPointer(empty))
                }
                chflags(path, 0)
                chmod(path, 0o755)
            }
            try fm.removeItem(at: url)
        }
    }

    public func delete(_ path: String) {
        if let selected = selection, selected == path || selected.hasPrefix(path + "/") { selection = nil }
        try? Self.forceRemove(url(for: path))
        try? FileManager.default.removeItem(at: url(for: Self.annotationsPath(for: path)))
        orderRenamed(from: path, to: nil)
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
        /// Things Jet won't take at all, with why (apps, unreadable folders, the vault itself…).
        public var refused: [(url: URL, reason: String)] = []
    }

    /// Folders bigger than this many files aren't imported: that's a dump of something, not notes.
    public nonisolated static let largestImportedFolder = 1000

    /// What an import candidate is, before anything is copied.
    enum ImportCheck: Equatable {
        case ok(size: Int)
        case refused(String)
    }

    /// Checks a file or folder from elsewhere: it must be readable, not an app or other bundle, not
    /// contain the vault, and (for folders) hold a sane number of plain files.
    nonisolated static func check(_ url: URL, vaultRoot: URL) -> ImportCheck {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey,
                                         .totalFileSizeKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return .refused("Jet can't read it") }
        if values.isPackage == true { return .refused("apps and other bundles can't go in a vault") }
        if values.isSymbolicLink == true || values.isAliasFile == true { return .refused("it's a shortcut to something else") }
        guard values.isDirectory == true else { return .ok(size: values.totalFileSize ?? values.fileSize ?? 0) }

        let source = url.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let root = vaultRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        if root.hasPrefix(source) || source.hasPrefix(root) { return .refused("it contains this vault") }
        // macOS keeps some folders (Downloads, Desktop…) private unless you allow it; a folder Jet
        // can't list would come in empty.
        guard (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else {
            return .refused("Jet isn't allowed to read that folder; drag in the files themselves")
        }
        var total = 0, count = 0
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                   options: [], errorHandler: { _, _ in false })
        while let item = items?.nextObject() as? URL {
            guard let itemValues = try? item.resourceValues(forKeys: keys) else { return .refused("Jet can't read everything in it") }
            if itemValues.isPackage == true { return .refused("it contains apps or other bundles") }
            if itemValues.isDirectory != true {
                count += 1
                total += itemValues.totalFileSize ?? itemValues.fileSize ?? 0
            }
            if count > largestImportedFolder { return .refused("it has more than \(largestImportedFolder) files") }
        }
        return .ok(size: total)
    }

    /// Imports that need the user's say-so: shown by the vault window.
    public var importReview: ImportReview?
    public var fileOperationError: String?

    /// Imports files, checking sizes first: anything over 100 MB is refused (git sync would fail on
    /// it), and 50–100 MB files are only imported once the user confirms.
    public func requestImport(_ urls: [URL], into folder: String? = nil) {
        let folder = folder ?? targetFolder
        var review = ImportReview(folder: folder, normal: [], large: [], tooLarge: [])
        for url in urls {
            switch Self.check(url, vaultRoot: root) {
            case .refused(let reason): review.refused.append((url, reason))
            case .ok(let size) where size > Self.largestSyncableFile: review.tooLarge.append((url, size))
            case .ok(let size) where size > Self.largeFileWarning: review.large.append((url, size))
            case .ok: review.normal.append(url)
            }
        }
        if review.large.isEmpty && review.tooLarge.isEmpty && review.refused.isEmpty {
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
                    do { try Self.copyContents(of: readable, to: self.url(for: path)) } catch { copyError = error }
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
        let parts = target.components(separatedBy: "#")
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        let heading = parts.dropFirst().joined(separator: "#")
        let destination: String?
        if name.isEmpty {
            destination = selection
        } else if let path = resolve(name, from: selection) {
            destination = path
        } else {
            let bare = Self.noteExtensions.contains((name as NSString).pathExtension.lowercased())
                ? (name as NSString).deletingPathExtension : name
            destination = createNote(kind: .markdown, named: (bare as NSString).lastPathComponent)
        }
        if let destination {
            selection = destination
            headingJump = heading.isEmpty ? nil : MarkdownHeadingJump(path: destination, heading: heading)
        }
    }

    public func resolve(_ target: String, from source: String? = nil) -> String? {
        lookup.resolve(target, from: source)
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
        await indexTask?.value
        let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        // Longest first, so "Jet app" wins over "Jet" when both would match.
        let names = ([title] + (index.noteAliases[path] ?? [])).sorted { $0.count > $1.count }
        let linked = Set(index.backlinks[path] ?? [])
        let candidates = allNotes.filter { $0.path != path && !linked.contains($0.path) }
        let indexedText = index.text
        return await Task.detached(priority: .utility) {
            var hits: [SearchHit] = []
            for note in candidates {
                if Task.isCancelled { return [] }
                guard let text = indexedText[note.path] else { continue }
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
        guard (source as NSString).pathExtension.lowercased() != "ink" else { return }
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
        openPeriodicNote(.daily, for: date)
    }

    enum Period: String, CaseIterable {
        case daily = "Daily", weekly = "Weekly", monthly = "Monthly"

        func title(for date: Date) -> String {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.calendar = Calendar(identifier: .iso8601)
            switch self {
            case .daily: format.dateFormat = "yyyy-MM-dd"
            case .monthly: format.dateFormat = "yyyy-MM"
            case .weekly:
                var iso = Calendar(identifier: .iso8601)
                iso.timeZone = .current
                return String(format: "%04d-W%02d", iso.component(.yearForWeekOfYear, from: date),
                              iso.component(.weekOfYear, from: date))
            }
            return format.string(from: date)
        }
    }


    func openPeriodicNote(_ period: Period, for date: Date = .now) {
        let title = period.title(for: date)
        let path = "\(period.rawValue)/\(title).md"
        if !exists(path) {
            let template = "Templates/\(period.rawValue).md"
            guard writeTemplate(exists(template) ? template : nil, to: path, title: title, date: date) else { return }
        }
        selection = path
    }

    func createFromTemplate(_ template: String, named name: String) -> Bool {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let path = uniquePath(folder: targetFolder, base: base.isEmpty ? "Untitled" : base, ext: "md")
        let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard writeTemplate(template, to: path, title: title, date: .now) else { return false }
        selection = path
        return true
    }

    func writeTemplate(_ template: String?, to path: String, title: String, date: Date) -> Bool {
        do {
            flushEditors()
            let destination = try root.vaultFile(path)
            let directory = destination.deletingLastPathComponent()
            let source = try template.map { try String(contentsOf: root.vaultFile($0), encoding: .utf8) } ?? ""
            let text = source.replacingOccurrences(of: "{{date}}", with: Period.daily.title(for: date))
                .replacingOccurrences(of: "{{weekday}}", with: date.formatted(.dateTime.weekday(.wide)))
                .replacingOccurrences(of: "{{title}}", with: title)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: destination, options: .withoutOverwriting)
            didWriteFile()
            refreshTree()
            return true
        } catch {
            fileOperationError = error.localizedDescription
            return false
        }
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
        await indexTask?.value
        let snapshot = index, notes = allNotes
        return await Task.detached(priority: .userInitiated) { snapshot.search(query, notes: notes) }.value
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
            if !report.conflicts.isEmpty {
                lastConflictPaths = Array(Set(report.conflicts)).sorted()
                defaults.set(lastConflictPaths, forKey: key("lastConflicts"))
            }
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
