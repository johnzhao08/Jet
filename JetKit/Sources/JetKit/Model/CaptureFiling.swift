import Foundation
import CryptoKit
import JetCapture
import UniformTypeIdentifiers

/// What filing one capture has written into the vault, kept beside the capture in the inbox so an
/// interrupted attempt can be undone (and a finished one never repeated) after a relaunch.
struct CaptureJournal: Codable {
    /// The vault this attempt wrote into. A journal is only ever undone in that vault: an untargeted
    /// capture can be retried in another vault, where the same paths mean different files.
    var vault: UUID?
    /// Files this attempt created, each recorded the moment it was made (by identity) and again when
    /// its bytes were complete, so a later undo can tell them from anything else at the same path.
    var created: [Created] = []
    /// Text appended to a daily note, with the note's size before, to take it back exactly.
    var appended: Appended?
    /// Set once everything is written; the capture is then only waiting to be removed from the inbox.
    var result: String?

    struct Created: Codable {
        var path: String
        /// Which file we made: its device and inode, taken from the descriptor we created it with.
        var device: UInt64?
        var inode: UInt64?
        /// Size and SHA-256 of the finished file. Nil while it was still being written.
        var size: Int?
        var sha256: String?
    }

    struct Appended: Codable {
        var path: String
        var text: String
        var sizeBefore: Int
    }

    /// What a regular file on disk looks like: enough to tell our own, untouched file from a replaced
    /// or edited one.
    struct Fingerprint: Equatable {
        var device: UInt64
        var inode: UInt64
        var size: Int
        var sha256: String

        /// Nil unless `url` is a regular file (not a symlink or folder) that can be read.
        static func of(_ url: URL) -> Fingerprint? {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            var total = 0
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n < 0 { if errno == EINTR { continue }; return nil }
                if n == 0 { break }
                hasher.update(data: buffer[0..<n])
                total += n
            }
            return Fingerprint(device: UInt64(truncatingIfNeeded: st.st_dev), inode: UInt64(truncatingIfNeeded: st.st_ino),
                               size: total, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }

    /// True only if the file at `url` is the very file this entry recorded and still holds the bytes we
    /// wrote. A file that was replaced, edited, turned into a link, or never confirmed as ours is not.
    func owns(_ entry: Created, at url: URL) -> Bool {
        guard let device = entry.device, let inode = entry.inode else { return false }
        guard let now = Fingerprint.of(url), now.device == device, now.inode == inode else { return false }
        guard let sha = entry.sha256, let size = entry.size else { return now.size == 0 }  // cut off before any bytes landed
        return now.size == size && now.sha256 == sha
    }

    static func load(_ url: URL?) -> CaptureJournal {
        guard let url, let data = try? Data(contentsOf: url) else { return CaptureJournal() }
        return (try? JSONDecoder().decode(CaptureJournal.self, from: data)) ?? CaptureJournal()
    }

    /// Without a journal file (quick capture) there is nothing to persist, which is fine: a failure is
    /// rolled back at once, and nothing is left queued to repeat.
    func save(to url: URL?) -> Bool {
        guard let url else { return true }
        guard let data = try? JSONEncoder().encode(self) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

/// Appends to a file we just created exclusively, keeping a running size and checksum of what went in.
final class CaptureFileWriter {
    let fd: Int32
    private var hasher = SHA256()
    private(set) var size = 0

    init(fd: Int32) { self.fd = fd }

    func write(_ data: Data) throws {
        hasher.update(data: data)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                offset += n
            }
        }
        size += data.count
    }

    var sha256: String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}

/// Writes captures (from the share sheet, Shortcuts, quick capture) into a vault.
///
/// This is the only place captures touch a vault, and it runs in the app: extensions only leave
/// items in the shared inbox. A capture is all or nothing: if any part can't be written, everything
/// written for it is taken back and the capture stays queued to try again. Nothing is overwritten,
/// every destination goes through `vaultFile` (no symlinks, no hidden folders), and what's open is left
/// alone, apart from flushing and reloading editors when a daily note grows.
/// Captures that failed this launch: each is retried once per launch (not on every foreground), so
/// repeated activations don't use up its attempts before a temporary problem has had a chance to clear.
@MainActor
enum CaptureAttempts {
    static var failedThisLaunch = Set<UUID>()
    /// Test seam: called with the vault path a capture file is about to be created at, so a test can
    /// make something appear there first.
    static var beforeCreate: ((String) -> Void)?
}

extension VaultSession {
    public nonisolated static let inboxFolder = "Inbox"

