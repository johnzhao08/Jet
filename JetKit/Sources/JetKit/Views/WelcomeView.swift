import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Vault picker shown when no vault is open.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var showCreate = false
    @State private var showClone = false
    @State private var vaultToRemove: VaultRef?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Jet").font(.largeTitle.bold())
                        Text("Notes in plain files, synced with git.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                if !app.vaults.isEmpty {
                    Section("Vaults") {
                        ForEach(app.vaults) { vault in
                            let missing = !FileManager.default.fileExists(atPath: vault.url.path)
                            Button {
                                app.open(vault)
                            } label: {
                                HStack {
                                    Label(vault.name, systemImage: "books.vertical")
                                    Spacer()
                                    if missing {
                                        Text("Folder missing").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(missing)
                            .contextMenu {
                                Button("Remove…", role: .destructive) { vaultToRemove = vault }
                            }
                            .swipeActions {
                                Button("Remove", role: .destructive) { vaultToRemove = vault }
                            }
                        }
                    }
                }

                Section {
                    Button { showClone = true } label: {
                        Label("Clone a vault from git", systemImage: "arrow.down.circle")
                    }
                    Button { showCreate = true } label: {
                        Label("Create a new vault", systemImage: "plus.circle")
                    }
                    #if os(macOS)
                    Button(action: openFolder) {
                        Label("Open an existing folder", systemImage: "folder")
                    }
                    #endif
                }
            }
            .navigationTitle("Vaults")
            .inlineTitle()
        }
        .sheet(isPresented: $showCreate) { CreateVaultSheet() }
        .sheet(isPresented: $showClone) { CloneVaultSheet() }
        .confirmationDialog(
            "Remove “\(vaultToRemove?.name ?? "")”?",
            isPresented: Binding(get: { vaultToRemove != nil }, set: { if !$0 { vaultToRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove from list") {
                if let vault = vaultToRemove { app.forget(vault, deleteFiles: false) }
            }
            Button("Delete files on this device", role: .destructive) {
                if let vault = vaultToRemove { app.forget(vault, deleteFiles: true) }
            }
        } message: {
            Text("Deleting files cannot be undone. Anything not yet synced is lost.")
        }
    }

    #if os(macOS)
    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Open as Vault"
        if panel.runModal() == .OK, let url = panel.url {
            app.addExistingFolder(url)
        }
    }
    #endif
}

private struct CreateVaultSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Notes"
    @State private var error: String?

    private static var locationDescription: String {
        #if os(iOS)
        "Jet's folder in the Files app"
        #else
        AppModel.vaultsDirectory.path
        #endif
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Vault name", text: $name)
                } footer: {
                    Text("Created in \(Self.locationDescription). You can connect a git remote afterwards in Sync settings.")
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New vault")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        do {
                            try app.createVault(name: name)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .sheetSize(width: 440, height: 260)
    }
}

private struct CloneVaultSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var remote = ""
    @State private var name = ""
    @State private var username = ""
    @State private var token = ""
    @State private var error: String?
    @State private var working = false

    private var derivedName: String {
        let last = remote.trimmingCharacters(in: .whitespaces).split(separator: "/").last.map(String.init) ?? ""
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://github.com/you/notes.git", text: $remote)
                        .literalInput()
                    TextField(derivedName.isEmpty ? "Vault name" : derivedName, text: $name)
                } header: {
                    Text("Repository")
                }
                Section {
                    TextField("Username", text: $username)
                        .literalInput()
                    SecureField("Access token", text: $token)
                } header: {
                    Text("Sign in")
                } footer: {
                    Text("Use an HTTPS URL with a personal access token that can read and write the repository. The token is stored in the keychain on this device. SSH URLs are not supported.")
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Clone vault")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Clone", action: clone)
                            .disabled(remote.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .disabled(working)
        }
        .sheetSize(width: 480, height: 420)
    }

    private func clone() {
        working = true
        error = nil
        Task {
            do {
                try await app.cloneVault(
                    remote: remote,
                    name: name.isEmpty ? derivedName : name,
                    username: username,
                    token: token
                )
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
