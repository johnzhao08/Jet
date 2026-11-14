import SwiftUI

/// Markdown note: source editor and rendered reading view, toggled with ⌘E.
struct MarkdownNoteView: View {
    let session: VaultSession
    let path: String

    @State private var model: MarkdownNoteModel
    @State private var editorID: UUID?
    @AppStorage("jet.markdown.reading") private var reading = false

    init(session: VaultSession, path: String) {
        self.session = session
        self.path = path
        _model = State(initialValue: MarkdownNoteModel(url: session.url(for: path)))
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if reading {
                MarkdownPreview(session: session, model: model, path: path)
            } else {
                TextEditor(text: $model.text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
        }
        .toolbar {
            if VaultSession.dailyDate(of: path) != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { open(dailyNeighbor(before: true)) } label: {
                        Label("Previous day", systemImage: "chevron.left")
                    }
                    .disabled(dailyNeighbor(before: true) == nil)
                    .help("Previous daily note")
                    Button { open(dailyNeighbor(before: false)) } label: {
                        Label("Next day", systemImage: "chevron.right")
                    }
                    .disabled(dailyNeighbor(before: false) == nil)
                    .help("Next daily note")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { reading.toggle() } label: {
                    Label(reading ? "Edit" : "Read", systemImage: reading ? "pencil" : "book")
                }
                .keyboardShortcut("e", modifiers: .command)
                .help(reading ? "Edit source" : "Reading view")
            }
        }
        .onAppear {
            model.onWrite = { session.didWriteFile() }
            editorID = session.registerEditor { model.saveNow() }
        }
        .onDisappear {
            model.saveNow()
            session.unregisterEditor(editorID)
        }
        .onChange(of: session.contentVersion) { model.reloadIfChangedOnDisk() }
    }

    private func open(_ path: String?) {
        if let path { session.selection = path }
    }

    /// The closest existing daily note before or after this one.
    private func dailyNeighbor(before: Bool) -> String? {
        let days = session.allNotes.map(\.path)
            .filter { VaultSession.dailyDate(of: $0) != nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return before
            ? days.last { $0.localizedStandardCompare(path) == .orderedAscending }
            : days.first { $0.localizedStandardCompare(path) == .orderedDescending }
    }
}

// MARK: - Parsing

struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(indent: Int, text: String)
        case ordered(indent: Int, marker: String, text: String)
        case task(indent: Int, done: Bool, text: String)
        case quote(String)
        case code(String)
        case embed(String)
        case properties([NoteSyntax.Property])
        case rule
    }

    /// Index of the block's first source line.
    let id: Int
    let kind: Kind

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var paragraphStart = 0
        var code: [String]?
        var codeStart = 0
        let frontmatter = NoteSyntax.frontmatter(in: source)
        if frontmatter.lineCount > 0, !frontmatter.properties.isEmpty {
            blocks.append(MarkdownBlock(id: 0, kind: .properties(frontmatter.properties)))
        }

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(MarkdownBlock(id: paragraphStart, kind: .paragraph(paragraph.joined(separator: "\n"))))
            paragraph = []
        }

        for (index, rawLine) in source.components(separatedBy: "\n").enumerated() where index >= frontmatter.lineCount {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(MarkdownBlock(id: codeStart, kind: .code(lines.joined(separator: "\n"))))
                    code = nil
                } else {
                    flush()
                    code = []
                    codeStart = index
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }

            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2

            if trimmed.isEmpty {
                flush()
            } else if let match = trimmed.wholeMatch(of: #/(#{1,6})\s+(.*)/#) {
                flush()
                blocks.append(MarkdownBlock(id: index, kind: .heading(level: match.1.count, text: String(match.2))))
            } else if trimmed.wholeMatch(of: #/(-{3,}|\*{3,}|_{3,})/#) != nil {
                flush()
                blocks.append(MarkdownBlock(id: index, kind: .rule))
            } else if let match = trimmed.wholeMatch(of: #/!\[\[([^\]]+)\]\]/#) {
                flush()
                blocks.append(MarkdownBlock(id: index, kind: .embed(String(match.1))))
            } else if let match = trimmed.wholeMatch(of: #/[-*+]\s+\[([ xX])\]\s+(.*)/#) {
                flush()
                blocks.append(MarkdownBlock(id: index, kind: .task(indent: indent, done: match.1 != " ", text: String(match.2))))
            } else if let match = trimmed.wholeMatch(of: #/[-*+]\s+(.*)/#) {
                flush()
                blocks.append(MarkdownBlock(id: index, kind: .bullet(indent: indent, text: String(match.1))))
            } else if let match = trimmed.wholeMatch(of: #/(\d+[.)])\s+(.*)/#) {
                flush()
                blocks.append(MarkdownBlock(id: index, kind: .ordered(indent: indent, marker: String(match.1), text: String(match.2))))
            } else if let match = trimmed.wholeMatch(of: #/>\s?(.*)/#) {
                flush()
                if case .quote(let previous)? = blocks.last?.kind, let last = blocks.last {
                    blocks[blocks.count - 1] = MarkdownBlock(id: last.id, kind: .quote(previous + "\n" + String(match.1)))
                } else {
                    blocks.append(MarkdownBlock(id: index, kind: .quote(String(match.1))))
                }
            } else {
                if paragraph.isEmpty { paragraphStart = index }
                paragraph.append(trimmed)
            }
        }
        if let lines = code {
            blocks.append(MarkdownBlock(id: codeStart, kind: .code(lines.joined(separator: "\n"))))
        }
        flush()
        return blocks
    }

    /// Inline Markdown, with `[[wikilinks]]` turned into `jet://note/…` links and `#tags` into `jet://tag/…` links.
    /// Text inside `inline code` is left alone.
    static func inline(_ text: String) -> AttributedString {
        let linked = text.split(separator: "`", omittingEmptySubsequences: false).enumerated().map { index, part in
            index.isMultiple(of: 2) ? linkify(String(part)) : String(part)
        }.joined(separator: "`")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: linked, options: options)) ?? AttributedString(text)
    }

    private static func linkify(_ text: String) -> String {
        let withLinks = text.replacing(#/\[\[([^\]]+)\]\]/#) { match -> String in
            let parts = match.1.split(separator: "|", maxSplits: 1).map(String.init)
            let target = parts.first ?? ""
            let label = parts.count > 1 ? parts[1] : target
            return "[\(label)](jet://note/\(encode(target)))"
        }
        return withLinks.replacing(#/(^|\s)#([\p{L}\p{N}_\/-]+)/#) { match -> String in
            let tag = String(match.2)
            guard NoteSyntax.isTag(tag) else { return String(match.0) }
            return "\(match.1)[#\(tag)](jet://tag/\(encode(tag)))"
        }
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}

