import Foundation
import CryptoKit
import Darwin
import Vision

struct IndexedNote: Codable, Sendable {
    /// inode and change time catch replacements that preserve size and modification time.
    struct Signature: Codable, Equatable {
        let inode: UInt64
        let seconds: Int
        let nanoseconds: Int
        let bytes: Int64
        init?(url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            inode = info.st_ino
            seconds = info.st_ctimespec.tv_sec
            nanoseconds = info.st_ctimespec.tv_nsec
            bytes = info.st_size
        }
    }
    let signature: Signature?
    let text: String
    let targets: [Target]
    let properties: [NoteSyntax.Property]
    let tags: [String]
    var aliases: [String] {
        properties.filter { ["alias", "aliases"].contains($0.key.lowercased()) }.flatMap(\.values)
    }
    struct Target: Codable, Sendable {
        let name: String
        let relative: Bool
    }
    init(text: String, signature: Signature? = nil) {
        self.signature = signature
        self.text = text
        targets = NoteSyntax.references(in: text).map { Target(name: $0.target, relative: $0.relative) }
        properties = NoteSyntax.frontmatter(in: text).properties
        tags = NoteSyntax.tags(in: text, properties: properties)
    }
}

/// Only note files with changed fingerprints need parsing or Vision recognition. Cache files
/// live outside the vault, so git and the folder watcher never see them.
actor VaultIndexStore {
    private let files: VaultIndexFiles
    init(root: URL) { files = VaultIndexFiles(root: root) }

    func update(root: URL, paths: [String]) -> LinkIndex {
        files.update(root: root, paths: paths)
    }
}

final class VaultIndexFiles {
    private let lock = NSLock()
    private var records: [String: IndexedNote] = [:]
    private var current = LinkIndex()
    private var previousPaths: [String] = []
    private let cache: URL

    init(root: URL) {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jet/NoteIndex-v2/\(key)")
    }

    func update(root: URL, paths: [String]) -> LinkIndex {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let notes = paths.filter { VaultSession.noteExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        func file(_ path: String) -> URL {
            let digest = SHA256.hash(data: Data(path.utf8))
            return cache.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined())
        }
        let old = Set(records.keys)
        var changed = Set<String>()
        var aliasesChanged = false
        for path in notes {
            let url = root.appendingPathComponent(path)
            guard let signature = IndexedNote.Signature(url: url) else {
                if records.removeValue(forKey: path) != nil { changed.insert(path); aliasesChanged = true }
                continue
            }
            let cached = records[path] ?? (try? Data(contentsOf: file(path))).flatMap { try? PropertyListDecoder().decode(IndexedNote.self, from: $0) }
            if let cached, cached.signature == signature {
                if records[path] == nil { records[path] = cached; changed.insert(path) }
                continue
            }
            let text: String?
            if url.pathExtension.lowercased() == "ink" { text = Self.handwriting(at: url) }
            else { text = try? String(contentsOf: url, encoding: .utf8) }
            let record = text.map { IndexedNote(text: $0, signature: signature) }
            if record?.aliases != records[path]?.aliases { aliasesChanged = true }
            records[path] = record
            changed.insert(path)
            if let record, let data = try? PropertyListEncoder().encode(record) {
                try? data.write(to: file(path), options: .atomic)
            } else { try? fm.removeItem(at: file(path)) }
        }
        let removed = old.subtracting(notes)
        for path in removed { records[path] = nil; try? fm.removeItem(at: file(path)) }
        if paths != previousPaths || aliasesChanged || !removed.isEmpty {
            current = LinkIndex(records: records, paths: paths)
            previousPaths = paths
        } else if !changed.isEmpty {
            let resolver = VaultLinks(paths: paths, aliases: current.aliases)
            for path in changed {
                current.remove(path)
                if let note = records[path] { current.add(note, path: path, resolver: resolver) }
            }
        }
        return current
    }

    private static func handwriting(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), let doc = InkDocument.decode(data) else { return nil }
        let drawing = doc.pkDrawing
        let pageHeight: CGFloat = 1400
        var pages = Set<Int>()
        for stroke in drawing.strokes {
            let bounds = stroke.renderBounds
            guard !bounds.isNull, bounds.minY.isFinite, bounds.maxY.isFinite,
                  bounds.maxY >= 0, bounds.maxY < CGFloat(Int.max) else { continue }
            for page in max(0, Int(floor(bounds.minY / pageHeight)))...Int(bounds.maxY / pageHeight) { pages.insert(page) }
        }
        // Typed text is indexed exactly as written (it isn't rendered for recognition, so it isn't found twice).
        var lines: [String] = (doc.texts ?? []).sorted { ($0.y, $0.x) < ($1.y, $1.x) }.map(\.text)
        for page in pages.sorted() {
            let result: [String]? = autoreleasepool {
                let rect = CGRect(x: 0, y: CGFloat(page) * pageHeight, width: InkDocument.pageWidth, height: pageHeight)
                guard let image = InkRenderer.compose(drawing, images: [], root: url.deletingLastPathComponent(),
                    rect: rect, scale: 1.5, dark: false, background: CGColor(gray: 1, alpha: 1)) else { return nil }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return nil }
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            }
            guard let result else { return nil }
            lines += result
        }
        return lines.joined(separator: "\n")
    }
}