    /// Files every waiting capture meant for this vault (or for no vault in particular). Returns how
    /// many were filed. A capture that can't be written stays in the inbox for the next try, and is
    /// set aside after repeated failures.
    @discardableResult
    public func fileCaptures(from inbox: CaptureInbox) -> Int {
        inbox.removeStaleScratch()
        let filed = inbox.filedIDs()
        var count = 0
        for pending in inbox.pending() {
            let item = pending.item
            guard item.vaultID == nil || item.vaultID == ref.id else { continue }
            if filed.contains(item.id) { inbox.discard(item.id); continue }
            if CaptureAttempts.failedThisLaunch.contains(item.id) { continue }
            guard apply(item, attachments: { pending.attachmentURL($0) }, journal: pending.journalURL) != nil else {
                CaptureAttempts.failedThisLaunch.insert(item.id)
                inbox.recordFailure(item.id)
                continue
            }
            inbox.finish(item.id)
            count += 1
        }
        return count
    }

    /// Writes one capture into the vault and returns the path of the note it made or added to, or nil
    /// if any part failed (in which case nothing of it is left in the vault). Calling it again for a
    /// capture that was interrupted undoes the partial attempt first (only files it can prove are its own
    /// and untouched, and only in the vault it wrote to), and for one that finished just returns its
    /// note, so a relaunch never files anything twice.
    ///
    /// `journal` is where progress is recorded; pass the capture's `journalURL` when it's queued.
    @discardableResult
    public func apply(_ item: CaptureItem, attachments urlFor: (String) -> URL? = { _ in nil }, journal journalURL: URL? = nil) -> String? {
        var journal = CaptureJournal.load(journalURL)
        if let result = journal.result { return result }
        // An earlier attempt in this vault was cut short: take back whatever it wrote before starting
        // over. One cut short in another vault is left alone: those paths mean other files here.
        if journal.vault == ref.id { rollBack(journal) }
        journal = CaptureJournal(vault: ref.id)
        flushEditors()

        func fail() -> String? {
            rollBack(journal)
            if let journalURL { try? FileManager.default.removeItem(at: journalURL) }
            refreshTree()
            return nil
        }

        var embeds: [(name: String, isImage: Bool)] = []
        for name in item.attachments {
            guard let source = urlFor(name), let saved = storeAttachment(source, named: name, journal: &journal, at: journalURL) else {
                return fail()
            }
            embeds.append(saved)
        }

        let title = CaptureNaming.fileName(item.title) ?? CaptureNaming.fallbackTitle(for: item)
        let path: String?
        switch item.destination {
        case .inbox:
            path = writeNewNote(Self.captureNote(item, embeds: embeds), folder: Self.inboxFolder, title: title,
                                journal: &journal, at: journalURL)
        case .dailyNote:
            path = appendToDailyNote(Self.dailyEntry(item, title: title, embeds: embeds), date: item.created,
                                     journal: &journal, at: journalURL)
        }
        guard let path else { return fail() }

        journal.result = path
        guard journal.save(to: journalURL) else { return fail() }
        didWriteFile()
        refreshTree()
        return path
    }

    // MARK: Writing