// MARK: - Reading view

struct MarkdownPreview: View {
    let session: VaultSession
    let model: MarkdownNoteModel
    let path: String

    @State private var unlinked: [SearchHit] = []

    var body: some View {
        let blocks = MarkdownBlock.parse(model.text)
        let backlinks = (session.index.backlinks[path] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { block in
                    view(for: block)
                }
                if !backlinks.isEmpty || !unlinked.isEmpty {
                    Divider().padding(.top, 24)
                }
                if !backlinks.isEmpty {
                    Text("Linked from").font(.caption).foregroundStyle(.secondary)
                    ForEach(backlinks, id: \.self) { source in
                        Button {
                            session.selection = source
                        } label: {
                            Label(noteTitle(source), systemImage: "arrow.turn.down.right")
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                }
                if !unlinked.isEmpty {
                    Text("Mentioned in (not linked)").font(.caption).foregroundStyle(.secondary)
                        .padding(.top, backlinks.isEmpty ? 0 : 8)
                    ForEach(unlinked) { hit in
                        UnlinkedMentionRow(hit: hit) {
                            session.selection = hit.path
                        } link: {
                            session.linkMention(in: hit.path, to: path)
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
        }
        .task(id: session.indexVersion) {
            unlinked = await session.unlinkedMentions(of: path)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "jet" else { return .systemAction }
            let value = String(url.path.dropFirst())
            switch url.host {
            case "tag": session.sidebarQuery = "#" + value
            default: session.openLink(value)
            }
            return .handled
        })
    }

    private func noteTitle(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(MarkdownBlock.inline(text))
                .font(level == 1 ? .largeTitle.bold() : level == 2 ? .title.bold() : level == 3 ? .title2.bold() : .headline)
                .padding(.top, level <= 2 ? 10 : 4)
        case .paragraph(let text):
            Text(MarkdownBlock.inline(text))
        case .bullet(let indent, let text):
            listRow(indent: indent, marker: Text("•"), text: text)
        case .ordered(let indent, let marker, let text):
            listRow(indent: indent, marker: Text(marker).monospacedDigit(), text: text)
        case .task(let indent, let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    model.toggleTask(atLine: block.id)
                } label: {
                    Image(systemName: done ? "checkmark.square.fill" : "square")
                        .foregroundStyle(done ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? "Mark as not done" : "Mark as done")
                Text(MarkdownBlock.inline(text))
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .quote(let text):
            Text(MarkdownBlock.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.tertiary).frame(width: 3)
                }
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .embed(let target):
            embed(target)
        case .properties(let properties):
            propertiesView(properties)
        case .rule:
            Divider()
        }
    }

    private func propertiesView(_ properties: [NoteSyntax.Property]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(properties, id: \.self) { property in
                GridRow {
                    Text(property.key).foregroundStyle(.secondary)
                    Text(MarkdownBlock.inline(display(property)))
                }
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 6)
    }

    /// Tag properties render as tappable `#tags`, lists as comma-separated values.
    private func display(_ property: NoteSyntax.Property) -> String {
        if ["tags", "tag"].contains(property.key.lowercased()) {
            return NoteSyntax.tags(in: "", properties: [property]).map { "#" + $0 }.joined(separator: " ")
        }
        return property.values.isEmpty ? "—" : property.values.joined(separator: ", ")
    }

    private func listRow(indent: Int, marker: Text, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker.foregroundStyle(.secondary)
            Text(MarkdownBlock.inline(text))
        }
        .padding(.leading, CGFloat(indent) * 18)
    }

    @ViewBuilder
    private func embed(_ target: String) -> some View {
        let name = target.split(separator: "|").first.map(String.init) ?? target
        if let path = session.resolve(name) {
            let ext = (path as NSString).pathExtension.lowercased()
            if ext == "ink" {
                Button {
                    session.selection = path
                } label: {
                    InkEmbedView(url: session.url(for: path), version: session.contentVersion)
                }
                .buttonStyle(.plain)
            } else if let image = PlatformImage(contentsOfFile: session.url(for: path).path) {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 600)
            } else {
                Button(name) { session.selection = path }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        } else {
            Text("Missing: \(name)").foregroundStyle(.secondary).italic()
        }
    }
}

/// A note that mentions the open note's title as plain text, with a button that turns the mention into a link.
private struct UnlinkedMentionRow: View {
    let hit: SearchHit
    let open: () -> Void
    let link: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(((hit.path as NSString).lastPathComponent as NSString).deletingPathExtension,
                          systemImage: "text.quote")
                        .foregroundStyle(Color.accentColor)
                    if !hit.snippet.isEmpty {
                        Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button("Link", action: link)
                .controlSize(.small)
                .help("Turn this mention into a [[link]]")
        }
    }
}
