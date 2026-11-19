import Foundation

/// Resolves links against the vault tree, never against arbitrary filesystem paths.
struct VaultLinks: Sendable {
    private var lookup: [String: String] = [:]
    private var basenames: [String: String] = [:]
    var aliases: [String: String]

    init(paths: [String], aliases: [String: String] = [:]) {
        self.aliases = aliases
        for path in paths.sorted() {
            let name = path as NSString
            lookup[path.lowercased()] = path
            let keys = VaultSession.noteExtensions.contains(name.pathExtension.lowercased())
                ? [path, name.deletingPathExtension] : [path]
            for key in keys {
                if lookup[key.lowercased()] == nil { lookup[key.lowercased()] = path }
                let base = (key as NSString).lastPathComponent.lowercased()
                if basenames[base] == nil { basenames[base] = path }
            }
        }
    }

    func resolve(_ raw: String, from source: String?, relative: Bool = false) -> String? {
        let name = raw.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return source }
        if !relative, name.hasPrefix("/") { return lookup[String(name.dropFirst()).lowercased()] }
        let base = (source as NSString?)?.deletingLastPathComponent ?? ""
        let local = (base.isEmpty ? name : base + "/" + name) as NSString
        let normalized = (("/" + (local as String)) as NSString).standardizingPath
        let nearby = lookup[String(normalized.dropFirst()).lowercased()]
        if relative || name.hasPrefix("./") || name.hasPrefix("../") { return nearby }
        if name.contains("/") { return lookup[name.lowercased()] ?? nearby }
        return nearby ?? basenames[name.lowercased()] ?? aliases[name.lowercased()]
    }
}

extension NoteSyntax {
    struct Reference {
        var range: NSRange
        var target: String
        var relative: Bool
    }

    private static let referencePattern = try! NSRegularExpression(pattern:
        #"!?(?:\[\[([^\]\|#\n]*)(?:[#|][^\]\n]*)?\]\]|\[[^\]\n]*\]\((?:<([^>\n]+)>|([^\s)]+))(?:\s+["'][^\n]*?["'])?\))"#)

    static func references(in text: String) -> [Reference] {
        let source = text as NSString
        let masked = mask(text, [codePattern])
        return referencePattern.matches(in: masked, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let wiki = match.range(at: 1).location != NSNotFound
            var range = wiki ? match.range(at: 1) : match.range(at: 2)
            if range.location == NSNotFound { range = match.range(at: 3) }
            let raw = source.substring(with: range).components(separatedBy: "#")[0]
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            if !wiki && (URL(string: name)?.scheme != nil || name.hasPrefix("/") || name.hasPrefix("?")) { return nil }
            range = source.range(of: name, options: .literal, range: range)
            return Reference(range: range, target: wiki ? name : (name.removingPercentEncoding ?? name), relative: !wiki)
        }
    }
}

/// Shared by app and MCP. Resolve references against the original tree before moving anything.
public enum VaultRelocation {
    public static func move(root: URL, from old: String, to new: String) throws {
        let fm = FileManager.default
        func url(_ path: String) -> URL { root.appendingPathComponent(path) }
        func mapped(_ path: String) -> String {
            path == old || path.hasPrefix(old + "/") ? new + path.dropFirst(old.count) : path
        }
        let prefix = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        func safe(_ path: String) -> Bool {
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") } &&
                url(path).resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(prefix)
        }
        guard safe(old), safe(new), old != new, !new.hasPrefix(old + "/"), !fm.fileExists(atPath: url(new).path)
        else { throw CocoaError(.fileWriteInvalidFileName) }
        let files = VaultSession.flatten(VaultSession.scan(root: root, relative: "")).map(\.path)
        var texts: [String: String] = [:]
        var aliases: [String: String] = [:]
        for path in files.sorted() where ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()) {
            let text = try String(contentsOf: url(path), encoding: .utf8)
            texts[path] = text
            for prop in NoteSyntax.frontmatter(in: text).properties where ["alias","aliases"].contains(prop.key.lowercased()) {
                for alias in prop.values where aliases[alias.lowercased()] == nil { aliases[alias.lowercased()] = path }
            }
        }
        let before = VaultLinks(paths: files, aliases: aliases)
        let after = VaultLinks(paths: files.map(mapped), aliases: aliases.mapValues(mapped))
        var edits: [(path: String, original: String, revised: String)] = []
        for (path, original) in texts {
            let revised = NSMutableString(string: original)
            for ref in NoteSyntax.references(in: original).reversed() {
                guard let target = before.resolve(ref.target, from: path, relative: ref.relative) else { continue }
                let dest = mapped(target), source = mapped(path)
                if after.resolve(ref.target, from: source, relative: ref.relative) == dest { continue }
                var replacement = dest
                if ref.relative {
                    var from = source.split(separator: "/").dropLast()[...]
                    var to = dest.split(separator: "/")[...]
                    while let a = from.first, a == to.first { from = from.dropFirst(); to = to.dropFirst() }
                    replacement = (Array(repeating: "..", count: from.count) + to.map(String.init)).joined(separator: "/")
                    replacement = replacement.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~/"))) ?? replacement
                } else {
                    if VaultSession.noteExtensions.contains((dest as NSString).pathExtension.lowercased()),
                       (ref.target as NSString).pathExtension.lowercased() != (target as NSString).pathExtension.lowercased() {
                        replacement = (dest as NSString).deletingPathExtension
                    }
                    let name = (replacement as NSString).lastPathComponent
                    if !ref.target.contains("/"), after.resolve(name, from: source) == dest { replacement = name }
                    if after.resolve(replacement, from: source) != dest { replacement = "/" + dest }
                }
                revised.replaceCharacters(in: ref.range, with: replacement)
            }
            if original != revised as String { edits.append((path, original, revised as String)) }
        }
        let sidecar = VaultSession.annotationsPath(for: old)
        let newSidecar = VaultSession.annotationsPath(for: new)
        let hasSidecar = fm.fileExists(atPath: url(sidecar).path)
        if hasSidecar && fm.fileExists(atPath: url(newSidecar).path) { throw CocoaError(.fileWriteFileExists) }
        var applied = 0, moved = false
        do {
            for edit in edits {
                guard try String(contentsOf: url(edit.path), encoding: .utf8) == edit.original else { throw CocoaError(.fileWriteFileExists) }
                try edit.revised.write(to: url(edit.path), atomically: true, encoding: .utf8)
                applied += 1
            }
            try fm.moveItem(at: url(old), to: url(new))
            moved = true
            if hasSidecar { try fm.moveItem(at: url(sidecar), to: url(newSidecar)) }
        } catch {
            if moved { try fm.moveItem(at: url(new), to: url(old)) }
            for edit in edits.prefix(applied).reversed() {
                if try String(contentsOf: url(edit.path), encoding: .utf8) == edit.revised {
                    try edit.original.write(to: url(edit.path), atomically: true, encoding: .utf8)
                }
            }
            throw error
        }
    }
}