    /// Takes back what a journal says was written: files it created (only if each is still the same
    /// file with the same bytes) and text it appended (only if the note is exactly as that append left
    /// it). Anything else at those paths belongs to someone else and stays.
    private func rollBack(_ journal: CaptureJournal) {
        for entry in journal.created.reversed() {
            guard let file = try? root.vaultFile(entry.path), journal.owns(entry, at: file) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
        if let appended = journal.appended, let file = try? root.vaultFile(appended.path),
           let data = try? Data(contentsOf: file), data.count == appended.sizeBefore + appended.text.utf8.count,
           data.suffix(appended.text.utf8.count) == Data(appended.text.utf8) {
            try? data.prefix(appended.sizeBefore).write(to: file, options: .atomic)
            contentVersion += 1
        }
    }

    private enum Creation { case made, taken, failed }

    /// Creates the file at `path`, which must not exist, and fills it. Never touches anything already
    /// there: if the path is taken (even by something that appeared after it was chosen) nothing is
    /// changed and `.taken` says to pick another name. The new file is recorded in the journal by
    /// identity as soon as it exists, and with its checksum once it's complete; if anything goes wrong
    /// the half-made file is removed (it's ours by construction) and its record dropped.
    private func createFile(_ path: String, journal: inout CaptureJournal, at journalURL: URL?,
                            fill: (CaptureFileWriter) throws -> Void) -> Creation {
        guard let file = try? root.vaultFile(path) else { return .failed }
        do { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { return .failed }
        CaptureAttempts.beforeCreate?(path)

        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return errno == EEXIST ? .taken : .failed }
        defer { close(fd) }
        var st = stat()
        let identity: (UInt64, UInt64)? = fstat(fd, &st) == 0
            ? (UInt64(truncatingIfNeeded: st.st_dev), UInt64(truncatingIfNeeded: st.st_ino)) : nil

        /// Removes what we made, but only if the path still names it.
        func abandon() -> Creation {
            var now = stat()
            if let identity, lstat(file.path, &now) == 0,
               UInt64(truncatingIfNeeded: now.st_dev) == identity.0, UInt64(truncatingIfNeeded: now.st_ino) == identity.1 {
                unlink(file.path)
            }
            if journal.created.last?.path == path { journal.created.removeLast(); _ = journal.save(to: journalURL) }
            return .failed
        }

        guard let identity else { return abandon() }
        journal.created.append(.init(path: path, device: identity.0, inode: identity.1, size: nil, sha256: nil))
        guard journal.save(to: journalURL) else { return abandon() }

        let writer = CaptureFileWriter(fd: fd)
        do { try fill(writer) } catch { return abandon() }
        guard fsync(fd) == 0 else { return abandon() }
        journal.created[journal.created.count - 1].size = writer.size
        journal.created[journal.created.count - 1].sha256 = writer.sha256
        guard journal.save(to: journalURL) else { return abandon() }
        return .made
    }

    /// `createFile` at a free name, trying the next name if something takes it first.
    private func createAtFreePath(folder: String, base: String, ext: String, journal: inout CaptureJournal, at journalURL: URL?,
                                  fill: (CaptureFileWriter) throws -> Void) -> String? {
        var last: String?
        for _ in 0..<20 {
            let path = uniquePath(folder: folder, base: base, ext: ext)
            if path == last { return nil }  // the name is "free" yet can't be made: don't spin
            last = path
            switch createFile(path, journal: &journal, at: journalURL, fill: fill) {
            case .made: return path
            case .failed: return nil
            case .taken: continue
            }
        }
        return nil
    }

    private func writeNewNote(_ text: String, folder: String, title: String, journal: inout CaptureJournal, at journalURL: URL?) -> String? {
        createAtFreePath(folder: folder, base: title, ext: "md", journal: &journal, at: journalURL) { try $0.write(Data(text.utf8)) }
    }

    /// Adds `entry` to the end of the daily note for `date`, making the note first (from its template)
    /// if needed. Editors are flushed first so unsaved typing in that note isn't overwritten, then told
    /// to reload.
    private func appendToDailyNote(_ entry: String, date: Date, journal: inout CaptureJournal, at journalURL: URL?) -> String? {
        let name = Period.daily.title(for: date)
        let path = "\(Self.dailyFolder)/\(name).md"
        guard let file = try? root.vaultFile(path) else { return nil }
        if !exists(path) {
            // The new note is just today's note as Jet would make it, so it stays even if the append fails.
            guard writeTemplate(exists(Self.dailyTemplate) ? Self.dailyTemplate : nil, to: path, title: name, date: date) else { return nil }
        }
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { return nil }  // never replace what we can't read
        let added = (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + entry
        journal.appended = .init(path: path, text: added, sizeBefore: data.count)
        guard journal.save(to: journalURL) else { return nil }
        do { try Data((text + added).utf8).write(to: file, options: .atomic) } catch { return nil }
        contentVersion += 1
        return path
    }

    /// Copies an inbox file into `Attachments/` under a free name. Pictures go through the same
    /// preparation as any picture added in Jet (big photos shrink, HEIC becomes JPEG).
    private func storeAttachment(_ source: URL, named name: String, journal: inout CaptureJournal, at journalURL: URL?) -> (name: String, isImage: Bool)? {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
        guard size <= CaptureLimits.largestAttachment else { return nil }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.lowercased()
        let base = stem.isEmpty ? "File" : stem

        if ImageFiles.extensions.contains(ext), let data = try? Data(contentsOf: source),
           let prepared = ImageFiles.prepareForVault(data, type: UTType(filenameExtension: ext)) {
            guard let path = createAtFreePath(folder: Self.attachmentsFolder, base: base, ext: prepared.ext, journal: &journal, at: journalURL,
                                              fill: { try $0.write(prepared.data) }) else { return nil }
            return ((path as NSString).lastPathComponent, true)
        }
        guard let path = createAtFreePath(folder: Self.attachmentsFolder, base: base, ext: ext, journal: &journal, at: journalURL,
                                          fill: { try Self.stream(source, into: $0) }) else { return nil }
        return ((path as NSString).lastPathComponent, false)
    }

    /// Copies a plain file's bytes (not a link, not a folder) into a writer.
    private nonisolated static func stream(_ source: URL, into writer: CaptureFileWriter) throws {
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw CocoaError(.fileReadInvalidFileName) }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if n == 0 { return }
            try writer.write(Data(buffer[0..<n]))
            if writer.size > CaptureLimits.largestAttachment { throw CocoaError(.fileReadTooLarge) }
        }
    }

