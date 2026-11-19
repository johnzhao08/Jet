import SwiftUI

struct SyncSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: VaultSession

    @State private var remote = ""
    @State private var username = ""
    @State private var token = ""
    @State private var authorName = ""
    @State private var authorEmail = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://github.com/you/notes.git", text: $remote)
                        .literalInput()
                } header: {
                    Text("Remote repository")
                } footer: {
                    Text("HTTPS only. An empty repository is fine; the first sync pushes this vault into it.")
                }

                Section {
                    TextField("Username", text: $username)
                        .literalInput()
                    SecureField("Access token", text: $token)
                } header: {
                    Text("Sign in")
                } footer: {
                    Text("A personal access token with read and write access to the repository. Stored in this device's keychain.")
                }

                Section("Commits are signed as") {
                    TextField("Name", text: $authorName)
                    TextField("Email", text: $authorEmail)
                        .literalInput()
                }

                Section {
                    Toggle("Sync automatically", isOn: $session.autoSync)
                } footer: {
                    Text("Syncs when the vault opens, about a minute after you stop editing, and when you leave the app. With this off, sync only runs when you tap the sync button.")
                }

                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Sync settings")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save and sync", action: save) }
            }
        }
        .sheetSize(width: 480, height: 520)
        .onAppear {
            remote = session.remoteURL
            username = session.username
            token = session.token
            authorName = app.authorName
            authorEmail = app.authorEmail
        }
    }

    private func save() {
        let url = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasPrefix("git@") || url.hasPrefix("ssh://") {
            error = "SSH URLs are not supported. Use the repository's HTTPS URL."
            return
        }
        do {
            try session.setRemote(url)
        } catch {
            self.error = error.localizedDescription
            return
        }
        session.username = username
        session.token = token
        if !authorName.isEmpty { app.authorName = authorName }
        if !authorEmail.isEmpty { app.authorEmail = authorEmail }
        dismiss()
        if session.hasRemote {
            Task { await session.sync(author: GitAuthor(name: app.authorName, email: app.authorEmail)) }
        }
    }
}

struct QuickOpenView: View {
    @Environment(\.dismiss) private var dismiss
    let session: VaultSession
    @State private var query = ""
    @FocusState private var focused: Bool

    private var needle: String { query.trimmingCharacters(in: .whitespaces) }

    /// Notes ranked by how well their title (or an alias, or the folder path) matches; letters in order also count.
    private var matches: [FileNode] {
        let notes = session.allNotes
        guard !needle.isEmpty else {
            let byPath = Dictionary(uniqueKeysWithValues: notes.map { ($0.path, $0) })
            let recent = session.recentNotes.compactMap { byPath[$0] }
            let seen = Set(recent.map(\.path))
            return Array((recent + notes.filter { !seen.contains($0.path) }).prefix(50))
        }
        let scored = notes.compactMap { node -> (FileNode, Int)? in
            let names = [node.title] + (session.index.noteAliases[node.path] ?? [])
            let score = names.map { Self.score(needle, in: $0) }.max() ?? 0
            let best = max(score, Self.score(needle, in: node.path) - 1)
            return best > 0 ? (node, best) : nil
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title.count < $1.0.title.count }
            .prefix(50).map(\.0)
    }

    static func score(_ needle: String, in name: String) -> Int {
        let needle = needle.lowercased(), name = name.lowercased()
        if name == needle { return 5 }
        if name.hasPrefix(needle) { return 4 }
        if name.contains(needle) { return 3 }
        var rest = Substring(name)
        for character in needle {
            guard let found = rest.firstIndex(of: character) else { return 0 }
            rest = rest[rest.index(after: found)...]
        }
        return 2
    }

    /// Offer to create the note when nothing has exactly this name, like following a new `[[link]]`.
    private var canCreate: Bool {
        !needle.isEmpty && session.path(forTitle: needle) == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Open or create a note…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($focused)
                .onSubmit {
                    if let first = matches.first { open(first) } else if canCreate { create() }
                }
            Divider()
            if canCreate {
                Button(action: create) {
                    Label("Create “\(needle)”", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .keyboardShortcut(.return, modifiers: .shift)
                .help("Shift-Return")
                Divider()
            }
            List(matches) { node in
                Button { open(node) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Label(node.title, systemImage: node.fileExtension == "ink" ? "pencil.tip" : "doc.text")
                        let folder = (node.path as NSString).deletingLastPathComponent
                        if !folder.isEmpty {
                            Text(folder).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .sheetSize(width: 520, height: 420)
        .onAppear { focused = true }
    }

    private func open(_ node: FileNode) {
        session.selection = node.path
        dismiss()
    }

    private func create() {
        session.createNote(kind: .markdown, named: needle.replacingOccurrences(of: "/", with: "-"))
        dismiss()
    }
}

extension View {
    /// Sheets size themselves on iPad; on the Mac they need explicit dimensions.
    func sheetSize(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        self.frame(width: width, height: height)
        #else
        self
        #endif
    }
}
