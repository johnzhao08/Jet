import Foundation
import Observation

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
    /// Lowercased note title -> paths of notes that link to it.
    public private(set) var backlinks: [String: [String]] = [:]

    @ObservationIgnored private var flushHandlers: [UUID: () -> Void] = [:]
    @ObservationIgnored private var lastLocalWrite = Date.distantPast
    @ObservationIgnored private let defaults = UserDefaults.standard

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
        if let last = UserDefaults.standard.string(forKey: "vault.\(ref.id.uuidString).lastNote"), exists(last) {
            selection = last
        }
    }

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

        let root = root
        let markdown = allNotes.filter { $0.fileExtension != "ink" }.map(\.path)
        Task.detached(priority: .utility) {
            var links: [String: [String]] = [:]
            for path in markdown {
                guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { continue }
                for target in Set(Wikilink.targets(in: text)) {
                    links[target.lowercased(), default: []].append(path)
                }
            }
            let result = links
            await MainActor.run { self.backlinks = result }
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

    public func createFolder(in folder: String? = nil) {
        let path = uniquePath(folder: folder ?? targetFolder, base: "New Folder", ext: "")
        try? FileManager.default.createDirectory(at: url(for: path), withIntermediateDirectories: true)
        refreshTree()
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
        didWriteFile()
        refreshTree()
        if wasSelected { selection = newPath }
    }

    public func delete(_ path: String) {
        if let selected = selection, selected == path || selected.hasPrefix(path + "/") { selection = nil }
        try? FileManager.default.removeItem(at: url(for: path))
        didWriteFile()
        refreshTree()
    }

    // MARK: Links & search

    /// Opens the note a `[[wikilink]]` points at, creating it next to the current note if it does not exist.
    public func openLink(_ target: String) {
        let name = target.split(separator: "#").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? target
        let bare = Self.noteExtensions.contains((name as NSString).pathExtension.lowercased())
            ? (name as NSString).deletingPathExtension : name
        if let path = notesByTitle[(bare as NSString).lastPathComponent.lowercased()] {
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
            return notesByTitle[((name as NSString).deletingPathExtension).lowercased()]
        }
        return Self.flatten(tree).first { $0.fileName.lowercased() == name.lowercased() }?.path
    }

    public func search(_ query: String) async -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
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

enum Wikilink {
    /// Targets of every `[[target]]`, `[[target|alias]]` and `[[target#heading]]` in the text.
    static func targets(in text: String) -> [String] {
        text.matches(of: #/\[\[([^\]\|#]+)[^\]]*\]\]/#).map {
            let target = String($0.1).trimmingCharacters(in: .whitespaces)
            let name = (target as NSString).lastPathComponent
            return VaultSession.noteExtensions.contains((name as NSString).pathExtension.lowercased())
                ? (name as NSString).deletingPathExtension : name
        }
    }
}