    // MARK: Text

    private nonisolated static func quoted(_ value: String) -> String {
        // JSON strings are valid YAML, and Jet's property reader decodes them.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private nonisolated static func embedLine(_ embed: (name: String, isImage: Bool)) -> String {
        embed.isImage ? "![[\(embed.name)]]" : "[[\(embed.name)]]"
    }

    /// The Markdown for a capture filed as its own note.
    nonisolated static func captureNote(_ item: CaptureItem, embeds: [(name: String, isImage: Bool)]) -> String {
        var properties = ["captured: \(quoted(item.created.formatted(.iso8601)))"]
        if let link = item.link, !link.isEmpty { properties.insert("source: \(quoted(link))", at: 0) }
        var parts = ["---\n" + properties.joined(separator: "\n") + "\n---"]
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && text != item.link { parts.append(text) }
        if let link = item.link, !link.isEmpty { parts.append("<\(link)>") }
        if !embeds.isEmpty { parts.append(embeds.map(embedLine).joined(separator: "\n")) }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// The Markdown appended to a daily note for a capture: a one-line bullet for plain text, a small
    /// block when there's more.
    nonisolated static func dailyEntry(_ item: CaptureItem, title: String, embeds: [(name: String, isImage: Bool)]) -> String {
        let time = item.created.formatted(.dateTime.hour().minute())
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        if let link = item.link, !link.isEmpty { lines.append("<\(link)>") }
        if !text.isEmpty && text != item.link { lines.append(text) }
        if !embeds.isEmpty { lines.append(embeds.map(embedLine).joined(separator: "\n")) }

        let simple = embeds.isEmpty && heading.isEmpty && item.link == nil && !text.contains("\n")
        if simple { return "\n- \(time) \(text)\n" }
        let first = heading.isEmpty ? "" : " " + heading
        return "\n**\(time)**\(first)\n\n" + lines.joined(separator: "\n\n") + "\n"
    }
}
