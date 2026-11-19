import Foundation

extension LinkIndex {
    private static let tokens = try! NSRegularExpression(pattern:
        #"\[[^\]\n]*\]|(?:[\w-]+:)?"[^"]*"|/(?:\\.|[^/\\])+/|\S+"#)

    func search(_ query: String, notes: [FileNode]) -> [SearchHit] {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        guard raw.length > 0 else { return [] }
        let tokens = Self.tokens.matches(in: raw as String, range: NSRange(location: 0, length: raw.length))
            .map { raw.substring(with: $0.range) }
        enum Term {
            case text(String), path(String), tag(String), property(String, String), todo(String), regex(NSRegularExpression)
        }
        func value(_ token: String) -> String {
            token.hasPrefix("\"") && token.hasSuffix("\"") ? String(token.dropFirst().dropLast()) : token
        }
        var terms: [Term] = []
        for token in tokens {
            if token.hasPrefix("path:") { terms.append(.path(value(String(token.dropFirst(5))))) }
            else if token.hasPrefix("tag:") || token.hasPrefix("#") {
                let tag = token.hasPrefix("#") ? String(token.dropFirst()) : value(String(token.dropFirst(4)))
                terms.append(.tag(tag.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()))
            } else if token.hasPrefix("["), token.hasSuffix("]"), let colon = token.firstIndex(of: ":") {
                terms.append(.property(String(token[token.index(after: token.startIndex)..<colon]).lowercased(),
                                       value(String(token[token.index(after: colon)..<token.index(before: token.endIndex)]))))
            } else if token.hasPrefix("task-todo:") { terms.append(.todo(value(String(token.dropFirst(10))))) }
            else if token.hasPrefix("/"), token.hasSuffix("/"), token.count > 1 {
                guard let regex = try? NSRegularExpression(pattern: String(token.dropFirst().dropLast()), options: [.caseInsensitive]) else { return [] }
                terms.append(.regex(regex))
            } else { terms.append(.text(value(token))) }
        }
        func contains(_ text: String, _ term: String) -> Bool { term.isEmpty || text.localizedStandardContains(term) }
        return notes.compactMap { note in
            let body = text[note.path] ?? ""
            var snippet = ""
            for term in terms {
                switch term {
                case .text(let s):
                    if let range = body.range(of: s, options: [.diacriticInsensitive, .caseInsensitive]) {
                        if snippet.isEmpty { snippet = String(body[body.lineRange(for: range)]) }
                    } else if !contains(note.title, s) { return nil }
                case .regex(let regex):
                    let ns = body as NSString
                    if let match = regex.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) {
                        if snippet.isEmpty { snippet = ns.substring(with: ns.lineRange(for: match.range)) }
                    } else if regex.firstMatch(in: note.title, range: NSRange(note.title.startIndex..., in: note.title)) == nil { return nil }
                case .path(let s):
                    guard contains(note.path, s) else { return nil }
                case .tag(let tag):
                    let tags = noteTags[note.path] ?? []
                    guard !tag.isEmpty, tags.contains(where: { $0.lowercased() == tag || $0.lowercased().hasPrefix(tag + "/") }) else { return nil }
                    if snippet.isEmpty { snippet = tags.map { "#" + $0 }.joined(separator: " ") }
                case let .property(key, s):
                    guard (noteProperties[note.path] ?? []).contains(where: { $0.key.lowercased() == key &&
                        (s.isEmpty || $0.values.contains { $0.caseInsensitiveCompare(s) == .orderedSame }) }) else { return nil }
                case .todo(let s):
                    guard let line = body.components(separatedBy: .newlines).first(where: {
                        let line = $0.trimmingCharacters(in: .whitespaces)
                        return ["- [ ]", "* [ ]", "+ [ ]"].contains { line.hasPrefix($0) } && contains(line, s)
                    }) else { return nil }
                    if snippet.isEmpty { snippet = line }
                }
            }
            return SearchHit(path: note.path, snippet: snippet.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
