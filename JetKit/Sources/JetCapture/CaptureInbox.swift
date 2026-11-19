import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The shared inbox in the App Group container. Extensions add items; the app files them into a
/// vault and removes them.
///
///     <container>/Jet/Captures/<uuid>/item.json      one folder per capture, plus its files
///     <container>/Jet/Captures/.tmp-<uuid>/          being written; never read by the app
///     <container>/Jet/Captures/.processed.json       ids already filed (guards against double filing)
///
/// An item appears all at once (its folder is renamed into place when complete), so the app never
/// reads half a capture.
public struct CaptureInbox: Sendable {
    public static let groupIdentifier = "group.com.johnzhao.jet"

    public struct Pending: Sendable {
        public let item: CaptureItem
        public let folder: URL
        /// Where the app records what it has written to the vault for this capture (see `VaultSession.apply`).
        public var journalURL: URL { folder.appendingPathComponent(".journal.json") }

        /// The stored file for `name`, or nil if the name isn't a plain file name or the file is gone.
        public func attachmentURL(_ name: String) -> URL? {
            guard CaptureNaming.isPlainFileName(name) else { return nil }
            let url = folder.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    public enum Failure: LocalizedError {
        case unavailable
        case nothingToSave
        case tooManyFiles
        case fileTooLarge(String)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable: "Jet's shared storage isn't available. Open Jet once, then try again."
            case .nothingToSave: "There's nothing to save."
            case .tooManyFiles: "That's too many files at once (the limit is \(CaptureLimits.mostAttachments))."
            case .fileTooLarge(let name): "“\(name)” is over 100 MB, which a synced vault can't hold."
            case .unreadable(let name): "Couldn't read “\(name)”."
            }
        }
    }

    /// The shared folder every capture file lives under (`<container>/Jet`).
    public let base: URL
    public var captures: URL { base.appendingPathComponent("Captures", isDirectory: true) }

    public init(base: URL) { self.base = base }

