import Foundation

struct MarkdownHeading: Identifiable, Equatable {
    let level: Int
    let title: String
    let range: NSRange
    var id: Int { range.location }

    static func outline(_ text: String) -> [Self] {
        let ns = text as NSString
        return MarkdownStyling.spans(in: text).compactMap { span in
            guard case .heading(let level) = span.role else { return nil }
            let title = ns.substring(with: span.range).dropFirst(level).trimmingCharacters(in: .whitespaces)
            return Self(level: level, title: title, range: span.range)
        }
    }

    static func section(_ title: String, in source: String) -> String? {
        let headings = outline(source)
        guard let start = headings.firstIndex(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) else { return nil }
        let text = source as NSString
        let end = headings.dropFirst(start + 1).first { $0.level <= headings[start].level }?.id ?? text.length
        return text.substring(with: NSRange(location: headings[start].id, length: end - headings[start].id))
    }
}

struct MarkdownHeadingJump: Equatable {
    let id = UUID()
    let path: String
    let heading: String
}

struct MarkdownCompletion: Equatable {
    let isLink: Bool
    let query: String
    let range: NSRange

    static func at(_ selection: NSRange, in source: String) -> Self? {
        let text = source as NSString
        guard selection.length == 0, selection.location <= text.length else { return nil }
        let line = text.lineRange(for: selection)
        let prefix = text.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        if let match = prefix.firstMatch(of: #/\[\[([^\[\]\n#|]*)$/#) {
            let length = String(match.0).utf16.count
            let suffix = text.substring(from: selection.location)
            return Self(isLink: true, query: String(match.1), range: NSRange(location: selection.location - length, length: length + (suffix.hasPrefix("]]") ? 2 : 0)))
        }
        if let match = prefix.firstMatch(of: #/(?:^|\s)#([\p{L}\p{N}_/-]*)$/#) {
            let length = match.1.utf16.count + 1
            return Self(isLink: false, query: String(match.1), range: NSRange(location: selection.location - length, length: length))
        }
        return nil
    }
}

struct MarkdownEditorAction: Equatable {
    let id = UUID()
    let kind: Kind
    enum Kind: Equatable {
        case wrap(String)
        case complete(MarkdownCompletion, String)
        case reveal(NSRange)
    }

    func replacement(in source: String, selection: NSRange) -> (NSRange, String, NSRange)? {
        let text = source as NSString
        guard NSMaxRange(selection) <= text.length else { return nil }
        switch kind {
        case .wrap(let marker):
            let wrapped = marker + text.substring(with: selection) + marker
            return (selection, wrapped, NSRange(location: selection.location + marker.utf16.count, length: selection.length))
        case .complete(let completion, let value):
            guard MarkdownCompletion.at(selection, in: source) == completion else { return nil }
            let replacement = completion.isLink ? "[[\(value)]]" : "#\(value)"
            return (completion.range, replacement, NSRange(location: completion.range.location + replacement.utf16.count, length: 0))
        case .reveal: return nil
        }
    }
}
