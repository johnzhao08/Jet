import Foundation

/// Obsidian-compatible Markdown syntax: `[[wikilinks]]`, `#tags`, and YAML frontmatter properties.
public enum NoteSyntax {
    /// A frontmatter property: `key: value`, `key: [a, b]`, or `key:` followed by `- item` lines.
    public struct Property: Hashable, Sendable {
        public let key: String
        public let values: [String]
    }

    /// Properties from a leading `---` block, and how many source lines that block takes (0 if none).
    public static func frontmatter(in text: String) -> (properties: [Property], lineCount: Int) {
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.indices.dropFirst().first(where: {
                  let line = lines[$0].trimmingCharacters(in: .whitespaces)
                  return line == "---" || line == "..."
              })
        else { return ([], 0) }

        var properties: [Property] = []
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- "), let last = properties.popLast() {
                properties.append(Property(key: last.key, values: last.values + [unquote(String(trimmed.dropFirst(2)))]))
            } else if let colon = trimmed.firstIndex(of: ":"), !trimmed.hasPrefix("#") {
                let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                let raw = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                var values: [String]
                if raw.hasPrefix("["), raw.hasSuffix("]") {
                    values = raw.dropFirst().dropLast().split(separator: ",").map { unquote(String($0)) }
                } else if raw.isEmpty {
                    values = []
                } else {
                    values = [unquote(raw)]
                }
                values.removeAll { $0.isEmpty }
                properties.append(Property(key: key, values: values))
            }
        }
        return (properties, end + 1)
    }

    private static func unquote(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Link targets as note titles: `[[Folder/Note.md#Heading|label]]` → `Note`.
    public static func linkTargets(in text: String) -> [String] {
        text.matches(of: #/\[\[([^\]\|#]+)[^\]]*\]\]/#).map {
            let target = String($0.1).trimmingCharacters(in: .whitespaces)
            let name = (target as NSString).lastPathComponent
            return VaultSession.noteExtensions.contains((name as NSString).pathExtension.lowercased())
                ? (name as NSString).deletingPathExtension : name
        }
    }

    /// `#tag` and `#nested/tag` in the text (without the `#`), skipping code and pure numbers like `#1`.
    public static func inlineTags(in text: String) -> [String] {
        let masked = maskedBody(text, [codePattern, wikilinkPattern, markdownLinkPattern]) as NSString
        return tagRegex.matches(in: masked as String, range: NSRange(location: 0, length: masked.length)).compactMap {
            let tag = masked.substring(with: $0.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: "/-"))
            return isTag(tag) ? tag : nil
        }
    }

    /// Tags from the `tags`/`tag` property plus every inline `#tag`, de-duplicated case-insensitively.
    public static func tags(in text: String, properties: [Property]) -> [String] {
        let declared = properties.filter { ["tags", "tag"].contains($0.key.lowercased()) }
            .flatMap(\.values)
            .flatMap { $0.split(whereSeparator: { $0 == "," || $0 == " " }) }
            .map { String($0.drop { $0 == "#" }) }
        var seen = Set<String>()
        return (declared + inlineTags(in: text)).filter { isTag($0) && seen.insert($0.lowercased()).inserted }
    }

    static func isTag(_ tag: String) -> Bool {
        !tag.isEmpty && tag.contains { !$0.isNumber && $0 != "/" && $0 != "-" && $0 != "_" }
    }

    // A tag starts after whitespace or at the start of a line.
    static let tagRegex = try! NSRegularExpression(pattern: #"(^|\s)#([\p{L}\p{N}_/-]+)"#, options: [.anchorsMatchLines])
    static let codePattern = try! NSRegularExpression(pattern: #"```[\s\S]*?(```|\z)|`[^`\n]*`"#)
    static let wikilinkPattern = try! NSRegularExpression(pattern: #"!?\[\[[^\]]*\]\]"#)

    /// The text with every match of the patterns blanked out, keeping offsets intact.
    static func mask(_ text: String, _ patterns: [NSRegularExpression]) -> String {
        let masked = NSMutableString(string: text)
        for pattern in patterns {
            for match in pattern.matches(in: masked as String, range: NSRange(location: 0, length: masked.length)) {
                masked.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
            }
        }
        return masked as String
    }

    /// `mask`, plus the frontmatter block blanked out.
    static func maskedBody(_ text: String, _ patterns: [NSRegularExpression]) -> String {
        let masked = mask(text, patterns)
        let lines = frontmatter(in: text).lineCount
        guard lines > 0 else { return masked }
        let header = text.components(separatedBy: "\n").prefix(lines).joined(separator: "\n") as NSString
        return String(repeating: " ", count: header.length) + (masked as NSString).substring(from: header.length)
    }

    /// Where `title` appears as plain text: not inside a link, code, or the frontmatter, and as a whole word.
    public static func unlinkedMentionRanges(of title: String, in text: String) -> [NSRange] {
        guard title.count >= 3 else { return [] }
        let masked = maskedBody(text, [codePattern, wikilinkPattern, markdownLinkPattern])
        let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: title) + #"(?![\p{L}\p{N}_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: masked, range: NSRange(location: 0, length: (masked as NSString).length)).map(\.range)
    }

    static let markdownLinkPattern = try! NSRegularExpression(pattern: #"\[[^\]]*\]\([^)]*\)|https?://\S+"#)

    /// Turns the first unlinked mention of `title` into a `[[wikilink]]`, keeping the text as written.
    public static func linkingFirstMention(of title: String, in text: String) -> String? {
        guard let range = unlinkedMentionRanges(of: title, in: text).first else { return nil }
        let original = (text as NSString).substring(with: range)
        return (text as NSString).replacingCharacters(in: range, with: "[[\(original)]]")
    }
}

/// What the vault's Markdown notes say about each other: links, tags and aliases, keyed by path.
public struct LinkIndex: Sendable {
    /// Note path -> paths of the notes it links to (existing notes only).
    public var outgoing: [String: [String]] = [:]
    /// Note path -> paths of the notes that link to it.
    public var backlinks: [String: [String]] = [:]
    /// Lowercased tag -> paths of notes with that tag.
    public var tags: [String: [String]] = [:]
    /// Lowercased tag -> the tag as first written.
    public var tagNames: [String: String] = [:]
    /// Note path -> its tags.
    public var noteTags: [String: [String]] = [:]
    /// Lowercased alias (from the `aliases` property) -> note path.
    public var aliases: [String: String] = [:]
    /// Note path -> its aliases.
    public var noteAliases: [String: [String]] = [:]

    public init() {}

    /// Reads every Markdown note under `root`. `titles` maps lowercased note titles to paths.
    public static func build(root: URL, markdown: [String], titles: [String: String]) -> LinkIndex {
        var index = LinkIndex()
        var rawLinks: [String: [String]] = [:]
        for path in markdown {
            guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { continue }
            let properties = NoteSyntax.frontmatter(in: text).properties
            rawLinks[path] = NoteSyntax.linkTargets(in: text)
                + properties.flatMap(\.values).flatMap(NoteSyntax.linkTargets(in:))

            let tags = NoteSyntax.tags(in: text, properties: properties)
            index.noteTags[path] = tags
            for tag in tags {
                index.tags[tag.lowercased(), default: []].append(path)
                if index.tagNames[tag.lowercased()] == nil { index.tagNames[tag.lowercased()] = tag }
            }

            let aliases = properties.filter { ["aliases", "alias"].contains($0.key.lowercased()) }.flatMap(\.values)
            index.noteAliases[path] = aliases
            for alias in aliases where titles[alias.lowercased()] == nil && index.aliases[alias.lowercased()] == nil {
                index.aliases[alias.lowercased()] = path
            }
        }

        for (source, targets) in rawLinks {
            var seen = Set<String>()
            for target in targets {
                guard let path = titles[target.lowercased()] ?? index.aliases[target.lowercased()],
                      path != source, seen.insert(path).inserted
                else { continue }
                index.outgoing[source, default: []].append(path)
                index.backlinks[path, default: []].append(source)
            }
        }
        return index
    }
}