    /// The inbox in the App Group container, or nil when the app isn't entitled to it (a build
    /// without the App Group, or macOS).
    public static var shared: CaptureInbox? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else { return nil }
        return CaptureInbox(base: container.appendingPathComponent("Jet", isDirectory: true))
    }

    // MARK: Adding

    /// Copies `files` and `item` into the inbox as one capture. Files are copied (never moved, never
    /// read into memory), checked for size, and renamed to safe unique names; `item.attachments` is
    /// replaced with the stored names. Throws without leaving anything behind.
    @discardableResult
    public func enqueue(_ item: CaptureItem, files: [URL] = []) throws -> CaptureItem {
        var item = item
        item.text = String(item.text.prefix(CaptureLimits.longestText))
        item.attachments = []
        guard !item.isEmpty || !files.isEmpty else { throw Failure.nothingToSave }
        guard files.count <= CaptureLimits.mostAttachments else { throw Failure.tooManyFiles }

        let fm = FileManager.default
        try fm.createDirectory(at: captures, withIntermediateDirectories: true)
        let staging = captures.appendingPathComponent(".tmp-\(item.id.uuidString)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            var used = Set<String>()
            for source in files {
                let size = (try? source.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]))
                guard let size, size.isDirectory != true, size.isSymbolicLink != true else {
                    throw Failure.unreadable(source.lastPathComponent)
                }
                if (size.fileSize ?? 0) > CaptureLimits.largestAttachment { throw Failure.fileTooLarge(source.lastPathComponent) }
                let name = Self.uniqueName(for: source.lastPathComponent, used: &used)
                do { try fm.copyItem(at: source, to: staging.appendingPathComponent(name)) }
                catch { throw Failure.unreadable(source.lastPathComponent) }
                item.attachments.append(name)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(item).write(to: staging.appendingPathComponent("item.json"), options: .atomic)
            try fm.moveItem(at: staging, to: captures.appendingPathComponent(item.id.uuidString, isDirectory: true))
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        Self.reloadWidgets()
        return item
    }

    static func uniqueName(for original: String, used: inout Set<String>) -> String {
        let ext = (original as NSString).pathExtension
        let stem = CaptureNaming.fileName((original as NSString).deletingPathExtension, limit: 60) ?? "File"
        let cleanExt = CaptureNaming.fileName(ext, limit: 10) ?? ""
        var candidate = cleanExt.isEmpty ? stem : "\(stem).\(cleanExt)"
        var counter = 2
        while used.contains(candidate.lowercased()) {
            candidate = cleanExt.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(cleanExt)"
            counter += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    // MARK: Reading

    /// Complete captures, oldest first. Folders that are still being written, or that don't hold a
    /// readable `item.json`, are skipped.
    public func pending() -> [Pending] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: captures.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var found: [Pending] = []
        for name in names where !name.hasPrefix(".") {
            let folder = captures.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("item.json")),
                  let item = try? decoder.decode(CaptureItem.self, from: data),
                  item.id.uuidString == name else { continue }
            // Attachments are not filtered here: a missing file must fail the capture (it stays queued)
            // rather than be quietly left out of the note.
            found.append(Pending(item: item, folder: folder))
        }
        return found.sorted { ($0.item.created, $0.item.id.uuidString) < ($1.item.created, $1.item.id.uuidString) }
    }

    public var pendingCount: Int { pending().count }

    // MARK: Filing

    private var ledgerURL: URL { captures.appendingPathComponent(".processed.json") }

    /// Ids already filed into a vault. A capture whose id is here is deleted instead of filed again,
    /// which covers the app being killed between writing the note and deleting the capture.
    public func filedIDs() -> Set<UUID> {
        guard let data = try? Data(contentsOf: ledgerURL), let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(ids)
    }

    /// Records `id` as filed, then removes the capture's folder.
    public func finish(_ id: UUID) {
        var ids = (try? JSONDecoder().decode([UUID].self, from: Data(contentsOf: ledgerURL))) ?? []
        if !ids.contains(id) { ids.append(id) }
        if let data = try? JSONEncoder().encode(Array(ids.suffix(500))) { try? data.write(to: ledgerURL, options: .atomic) }
        discard(id)
    }

    /// Removes a capture without recording it as filed.
    public func discard(_ id: UUID) {
        try? FileManager.default.removeItem(at: captures.appendingPathComponent(id.uuidString, isDirectory: true))
        Self.reloadWidgets()
    }

    private var failuresURL: URL { captures.appendingPathComponent(".failures.json") }
    /// How many filing attempts may fail before a capture is set aside.
    public static let attemptsBeforeQuarantine = 5

    /// Counts a failed filing attempt. After `attemptsBeforeQuarantine` the capture is moved to
    /// `.failed/` (kept, not deleted) so one bad capture doesn't retry forever. Returns true if it was set aside.
    @discardableResult
    public func recordFailure(_ id: UUID) -> Bool {
        var counts = (try? JSONDecoder().decode([String: Int].self, from: Data(contentsOf: failuresURL))) ?? [:]
        counts[id.uuidString, default: 0] += 1
        let quarantine = counts[id.uuidString, default: 0] >= Self.attemptsBeforeQuarantine
        if quarantine { counts[id.uuidString] = nil }
        if let data = try? JSONEncoder().encode(counts) { try? data.write(to: failuresURL, options: .atomic) }
        guard quarantine else { return false }
        let fm = FileManager.default
        let failed = captures.appendingPathComponent(".failed", isDirectory: true)
        try? fm.createDirectory(at: failed, withIntermediateDirectories: true)
        let target = failed.appendingPathComponent(id.uuidString, isDirectory: true)
        try? fm.removeItem(at: target)
        try? fm.moveItem(at: captures.appendingPathComponent(id.uuidString, isDirectory: true), to: target)
        Self.reloadWidgets()
        return true
    }

    /// Deletes scratch folders left by an extension that was killed mid-copy.
    public func removeStaleScratch(now: Date = Date()) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: captures.path)) ?? [] where name.hasPrefix(".tmp-") {
            let url = captures.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > CaptureLimits.staleScratch { try? fm.removeItem(at: url) }
        }
    }

    public static func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
