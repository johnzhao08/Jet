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
        .onDrop(of: FileDrop.acceptedTypes, isTargeted: $dropTargeted) { providers in
            FileDrop.handle(providers, app: app, into: nil)
        }
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
    /// The folder a drag is hovering over ("" for the top level), to highlight it.
    @State private var dropTarget: String?
    @State private var importFolder = ""
    @State private var newFolderName = ""

    var body: some View {
        List(selection: $session.selection) {
            if session.sidebarQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    OutlineGroup(session.tree, children: \.children) { node in
                        FileRow(node: node, dropTarget: dropTarget == node.path)
                            .contextMenu { menu(for: node) }
                            // Drag a row onto a folder (or the Files header) to move it there.
                            .itemProvider { VaultItem(path: node.path).itemProvider }
                            .modifier(FolderDrop(folder: node.isDirectory ? node.path : nil, target: $dropTarget))
                    }
                } header: {
                    HStack {
                        Text("Files")
                            .foregroundStyle(dropTarget == "" ? Color.accentColor : .secondary)
                        Spacer()
                        Button { askForFolder(in: session.targetFolder) } label: {
                            Label("New folder", systemImage: "folder.badge.plus")
                                .labelStyle(.iconOnly)
                                .font(.body)
                        }
                        .buttonStyle(.borderless)
                        .help("New folder")
                    }
                    .contentShape(Rectangle())
                    // Dropping on the header moves things to the vault's top level.
                    .modifier(FolderDrop(folder: "", target: $dropTarget))
                }
                let tags = session.allTags
                if !tags.isEmpty {
                    Section("Tags") {
                        ForEach(tags, id: \.name) { tag in
                            Button { session.sidebarQuery = "#" + tag.name } label: {
                                HStack {
                                    Label(tag.name, systemImage: "number")
                                    Spacer()
                                    Text("\(tag.count)").foregroundStyle(.secondary).monospacedDigit()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
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
                    .tag(hit.path)
                }
            }
        }
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

/// Makes a folder row (or the Files header) a drop target: rows dragged onto it move in, files dropped
/// onto it are imported into it.
private struct FolderDrop: ViewModifier {
    @Environment(AppModel.self) private var app
    let folder: String?
    @Binding var target: String?

    func body(content: Content) -> some View {
        if let folder {
            content.onDrop(of: FileDrop.acceptedTypes, isTargeted: Binding(
                get: { target == folder },
                set: { hovering in if hovering { target = folder } else if target == folder { target = nil } }
            )) { providers in
                target = nil
                return FileDrop.handle(providers, app: app, into: folder)
            }
        } else {
            content
        }
    }
}

private struct FileRow: View {
    let node: FileNode
    var dropTarget = false

    private var icon: String {
        node.isDirectory ? "folder" : FileKind(path: node.path).symbol
    }

    var body: some View {
        Label(node.title, systemImage: dropTarget ? "folder.fill" : icon)
            .lineLimit(1)
            .foregroundStyle(dropTarget ? Color.accentColor : .primary)
            .padding(.vertical, 1)
            .background(dropTarget ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
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
