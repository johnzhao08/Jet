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

    private var title: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    var body: some View {
        @Bindable var model = model
        Group {
            if reading {
                MarkdownPreview(session: session, model: model, title: title)
            } else {
                TextEditor(text: $model.text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
        }
        .toolbar {
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

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(MarkdownBlock(id: paragraphStart, kind: .paragraph(paragraph.joined(separator: "\n"))))
            paragraph = []
        }

        for (index, rawLine) in source.components(separatedBy: "\n").enumerated() {
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

    /// Inline Markdown, with `[[wikilinks]]` turned into `jet://note/…` links.
    static func inline(_ text: String) -> AttributedString {
        let linked = text.replacing(#/\[\[([^\]]+)\]\]/#) { match -> String in
            let parts = match.1.split(separator: "|", maxSplits: 1).map(String.init)
            let target = parts.first ?? ""
            let label = parts.count > 1 ? parts[1] : target
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
            return "[\(label)](jet://note/\(encoded))"
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: linked, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Reading view

struct MarkdownPreview: View {
    let session: VaultSession
    let model: MarkdownNoteModel
    let title: String

    var body: some View {
        let blocks = MarkdownBlock.parse(model.text)
        let mentions = (session.backlinks[title.lowercased()] ?? []).sorted()
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { block in
                    view(for: block)
                }
                if !mentions.isEmpty {
                    Divider().padding(.top, 24)
                    Text("Linked from").font(.caption).foregroundStyle(.secondary)
                    ForEach(mentions, id: \.self) { path in
                        Button {
                            session.selection = path
                        } label: {
                            Label(((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                                  systemImage: "arrow.turn.down.right")
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "jet" else { return .systemAction }
            session.openLink(String(url.path.dropFirst()))
            return .handled
        })
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
        case .rule:
            Divider()
        }
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
