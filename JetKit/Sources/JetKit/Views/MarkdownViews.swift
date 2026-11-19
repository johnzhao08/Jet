import SwiftUI
import UniformTypeIdentifiers

/// Markdown note: source editor and rendered reading view, toggled with ⌘E.
struct MarkdownNoteView: View {
    let session: VaultSession
    let path: String

    @State private var model: MarkdownNoteModel
    @State private var editorID: UUID?
    @AppStorage("jet.markdown.reading") private var reading = false
    @Environment(\.openURL) private var openURL
    @AppStorage("jet.markdown.fontSize") private var fontSize = 15.0
    @State private var completion: MarkdownCompletion?
    @State private var action: MarkdownEditorAction?
    @State private var output: MarkdownOutputRequest?
    @State private var pdf: MarkdownPDFDocument?
    @State private var exporting = false
    @State private var message: String?
    @State private var unlinked: [SearchHit] = []
    @State private var inspector = false
    @State private var imageSource: ImageSource?
    /// Text waiting to go in at the cursor (a picture's embed).
    @State private var insertion: String?

    init(session: VaultSession, path: String) {
        self.session = session
        self.path = path
        _model = State(initialValue: MarkdownNoteModel(url: session.url(for: path)))
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if reading {
                MarkdownReader(session: session, model: model, path: path, text: model.text, version: session.contentVersion,
                               fontSize: fontSize, jump: session.headingJump, output: output, follow: follow) { result in
                    switch result {
                    case .success(let data): pdf = MarkdownPDFDocument(data); exporting = true
                    case .failure(let error): message = error.localizedDescription
                    }
                }
            } else {
                #if os(macOS)
                MarkdownTextView(text: $model.text, insertion: $insertion, action: action, fontSize: fontSize,
                                 completion: { completion = $0 }, follow: { follow($0, path) }, image: { embed in
                    guard let file = session.embeddedFile(embed, inNote: path),
                          FileKind(path: file) == .image else { return nil }
                    return session.url(for: file)
                }) { files in
                    files.compactMap { url in
                        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                              let data = try? Data(contentsOf: url),
                              let path = session.addImage(data, type: type, named: url.deletingPathExtension().lastPathComponent)
                        else { return nil }
                        return "![[\(session.linkTarget(for: path))]]"
                    }
                }
                #else
                MarkdownPadEditor(text: $model.text, insertion: $insertion, action: action,
                                  fontSize: fontSize, completion: { completion = $0 })
                #endif
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !reading, let completion, !suggestions(for: completion).isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(suggestions(for: completion), id: \.self) { suggestion in
                            Button(suggestion) { action = MarkdownEditorAction(kind: .complete(completion, suggestion)) }
                        }
                    }.padding(8)
                }.background(.bar)
            }
        }
        .fileExporter(isPresented: $exporting, document: pdf, contentType: .pdf,
                      defaultFilename: ((path as NSString).lastPathComponent as NSString).deletingPathExtension) { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .alert("Markdown note", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .imageInsertion($imageSource, session: session) { path, _ in embed(path) }
        #if os(macOS)
        // In the reading view, pictures dropped on the note go into it (saved in Attachments); the
        // editor takes its own drops, at the spot they land. Other files fall through to the window,
        // which imports them, as does the sidebar.
        .onDrop(of: FileDrop.acceptedTypes, delegate: PictureDrop(session: session) { path, _, _ in embed(path) })
        #endif
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
                Menu {
                    if !reading {
                        Button("Bold") { action = MarkdownEditorAction(kind: .wrap("**")) }.keyboardShortcut("b")
                        Button("Italic") { action = MarkdownEditorAction(kind: .wrap("*")) }.keyboardShortcut("i")
                        Divider()
                    }
                    Picker("Font size", selection: $fontSize) {
                        ForEach([12.0, 15, 18, 21, 24], id: \.self) { size in Text("\(Int(size)) pt").tag(size) }
                    }
                    Button("Export PDF…") { requestOutput(printDialog: false) }
                    Button("Print…") { requestOutput(printDialog: true) }.keyboardShortcut("p")
                    Divider()
                    ImageSourceButtons(source: $imageSource)
                } label: {
                    Label("Note actions", systemImage: "ellipsis.circle")
                }
                .help("Formatting, print, export and pictures")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { inspector.toggle() } label: { Label("Outline and backlinks", systemImage: "list.bullet.indent") }
                    .popover(isPresented: $inspector) { navigationInspector }
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
            revealEditorHeading()
            model.onWrite = { session.didWriteFile() }
            editorID = session.registerEditor { model.saveNow() }
        }
        .onDisappear {
            model.saveNow()
            session.unregisterEditor(editorID)
        }
        .onChange(of: session.headingJump) { revealEditorHeading() }
        .task(id: session.indexVersion) { unlinked = await session.unlinkedMentions(of: path) }
        .onChange(of: session.contentVersion) { model.reloadIfChangedOnDisk() }
    }

    private func requestOutput(printDialog: Bool) {
        reading = true
        output = MarkdownOutputRequest(printDialog: printDialog)
    }

    private func follow(_ target: String, _ source: String) {
        if let url = URL(string: target), let scheme = url.scheme {
            if ["http", "https", "mailto"].contains(scheme.lowercased()) { openURL(url) }
            return
        }
        let decoded = target.removingPercentEncoding ?? target
        let parts = decoded.components(separatedBy: "#")
        let name = parts[0]
        let resolved = name.isEmpty ? source : (session.file(name, relativeTo: source) ?? session.resolve(name, from: source))
        let suffix = parts.count > 1 ? "#" + parts.dropFirst().joined(separator: "#") : ""
        // A resolved path is vault-relative; openLink resolves again from the open note, so mark it as rooted.
        session.openLink((resolved.map { "/" + $0 } ?? name) + suffix)
    }

    private func revealEditorHeading() {
        guard !reading, let jump = session.headingJump, jump.path == path,
              let heading = MarkdownHeading.outline(model.text).first(where: { $0.title.caseInsensitiveCompare(jump.heading) == .orderedSame }) else { return }
        action = MarkdownEditorAction(kind: .reveal(heading.range))
    }

    private func suggestions(for completion: MarkdownCompletion) -> [String] {
        if completion.isLink {
            let matches = session.allNotes.filter { completion.query.isEmpty || $0.path.localizedCaseInsensitiveContains(completion.query) }
            return matches.prefix(8).map { session.linkText(for: $0, from: path) }
        }
        return Array(session.index.tags.keys.filter { completion.query.isEmpty || $0.localizedCaseInsensitiveContains(completion.query) }.sorted().prefix(8))
    }

    private var navigationInspector: some View {
        List {
            Section("Outline") {
                let headings = MarkdownHeading.outline(model.text)
                if headings.isEmpty { Text("No headings").foregroundStyle(.secondary) }
                ForEach(headings) { heading in
                    Button(heading.title) {
                        inspector = false
                        session.headingJump = MarkdownHeadingJump(path: path, heading: heading.title)
                    }.padding(.leading, CGFloat(heading.level - 1) * 8)
                }
            }
            Section("Linked from") {
                let backlinks = (session.index.backlinks[path] ?? []).sorted()
                if backlinks.isEmpty { Text("No backlinks").foregroundStyle(.secondary) }
                ForEach(backlinks, id: \.self) { source in Button(source) { inspector = false; session.selection = source } }
            }
            if !unlinked.isEmpty {
                Section("Mentioned in (not linked)") {
                    ForEach(unlinked) { hit in
                        UnlinkedMentionRow(hit: hit) { inspector = false; session.selection = hit.path } link: {
                            session.linkMention(in: hit.path, to: path)
                        }
                    }
                }
            }
        }.frame(minWidth: 280, idealWidth: 320, minHeight: 280, idealHeight: 420)
    }

    /// Puts a picture's embed at the cursor (or at the end while reading).
    private func embed(_ imagePath: String) {
        let embed = "![[\(session.linkTarget(for: imagePath))]]"
        if reading {
            model.text = TextInsertion.appending(embed, to: model.text)
        } else {
            insertion = embed
        }
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

#if os(macOS)
/// Pictures dragged onto a note, a handwritten page or a PDF: from Finder, a browser, Photos or another
/// app. Each is saved in `Attachments/`, then handed over with its pixel size and where it was dropped
/// (in the view's coordinates; several pictures step down and right from there).
struct PictureDrop: DropDelegate {
    let session: VaultSession
    let insert: (_ path: String, _ pixelSize: CGSize, _ at: CGPoint) -> Void

    /// Decided from the drag's types alone, like every drop check during a drag (see `FileDrop`).
    func validateDrop(info: DropInfo) -> Bool {
        FileDrop.carriesImage(types: info.draggedTypes, fileURLs: FileDrop.draggedFileURLs())
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .copy : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        let providers = info.itemProviders(for: FileDrop.acceptedTypes)
        var point = info.location
        Task { @MainActor in
            for url in await FileDrop.fileURLs(in: providers) {
                guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                      let data = try? Data(contentsOf: url),
                      let path = session.addImage(data, type: type, named: url.deletingPathExtension().lastPathComponent)
                else { continue }
                insert(path, ImageFiles.pixelSize(of: session.url(for: path)) ?? CGSize(width: 800, height: 600), point)
                point.x += 24
                point.y += 24
            }
        }
        return true
    }
}
#endif

enum TextInsertion {
    /// `snippet` on a new line at the end of `text`.
    static func appending(_ snippet: String, to text: String) -> String {
        (text.isEmpty || text.hasSuffix("\n") ? text : text + "\n") + snippet + "\n"
    }
}

extension VaultSession {
    /// The shortest `[[link]]` text that opens `node` from the note at `source`: its title, else its path,
    /// else the path from the vault root (`/Note.md`) when a nearer note would otherwise win.
    func linkText(for node: FileNode, from source: String) -> String {
        [node.title, node.path, "/" + node.path].first { resolve($0, from: source) == node.path } ?? "/" + node.path
    }

    /// A link target written relative to the note at `notePath` (`../Pics/a.png`), if that file exists.
    func file(_ target: String, relativeTo notePath: String) -> String? {
        let decoded = target.removingPercentEncoding ?? target
        let folder = (notePath as NSString).deletingLastPathComponent
        var parts = decoded.hasPrefix("/") ? [] : folder.split(separator: "/").map(String.init)
        for part in decoded.split(separator: "/").map(String.init) {
            if part == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast() }
            else if part != "." { parts.append(part) }
        }
        let candidate = parts.joined(separator: "/")
        guard !candidate.isEmpty, (try? root.vaultFile(candidate)) != nil, exists(candidate), !isDirectory(candidate) else { return nil }
        return candidate
    }

    /// The vault file an embed (`![[name]]`, `![alt](path)`) in the note at `notePath` shows, if any.
    func embeddedFile(_ embed: String, inNote notePath: String) -> String? {
        var target = embed
        if target.hasPrefix("![["), target.hasSuffix("]]") {
            target = String(target.dropFirst(3).dropLast(2))
        } else if let open = target.range(of: "]("), target.hasSuffix(")") {
            target = String(target[open.upperBound...].dropLast())
        } else {
            return nil
        }
        let name = target.split(separator: "|").first.map(String.init) ?? target
        return file(name, relativeTo: notePath) ?? resolve(name)
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
            if FileKind(path: hit.path) == .markdown {
                Button("Link", action: link)
                .controlSize(.small)
                .help("Turn this mention into a [[link]]")
            }
        }
    }
}
