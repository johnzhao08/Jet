import Foundation

enum PropertyKind: String, CaseIterable, Identifiable {
    case text, list, number, date, checkbox
    var id: Self { self }
}

enum EditableProperty {
    struct Invalid: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func kind(raw: String) -> PropertyKind {
        if raw.hasPrefix("[") || raw.isEmpty { return .list }
        if ["true", "false"].contains(raw.lowercased()) { return .checkbox }
        if Double(raw)?.isFinite == true { return .number }
        if validDate(raw) { return .date }
        return .text
    }

    static func rawValue(for key: String, in text: String) -> String {
        let count = NoteSyntax.frontmatter(in: text).lineCount
        let line = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").prefix(count)
            .first { topKey($0) == key } ?? ""
        return String(line.drop(while: { $0 != ":" }).dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    static func set(key: String, kind: PropertyKind, value: String, in text: String) throws -> String {
        guard !key.isEmpty, key == key.trimmingCharacters(in: .whitespaces),
              key.range(of: #"^[\p{L}\p{N}_][\p{L}\p{N} _-]*$"#, options: .regularExpression) != nil,
              !key.contains(where: \.isNewline)
        else { throw Invalid(reason: "Use letters, numbers, spaces, hyphens or underscores in the property name.") }
        let encoded: String
        switch kind {
        case .text:
            encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        case .list:
            let items = value.components(separatedBy: .newlines).filter { !$0.isEmpty }
            encoded = String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
        case .checkbox:
            guard ["true", "false"].contains(value.lowercased()) else { throw Invalid(reason: "Enter true or false.") }
            encoded = value.lowercased()
        case .number:
            guard value.range(of: #"^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil,
                  Double(value)?.isFinite == true else { throw Invalid(reason: "Enter a finite number.") }
            encoded = value
        case .date:
            guard validDate(value) else { throw Invalid(reason: "Enter a date as YYYY-MM-DD.") }
            encoded = value
        }
        var lines = text.components(separatedBy: "\n")
        let carriageReturn = lines.first?.hasSuffix("\r") == true ? "\r" : ""
        let count = NoteSyntax.frontmatter(in: text).lineCount
        let replacement = "\(key): \(encoded)\(carriageReturn)"
        if count == 0 {
            guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) != "---" else {
                throw Invalid(reason: "Close the existing frontmatter block first.")
            }
            lines.insert(contentsOf: ["---" + carriageReturn, replacement, "---" + carriageReturn], at: 0)
        } else {
            let matches = (1..<(count - 1)).filter { topKey(lines[$0]) == key }
            guard matches.count <= 1 else { throw Invalid(reason: "Resolve the duplicate property in source first.") }
            if let start = matches.first {
                var end = start + 1
                while end < count - 1, lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("- ") { end += 1 }
                let raw = rawValue(for: key, in: text)
                guard !["|", ">", "{", "&", "*", "!"].contains(where: { raw.hasPrefix($0) }),
                      !lines[end..<(count - 1)].prefix(while: { topKey($0) == nil }).contains(where: {
                          let s = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                          return !s.isEmpty && !s.hasPrefix("#")
                      })
                else { throw Invalid(reason: "Edit this structured YAML property in source.") }
                lines.replaceSubrange(start..<end, with: [replacement])
            } else {
                lines.insert(replacement, at: count - 1)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func topKey(_ line: String) -> String? {
        guard let first = line.first, !first.isWhitespace, first != "#", let colon = line.firstIndex(of: ":") else { return nil }
        return String(line[..<colon]).trimmingCharacters(in: .whitespaces)
    }

    private static func validDate(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: value).map { f.string(from: $0) == value } ?? false
    }
}
