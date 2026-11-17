import Foundation

/// Finds what each part of a Markdown note is, for styling the source as you type (the Mac editor).
/// Works like Obsidian's live preview and Bear: the text stays plain Markdown, but headings are big,
/// **bold** is bold, and the markup around it (`**`, `[[ ]]`, link addresses…) can be dimmed or hidden.
public enum MarkdownStyling {
    public enum Role: Equatable, Sendable {
        case heading(Int)
        case bold, italic, strike, code
        /// A fenced code block, fences included.
        case codeBlock
        case quote
        case link, wikilink, embed, tag, url
        /// A list item's bullet, number or checkbox, and the hanging indent of its text.
        case listMarker
        case taskDone
        case rule
        case frontmatter
        /// Markup around something else. `hideable` markup (`#`, `**`, `[[`, a link's address…) is only
        /// shown on the line you're editing; the rest (code fences) is always shown, dimmed.
        case markup(hideable: Bool)
    }

    public struct Span: Equatable, Sendable {
        public let range: NSRange
        public let role: Role
        public init(_ range: NSRange, _ role: Role) {
            self.range = range
            self.role = role
        }
    }

    /// Every styled span in `text`, in no particular order. Inline styles never apply inside code or
    /// front matter.
    public static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var spans: [Span] = []
        var shielded = IndexSet()   // code and front matter: nothing else is styled inside

        func each(_ regex: NSRegularExpression, in range: NSRange = all, _ body: (NSTextCheckingResult) -> Void) {
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, !shielded.intersects(integersIn: Range(match.range) ?? 0..<0) else { return }
                body(match)
            }
        }
        func shield(_ range: NSRange) {
            if let r = Range(range) { shielded.insert(integersIn: r) }
        }
        func add(_ range: NSRange, _ role: Role) {
            if range.location != NSNotFound, range.length > 0 { spans.append(Span(range, role)) }
        }

        // Front matter: a `---` block at the very top.
        if let match = frontmatter.firstMatch(in: text, range: all) {
            add(match.range, .frontmatter)
            shield(match.range)
        }
        // Fenced code blocks, then inline code.
        each(fence) { match in
            add(match.range, .codeBlock)
            add(match.range(at: 1), .markup(hideable: false))
            add(match.range(at: 3), .markup(hideable: false))
            shield(match.range)
        }
        each(inlineCode) { match in
            add(match.range(at: 2), .code)
            add(match.range(at: 1), .markup(hideable: true))
            add(match.range(at: 3), .markup(hideable: true))
            shield(match.range)
        }

        // Block structure, line by line.
        each(heading) { match in
            let level = match.range(at: 1).length
            add(match.range, .heading(level))
            add(NSRange(location: match.range(at: 1).location,
                        length: match.range(at: 1).length + match.range(at: 2).length), .markup(hideable: true))
        }
        each(rule) { add($0.range, .rule) }
        each(quote) { match in
            add(match.range, .quote)
            add(match.range(at: 1), .markup(hideable: true))
        }
        each(list) { match in
            let box = match.range(at: 4)
            let markerEnd = box.location != NSNotFound ? NSMaxRange(box) : NSMaxRange(match.range(at: 3))
            add(NSRange(location: match.range(at: 2).location, length: markerEnd - match.range(at: 2).location), .listMarker)
            if box.location != NSNotFound, ns.substring(with: box).lowercased().contains("x") {
                add(NSRange(location: markerEnd, length: NSMaxRange(match.range) - markerEnd), .taskDone)
            }
        }

        // Inline.
        each(embed) { match in
            add(match.range, .embed)
        }
        each(wikilink) { match in
            add(match.range(at: 2), .wikilink)
            add(match.range(at: 1), .markup(hideable: true))
            add(match.range(at: 3), .markup(hideable: true))
        }
        each(markdownLink) { match in
            add(match.range(at: 2), .link)
            add(match.range(at: 1), .markup(hideable: true))
            add(match.range(at: 3), .markup(hideable: true))
        }
        each(bareURL) { match in
            // Not the address part of a [text](address) link, which is markup.
            if !spans.contains(where: { $0.role == .markup(hideable: true) && NSIntersectionRange($0.range, match.range).length > 0 }) {
                add(match.range, .url)
            }
        }
        each(bold) { match in
            add(match.range(at: 2), .bold)
            add(match.range(at: 1), .markup(hideable: true))
            add(match.range(at: 3), .markup(hideable: true))
        }
        for regex in [italicStar, italicUnderscore] {
            each(regex) { match in
                add(match.range(at: 2), .italic)
                add(match.range(at: 1), .markup(hideable: true))
                add(match.range(at: 3), .markup(hideable: true))
            }
        }
        each(strike) { match in
            add(match.range(at: 2), .strike)
            add(match.range(at: 1), .markup(hideable: true))
            add(match.range(at: 3), .markup(hideable: true))
        }
        each(NoteSyntax.tagRegex) { match in
            // Group 2 is the name; include the `#`.
            let name = match.range(at: 2)
            add(NSRange(location: name.location - 1, length: name.length + 1), .tag)
        }
        return spans
    }

    // MARK: Patterns

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    static let frontmatter = try! NSRegularExpression(pattern: #"\A---[ \t]*\n[\s\S]*?\n---[ \t]*$"#, options: [.anchorsMatchLines])
    static let fence = regex(#"^([ \t]*(?:```|~~~)[^\n]*)\n[\s\S]*?(\n([ \t]*(?:```|~~~))[ \t]*$|\z)"#)
    static let inlineCode = regex(#"(`+)([^`\n]+?)(\1)"#)
    static let heading = regex(#"^(#{1,6})([ \t]+)(.*)$"#)
    static let rule = regex(#"^[ ]{0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    static let quote = regex(#"^([ ]{0,3}>[ \t]?)(.*)$"#)
    static let list = regex(#"^([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+)(\[[ xX]\][ \t]+)?.*$"#)
    static let embed = regex(#"!\[\[[^\]\n]+\]\]|!\[[^\]\n]*\]\([^)\n]*\)"#)
    static let wikilink = regex(#"(?<!!)(\[\[)([^\]\n]+)(\]\])"#)
    static let markdownLink = regex(#"(?<!!)(\[)([^\]\n]+)(\]\([^)\n]*\))"#)
    static let bareURL = regex(#"https?://[^\s)>\]]+"#)
    static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)(\1)"#)
    static let italicStar = regex(#"(?<![*\w])(\*)(?=[^\s*])(.+?)(?<=[^\s*])(\*)(?![*\w])"#)
    static let italicUnderscore = regex(#"(?<![_\w])(_)(?=[^\s_])(.+?)(?<=[^\s_])(_)(?![_\w])"#)
    static let strike = regex(#"(~~)(?=\S)(.+?)(?<=\S)(~~)"#)
}
