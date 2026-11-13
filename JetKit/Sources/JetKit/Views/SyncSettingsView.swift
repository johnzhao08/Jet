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

    private var matches: [FileNode] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let notes = session.allNotes
        guard !needle.isEmpty else { return Array(notes.prefix(50)) }
        return Array(notes.filter { $0.path.localizedCaseInsensitiveContains(needle) }.prefix(50))
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Open note…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($focused)
                .onSubmit {
                    if let first = matches.first { open(first) }
                }
            Divider()
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
