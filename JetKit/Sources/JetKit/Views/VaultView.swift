import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Main window for an open vault: file sidebar plus the selected note.
struct VaultView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var session: VaultSession

    @State private var showSyncSettings = false
    @State private var showQuickOpen = false
    @State private var showGraph = false
    @State private var newNoteName = ""
    @State private var showConnectAI = false
    @State private var columns = NavigationSplitViewVisibility.automatic
    @State private var dropTargeted = false

    private var author: GitAuthor { GitAuthor(name: app.authorName, email: app.authorEmail) }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(session: session, showSyncSettings: $showSyncSettings,
                        showQuickOpen: $showQuickOpen, showGraph: $showGraph, showConnectAI: $showConnectAI)
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
        } detail: {
            if let path = session.selection, !session.isDirectory(path) {
                NoteDetailView(session: session, path: path)
                    .id(path)
            } else if let folder = session.selection {
                ContentUnavailableView {
                    Label((folder as NSString).lastPathComponent, systemImage: "folder.fill")
                } description: {
                    Text("You're working in “\(folder)”. New notes and folders go here.")
                } actions: {
                    Button("New handwritten note") { session.requestNewNote(kind: .ink) }
                    Button("New text note") { session.requestNewNote(kind: .markdown) }
                }
            } else {
                ContentUnavailableView {
                    Label("No note open", systemImage: "note.text")
                } description: {
                    Text("Pick a note in the sidebar or start a new one.")
                } actions: {
                    Button("New handwritten note") { session.requestNewNote(kind: .ink) }
                    Button("New text note") { session.requestNewNote(kind: .markdown) }
                }
            }
        }
        // Files dropped anywhere on the window: opened if they're already in a vault, else imported.
        .onDrop(of: FileDrop.acceptedTypes,
                delegate: FileDropTarget(app: app, folder: nil, targeted: $dropTargeted))
        .clearsWhenDragEnds($dropTargeted)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .alert(
            session.importReview.map { $0.large.isEmpty ? "Some items weren't imported" : "Import large files?" } ?? "",
            isPresented: Binding(get: { session.importReview != nil }, set: { if !$0 { session.importReview = nil } }),
            presenting: session.importReview
        ) { review in
            if !review.large.isEmpty {
                Button("Import Anyway") { session.resolveImport(includeLarge: true) }
                Button(review.normal.isEmpty ? "Cancel" : "Skip Large Files", role: .cancel) { session.resolveImport(includeLarge: false) }
            } else {
                Button("OK", role: .cancel) { session.resolveImport(includeLarge: false) }
            }
        } message: { review in
            Text(review.message)
        }
        .sheet(isPresented: $showSyncSettings) { SyncSettingsView(session: session) }
        .sheet(isPresented: $showQuickOpen) { QuickOpenView(session: session) }
        .sheet(isPresented: $showGraph) { GraphView(session: session) }
        .alert(
            session.pendingNewNote?.kind == .ink ? "New handwritten note" : "New text note",
            isPresented: Binding(get: { session.pendingNewNote != nil }, set: { if !$0 { session.pendingNewNote = nil } })
        ) {
            TextField("Untitled", text: $newNoteName)
            Button("Create") { session.createPendingNote(named: newNoteName) }
            Button("Cancel", role: .cancel) { session.pendingNewNote = nil }
        } message: {
            Text(session.pendingNewNote.map { $0.folder.isEmpty ? "Leave the name empty for “Untitled”." : "In “\($0.folder)”. Leave the name empty for “Untitled”." } ?? "")
        }
        .onChange(of: session.pendingNewNote) { _, request in
            if request != nil { newNoteName = "" }
        }
        #if os(macOS)
        .sheet(isPresented: $showConnectAI) { ConnectAIView(session: session) }
        #endif
        // A tapped #tag fills the sidebar search, so make sure the sidebar is showing.
        .onChange(of: session.sidebarQuery) { _, query in
            if !query.isEmpty, columns != .all { columns = .all }
        }
        .task { await session.autoSyncLoop { GitAuthor(name: app.authorName, email: app.authorEmail) } }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                session.refreshTree()
                session.contentVersion += 1
                session.refreshStatus()
            case .background:
                syncInBackground()
            default:
                session.flushEditors()
            }
        }
    }

    /// Leaving the app: save, then push what we can in the time iPadOS gives us.
    private func syncInBackground() {
        session.flushEditors()
        guard session.hasRemote, session.autoSync else { return }
        #if os(iOS)
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "jet.sync") {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        Task {
            await session.sync(author: author)
            if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
        }
        #else
        Task { await session.sync(author: author) }
        #endif
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Bindable var session: VaultSession
    @Binding var showSyncSettings: Bool
    @Binding var showQuickOpen: Bool
    @Binding var showGraph: Bool
    @Binding var showConnectAI: Bool

    @State private var hits: [SearchHit] = []
    @State private var renaming: FileNode?
    @State private var renameText = ""
    @State private var deleting: FileNode?
    /// The parent folder of a folder being named, while the "New folder" prompt is up.
    @State private var newFolderParent: String?
    /// The "Import files" picker, and the folder picked files go into.
    @State private var importing = false
    /// Folders shown open in the sidebar (remembered per vault).
    @State private var expanded: Set<String> = []
    /// Where a drag over the sidebar would land, to draw it (Mac).
    @State private var dropIndicator: DropIndicator?
    @State private var importFolder = ""
    @State private var newFolderName = ""

    /// The tree as flat rows with their depth, following which folders are open.
    private var visibleRows: [(node: FileNode, depth: Int)] {
        var rows: [(FileNode, Int)] = []
        func walk(_ nodes: [FileNode], depth: Int) {
            for node in nodes {
                rows.append((node, depth))
                if node.isDirectory, expanded.contains(node.path) { walk(node.children ?? [], depth: depth + 1) }
            }
        }
        walk(session.tree, depth: 0)
        return rows
    }

    @ViewBuilder
    private var rows: some View {
        if session.sidebarQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            let rows = visibleRows
            ForEach(Array(rows.enumerated()), id: \.element.node.path) { index, row in
                TreeRow(node: row.node, depth: row.depth,
                        isOpen: expanded.contains(row.node.path),
                        isSelected: session.selection == row.node.path,
                        isCurrentFolder: row.node.isDirectory && session.targetFolder == row.node.path,
                        indicator: dropIndicator,
                        toggle: { toggle(row.node.path) })
                    .contentShape(Rectangle())
                    .onTapGesture { open(row.node) }
                    .contextMenu { menu(for: row.node) }
                    .modifier(RowDrag(node: row.node, depth: row.depth, isOpen: expanded.contains(row.node.path),
                                      nextSibling: nextSibling(of: row.node.path),
                                      app: app, indicator: $dropIndicator))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("vault-row-" + row.node.path)
                    .accessibilityAddTraits(session.selection == row.node.path ? [.isButton, .isSelected] : .isButton)
            }
            // The space below the list is the top level: drop there to move things out of folders.
            Color.clear
                .frame(height: 120)
                .overlay(alignment: .top) {
                    if dropIndicator == .line(folder: "", before: nil, depth: 0) { InsertionLine(depth: 0) }
                }
                .contentShape(Rectangle())
                .modifier(EndDrop(app: app, indicator: $dropIndicator))
                .accessibilityElement()
                .accessibilityLabel("End of the top level")
                .accessibilityIdentifier("vault-end-drop")
            let tags = session.allTags
            if !tags.isEmpty {
                Text("Tags").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(tags, id: \.name) { tag in
                    Button { session.sidebarQuery = "#" + tag.name } label: {
                        HStack {
                            Label(tag.name, systemImage: "number")
                            Spacer()
                            Text("\(tag.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .frame(minHeight: TreeRow.height)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if hits.isEmpty {
            Text("No matches").foregroundStyle(.secondary)
        } else {
            ForEach(hits) { hit in
                VStack(alignment: .leading, spacing: 2) {
                    Label(((hit.path as NSString).lastPathComponent as NSString).deletingPathExtension,
                          systemImage: FileKind(path: hit.path).symbol)
                    if !hit.snippet.isEmpty {
                        Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(session.selection == hit.path ? Color.accentColor.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .onTapGesture { session.selection = hit.path }
            }
        }
    }

    /// The row after `path` in its own folder (where "drop below this row" inserts), or nil at the end.
    private func nextSibling(of path: String) -> String? {
        let siblings = session.children(of: (path as NSString).deletingLastPathComponent).map(\.path)
        guard let index = siblings.firstIndex(of: path), index + 1 < siblings.count else { return nil }
        return siblings[index + 1]
    }

    /// A click on a folder opens it (and makes it the folder you're working in); a click on a
    /// folder that's already current closes it again.
    private func open(_ node: FileNode) {
        if node.isDirectory {
            if session.selection == node.path { toggle(node.path) } else {
                session.selection = node.path
                setOpen(node.path, true)
            }
        } else {
            session.selection = node.path
        }
    }

    private func toggle(_ folder: String) { setOpen(folder, !expanded.contains(folder)) }

    private func setOpen(_ folder: String, _ open: Bool) {
        if open { expanded.insert(folder) } else { expanded.remove(folder) }
        UserDefaults.standard.set(Array(expanded), forKey: expandedKey)
    }

    private var expandedKey: String { "vault.\(session.ref.id.uuidString).expanded" }

    /// Opens the folders above `path`, so the open note is always visible.
    private func reveal(_ path: String?) {
        guard let path else { return }
        var folder = (path as NSString).deletingLastPathComponent
        var changed = false
        while !folder.isEmpty {
            if expanded.insert(folder).inserted { changed = true }
            folder = (folder as NSString).deletingLastPathComponent
        }
        if changed { UserDefaults.standard.set(Array(expanded), forKey: expandedKey) }
    }

    @ViewBuilder
    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) { rows }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }

    /// Top of the sidebar: the folder you're working in (where new notes go), as a path you can
    /// click back up, plus sorting and New Folder.
    private var header: some View {
        let parts = session.targetFolder.isEmpty ? [] : session.targetFolder.split(separator: "/").map(String.init)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Files").font(.headline)
                    .accessibilityIdentifier("vault-root-drop")
                Spacer()
                Menu {
                    Picker("Sort By", selection: $session.sortMode) {
                        ForEach(SortMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    .pickerStyle(.inline)
                    Menu("Clean Up By") {
                        ForEach([SortMode.name, .modified, .kind]) { mode in
                            Button(mode.label) { session.cleanUp(by: mode) }
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort files, or clean up their order")
                .accessibilityIdentifier("sort-menu")
                Button { askForFolder(in: session.targetFolder) } label: {
                    Label("New folder", systemImage: "folder.badge.plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("New folder in \(parts.last ?? "the top level")")
            }
            // Where you are: new notes and folders go here.
            HStack(spacing: 4) {
                Button { session.selection = nil } label: {
                    Image(systemName: "house")
                }
                .buttonStyle(.borderless)
                .help("Top level")
                .accessibilityLabel("Top level")
                ForEach(parts.indices, id: \.self) { index in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(parts[index]) {
                        let folder = parts[...index].joined(separator: "/")
                        session.selection = folder
                        setOpen(folder, true)
                    }
                    .buttonStyle(.borderless)
                    .fontWeight(index == parts.count - 1 ? .semibold : .regular)
                    .lineLimit(1)
                }
                if parts.isEmpty { Text("Top level").fontWeight(.semibold) }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(Color.accentColor)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("current-folder")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .foregroundStyle(dropIndicator == .into("") ? Color.accentColor : .primary)
        .background(dropIndicator == .into("") ? Color.accentColor.opacity(0.15) : .clear)
        .contentShape(Rectangle())
        .modifier(HeaderDrop(app: app, indicator: $dropIndicator))
    }

    var body: some View {
        fileList
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .clearsWhenDragEnds($dropIndicator)
        .onAppear {
            expanded = Set(UserDefaults.standard.stringArray(forKey: expandedKey) ?? [])
            reveal(session.selection)
        }
        .onChange(of: session.selection) { _, path in reveal(path) }
        .searchable(text: $session.sidebarQuery, placement: .sidebar, prompt: "Search notes or #tags")
        .task(id: "\(session.sidebarQuery)|\(session.indexVersion)") {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            hits = await session.search(session.sidebarQuery)
        }
        .navigationTitle(session.ref.name)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button { session.requestNewNote(kind: .ink) } label: {
                        Label("Handwritten note", systemImage: "pencil.tip")
                    }
                    Button { session.requestNewNote(kind: .markdown) } label: {
                        Label("Text note", systemImage: "doc.text")
                    }
                    Divider()
                    Button { askForFolder(in: session.targetFolder) } label: {
                        Label("Folder", systemImage: "folder.badge.plus")
                    }
                    Button { importFiles(into: session.targetFolder) } label: {
                        Label("Import Files…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                } primaryAction: {
                    session.requestNewNote(kind: .platformDefault)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button { showQuickOpen = true } label: {
                    Label("Quick open", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("o", modifiers: .command)

                Button { session.openDailyNote() } label: {
                    Label("Today's note", systemImage: "calendar")
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .help("Open today's daily note")

                Button { showGraph = true } label: {
                    Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Graph of linked notes")

                #if os(macOS)
                Button { showConnectAI = true } label: {
                    Label("Connect AI", systemImage: "sparkles")
                }
                .help("Let Claude or ChatGPT read and edit this vault")
                #endif
            }
        }
        // On iPad the floating Pencil tool picker sits along the bottom edge, so sync lives at the top there.
        .safeAreaInset(edge: SyncBar.edge) {
            SyncBar(session: session, showSyncSettings: $showSyncSettings, showConnectAI: $showConnectAI)
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { session.requestImport(urls, into: importFolder) }
        }
        .alert("New folder", isPresented: Binding(get: { newFolderParent != nil }, set: { if !$0 { newFolderParent = nil } })) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                if let parent = newFolderParent { session.createFolder(in: parent, named: newFolderName) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(newFolderParent.map { $0.isEmpty ? "In the vault's top level." : "Inside “\($0)”." } ?? "")
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let node = renaming { session.rename(node.path, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deleting?.title ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let node = deleting { session.delete(node.path) }
            }
        } message: {
            Text(deleting?.isDirectory == true
                 ? "The folder and everything in it will be deleted. Synced versions stay in git history."
                 : "Synced versions stay in git history.")
        }
    }

    /// Every folder in the vault, depth first.
    private func folders(in nodes: [FileNode]) -> [String] {
        nodes.filter(\.isDirectory).flatMap { [$0.path] + folders(in: $0.children ?? []) }
    }

    private func importFiles(into folder: String) {
        importFolder = folder
        importing = true
    }

    private func askForFolder(in parent: String) {
        newFolderName = ""
        newFolderParent = parent
    }

    @ViewBuilder
    private func menu(for node: FileNode) -> some View {
        let folder = node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
        Button { session.requestNewNote(kind: .ink, in: folder) } label: {
            Label("New handwritten note here", systemImage: "pencil.tip")
        }
        Button { session.requestNewNote(kind: .markdown, in: folder) } label: {
            Label("New text note here", systemImage: "doc.text")
        }
        Button { askForFolder(in: folder) } label: {
            Label("New folder here", systemImage: "folder.badge.plus")
        }
        Button { importFiles(into: folder) } label: {
            Label("Import files here…", systemImage: "square.and.arrow.down")
        }
        Divider()
        let parent = (node.path as NSString).deletingLastPathComponent
        let destinations = [""] + folders(in: session.tree).filter { folder in
            folder != node.path && !folder.hasPrefix(node.path + "/")
        }
        Menu {
            ForEach(destinations.filter { $0 != parent }, id: \.self) { folder in
                Button(folder.isEmpty ? "Top level" : folder) { session.move(node.path, into: folder) }
            }
        } label: {
            Label("Move to", systemImage: "folder")
        }
        let siblings = session.children(of: parent).map(\.path)
        Button { session.nudge(node.path, by: -1) } label: {
            Label("Move Up", systemImage: "arrow.up")
        }
        .disabled(siblings.first == node.path)
        Button { session.nudge(node.path, by: 1) } label: {
            Label("Move Down", systemImage: "arrow.down")
        }
        .disabled(siblings.last == node.path)
        Button {
            renameText = node.title
            renaming = node
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Button(role: .destructive) { deleting = node } label: {
            Label("Delete…", systemImage: "trash")
        }
    }
}

/// Where a drag over the sidebar would land.
enum DropIndicator: Equatable {
    /// Into this folder ("" is the top level, via the header).
    case into(String)
    /// An insertion line: in `folder`, before `before` (at the end when nil), drawn at `depth`.
    case line(folder: String, before: String?, depth: Int)
}

/// One row of the file tree: indentation, disclosure arrow, icon and name.
private struct TreeRow: View {
    #if os(macOS)
    static let height: CGFloat = 26
    #else
    static let height: CGFloat = 44
    #endif
    static let indent: CGFloat = 16

    let node: FileNode
    let depth: Int
    let isOpen: Bool
    let isSelected: Bool
    let isCurrentFolder: Bool
    let indicator: DropIndicator?
    let toggle: () -> Void

    private var isDropTarget: Bool { indicator == .into(node.path) }

    var body: some View {
        HStack(spacing: 4) {
            if node.isDirectory {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: TreeRow.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOpen ? "Collapse folder" : "Expand folder")
                .accessibilityIdentifier((isOpen ? "collapse-" : "expand-") + node.path)
            } else {
                Color.clear.frame(width: 16)
            }
            Image(systemName: icon)
                .foregroundStyle(node.isDirectory && (isCurrentFolder || isDropTarget) ? Color.accentColor : .secondary)
                .frame(width: 20)
            Text(node.title)
                .lineLimit(1)
                .fontWeight(isCurrentFolder ? .semibold : .regular)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * TreeRow.indent + 2)
        .padding(.trailing, 6)
        .frame(height: TreeRow.height)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isDropTarget ? Color.accentColor : .clear, lineWidth: 2))
        .overlay(alignment: .top) {
            if case .line(_, let before, let lineDepth)? = indicator, before == node.path {
                InsertionLine(depth: lineDepth).offset(y: -1)
            }
        }
    }

    private var icon: String {
        guard node.isDirectory else { return FileKind(path: node.path).symbol }
        return isOpen || isCurrentFolder || isDropTarget ? "folder.fill" : "folder"
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.22) }
        if isDropTarget { return Color.accentColor.opacity(0.15) }
        if isCurrentFolder { return Color.accentColor.opacity(0.08) }
        return .clear
    }
}

/// Finder's insertion line, indented to the level the drop would land at.
private struct InsertionLine: View {
    let depth: Int

    var body: some View {
        HStack(spacing: 0) {
            Circle().strokeBorder(Color.accentColor, lineWidth: 2).frame(width: 7, height: 7)
            Rectangle().fill(Color.accentColor).frame(height: 2)
        }
        .padding(.leading, CGFloat(depth) * TreeRow.indent + 22)
        .allowsHitTesting(false)
    }
}

/// Mac: makes a row draggable, and a drop target that works like Finder's list view: the middle of
/// a folder drops into it; the top or bottom edge of any row inserts above or below it, at that
/// row's level (so dropping beside a top-level row moves things out to the top level). Rows can't be
/// dragged on iPad, where Move to, Move Up and Move Down in the row's menu do the job.
private struct RowDrag: ViewModifier {
    let node: FileNode
    let depth: Int
    let isOpen: Bool
    let nextSibling: String?
    let app: AppModel
    @Binding var indicator: DropIndicator?

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onDrag { VaultItem(path: node.path).itemProvider }
            .onDrop(of: FileDrop.acceptedTypes, delegate: TreeDropDelegate(
                app: app, indicator: $indicator,
                target: { location in RowDrag.target(for: location, node: node, depth: depth, isOpen: isOpen, next: nextSibling) }))
        #else
        content
        #endif
    }

    /// What a drop at `location` (in the row, y from the top) means.
    static func target(for location: CGPoint, node: FileNode, depth: Int, isOpen: Bool, next: String?) -> DropIndicator {
        let parent = (node.path as NSString).deletingLastPathComponent
        let y = location.y / TreeRow.height
        if node.isDirectory {
            if y < 0.25 { return .line(folder: parent, before: node.path, depth: depth) }
            if y > 0.75 {
                // Below an open folder is the top of its contents.
                if isOpen { return .line(folder: node.path, before: node.children?.first?.path, depth: depth + 1) }
                return .line(folder: parent, before: next, depth: depth)
            }
            return .into(node.path)
        }
        return y < 0.5 ? .line(folder: parent, before: node.path, depth: depth)
                       : .line(folder: parent, before: next, depth: depth)
    }
}

/// Mac: the empty space under the tree is the end of the top level.
private struct EndDrop: ViewModifier {
    let app: AppModel
    @Binding var indicator: DropIndicator?

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onDrop(of: FileDrop.acceptedTypes, delegate: TreeDropDelegate(
            app: app, indicator: $indicator, target: { _ in .line(folder: "", before: nil, depth: 0) }))
        #else
        content
        #endif
    }
}

/// The Files header takes drops into the top level (rows on Mac, files from outside on both).
private struct HeaderDrop: ViewModifier {
    let app: AppModel
    @Binding var indicator: DropIndicator?

    func body(content: Content) -> some View {
        content.onDrop(of: FileDrop.acceptedTypes, delegate: TreeDropDelegate(
            app: app, indicator: $indicator, target: { _ in .into("") }))
    }
}

/// Drops on the tree: Jet's own rows move (and, between rows, take that place in manual order);
/// files from outside are imported into the folder the drop points at.
struct TreeDropDelegate: DropDelegate {
    let app: AppModel
    @Binding var indicator: DropIndicator?
    let target: (CGPoint) -> DropIndicator

    private func isRow(_ info: DropInfo) -> Bool { info.hasItemsConforming(to: [.jetVaultItem]) }

    func validateDrop(info: DropInfo) -> Bool {
        #if os(iOS)
        // Rows can't be dragged on iPad; files from other apps can still be dropped.
        if isRow(info) { return false }
        #endif
        return isRow(info) || info.hasItemsConforming(to: [.fileURL, .item])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        let destination = target(info.location)
        if indicator != destination { indicator = destination }
        return DropProposal(operation: isRow(info) ? .move : .copy)
    }

    func dropExited(info: DropInfo) {
        indicator = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let destination = target(info.location)
        indicator = nil
        guard validateDrop(info: info) else { return false }
        let providers = info.itemProviders(for: FileDrop.acceptedTypes)
        let folder: String
        var before: String?
        var placing = false
        switch destination {
        case .into(let into): folder = into
        case .line(let into, let sibling, _):
            folder = into
            before = sibling
            placing = true
        }
        if isRow(info) {
            Task { @MainActor in
                guard let session = app.session else { return }
                for path in await FileDrop.vaultPaths(in: providers) where path != before {
                    if placing {
                        session.move(path, into: folder, before: before)
                    } else {
                        session.move(path, into: folder)
                    }
                }
            }
            return true
        }
        return FileDrop.handle(providers, app: app, into: folder)
    }
}

/// Bottom of the sidebar: sync status, tap to sync now, and the way into sync settings.
private struct SyncBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var session: VaultSession
    @Binding var showSyncSettings: Bool
    @Binding var showConnectAI: Bool

    #if os(iOS)
    static let edge = VerticalEdge.top
    #else
    static let edge = VerticalEdge.bottom
    #endif

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if session.hasRemote {
                    Task { await session.sync(author: GitAuthor(name: app.authorName, email: app.authorEmail)) }
                } else {
                    showSyncSettings = true
                }
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.callout)
                        if !detail.isEmpty {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(session.syncState == .syncing)

            Menu {
                Button("Sync settings…") { showSyncSettings = true }
                #if os(macOS)
                Button("Connect AI…") { showConnectAI = true }
                #endif
                Button("Close vault") { app.closeVault() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch session.syncState {
        case .syncing:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle:
            Image(systemName: session.hasRemote ? "arrow.triangle.2.circlepath" : "icloud.slash")
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch session.syncState {
        case .syncing: return "Syncing…"
        case .failed: return "Sync failed"
        case .idle:
            guard session.hasRemote else { return "Set up git sync" }
            if session.pendingChanges > 0 { return "Sync now" }
            return session.lastSync == nil ? "Sync now" : session.lastSyncSummary
        }
    }

    private var detail: String {
        switch session.syncState {
        case .syncing: return ""
        case .failed(let message): return message
        case .idle:
            guard session.hasRemote else { return "Notes stay on this device" }
            var parts: [String] = []
            if session.pendingChanges > 0 {
                parts.append(session.pendingChanges == 1 ? "Unsynced changes" : "\(session.pendingChanges) unsynced changes")
            }
            if let last = session.lastSync {
                parts.append("Last sync \(last.formatted(date: .omitted, time: .shortened))")
            }
            return parts.joined(separator: " · ")
        }
    }
}
