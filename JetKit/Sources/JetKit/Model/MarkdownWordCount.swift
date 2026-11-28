import Foundation

struct MarkdownWordCount {
    struct Counts {
        let words: Int
        let characters: Int
        let charactersExcludingSpaces: Int

        init(_ text: String) {
            var words = 0
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, _ in
                words += 1
            }
            self.words = words
            characters = text.count
            charactersExcludingSpaces = text.count { !$0.isWhitespace }
        }
    }

    let total: Counts
    let selection: Counts?

    init(total: String, selection: String?) {
        self.total = Counts(total)
        self.selection = selection.map(Counts.init)
    }

    init(source: String, selection: NSRange? = nil) {
        let lineCount = NoteSyntax.frontmatter(in: source).lineCount
        let sourceLength = source.utf16.count
        let bodyStart = lineCount == 0 ? 0 : min(sourceLength, source.components(separatedBy: "\n")
            .prefix(lineCount).reduce(0) { $0 + $1.utf16.count + 1 })
        let body = NSRange(location: bodyStart, length: sourceLength - bodyStart)
        let text = source as NSString
        let selected = selection.flatMap { range -> String? in
            guard range.length > 0, (0...sourceLength).contains(range.location),
                  range.length <= sourceLength - range.location else { return nil }
            return text.substring(with: NSIntersectionRange(body, range))
        }
        self.init(total: text.substring(with: body), selection: selected)
    }
}
