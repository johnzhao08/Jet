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
    @State private var columns = NavigationSplitViewVisibility.automatic

    private var author: GitAuthor { GitAuthor(name: app.authorName, email: app.authorEmail) }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(session: session, showSyncSettings: $showSyncSettings,
                        showQuickOpen: $showQuickOpen, showGraph: $showGraph)
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
                    Button("New handwritten note") { session.createNote(kind: .ink) }
                    Button("New text note") { session.createNote(kind: .markdown) }
                }
            }
        }
        .sheet(isPresented: $showSyncSettings) { SyncSettingsView(session: session) }
        .sheet(isPresented: $showQuickOpen) { QuickOpenView(session: session) }
        .sheet(isPresented: $showGraph) { GraphView(session: session) }
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

    @State private var hits: [SearchHit] = []
    @State private var renaming: FileNode?
    @State private var renameText = ""
    @State private var deleting: FileNode?

    var body: some View {
        List(selection: $session.selection) {
            if session.sidebarQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Section("Files") {
                    OutlineGroup(session.tree, children: \.children) { node in
                        FileRow(node: node)
                            .contextMenu { menu(for: node) }
                    }
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
                              systemImage: hit.path.hasSuffix(".ink") ? "pencil.tip" : "doc.text")
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
                    Button { session.createNote(kind: .ink) } label: {
                        Label("Handwritten note", systemImage: "pencil.tip")
                    }
                    Button { session.createNote(kind: .markdown) } label: {
                        Label("Text note", systemImage: "doc.text")
                    }
                    Divider()
                    Button { session.createFolder() } label: {
                        Label("Folder", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                } primaryAction: {
                    session.createNote(kind: .platformDefault)
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
            }
        }
        // On iPad the floating Pencil tool picker sits along the bottom edge, so sync lives at the top there.
        .safeAreaInset(edge: SyncBar.edge) {
            SyncBar(session: session, showSyncSettings: $showSyncSettings)
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

    @ViewBuilder
    private func menu(for node: FileNode) -> some View {
        let folder = node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
        Button { session.createNote(kind: .ink, in: folder) } label: {
            Label("New handwritten note here", systemImage: "pencil.tip")
        }
        Button { session.createNote(kind: .markdown, in: folder) } label: {
            Label("New text note here", systemImage: "doc.text")
        }
        Button { session.createFolder(in: folder) } label: {
            Label("New folder here", systemImage: "folder.badge.plus")
        }
        Divider()
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

private struct FileRow: View {
    let node: FileNode

    private var icon: String {
        if node.isDirectory { return "folder" }
        switch node.fileExtension {
        case "ink": return "pencil.tip"
        case "md", "markdown": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        default: return "doc"
        }
    }

    var body: some View {
        Label(node.title, systemImage: icon)
            .lineLimit(1)
    }
}

/// Bottom of the sidebar: sync status, tap to sync now, and the way into sync settings.
private struct SyncBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var session: VaultSession
    @Binding var showSyncSettings: Bool

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
