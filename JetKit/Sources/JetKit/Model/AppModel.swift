import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// A vault the app knows about. `location` is a folder name inside the app's Documents on iPad
/// (the container path changes between launches) and an absolute path on the Mac.
public struct VaultRef: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var location: String

    public init(id: UUID = UUID(), name: String, location: String) {
        self.id = id
        self.name = name
        self.location = location
    }

    public var url: URL {
        #if os(macOS)
        URL(fileURLWithPath: location)
        #else
        AppModel.vaultsDirectory.appendingPathComponent(location)
        #endif
    }
}

@MainActor
@Observable
public final class AppModel {
    public var vaults: [VaultRef] = []
    public var session: VaultSession?
    /// Files handed to Jet by another app before a vault was open; imported once one is.
    public var pendingImports: [URL] = []

    private static let vaultsKey = "jet.vaults"
    private static let lastVaultKey = "jet.lastVault"

    public init() {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["JET_UI_TEST_VAULT"], let id = UUID(uuidString: value) {
            let name = "JetUITest-\(id.uuidString)"
            #if os(macOS)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            let ref = VaultRef(id: id, name: name, location: root.path)
            #else
            let ref = VaultRef(id: id, name: name, location: name)
            let root = ref.url
            #endif
            do {
                if !FileManager.default.fileExists(atPath: root.path) {
                    try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
                    try "# Root\n".write(to: root.appendingPathComponent("Root.md"), atomically: true, encoding: .utf8)
                    try "# Nested\n".write(to: root.appendingPathComponent("Folder/Nested.md"), atomically: true, encoding: .utf8)
                }
                vaults = [ref]
                session = VaultSession(ref: ref)
            } catch { fatalError("Could not create UI test vault: \(error)") }
            return
        }
        #endif
        if let data = UserDefaults.standard.data(forKey: Self.vaultsKey),
           let saved = try? JSONDecoder().decode([VaultRef].self, from: data) {
            vaults = saved
        }
        if let last = UserDefaults.standard.string(forKey: Self.lastVaultKey),
           let ref = vaults.first(where: { $0.id.uuidString == last }),
           FileManager.default.fileExists(atPath: ref.url.path) {
            session = VaultSession(ref: ref)
        }
    }

    /// Files opened in Jet from elsewhere: Finder (Open With, a double-click, the Dock icon), another
    /// app's share sheet or "Open in", or dropped on the window. A file that's already in one of your
    /// vaults opens right there (switching vault if needed); anything else is copied into the open
    /// vault, into `folder` if given.
    public func receive(_ urls: [URL], into folder: String? = nil) {
        var outside: [URL] = []
        var opened = false
        for url in urls where url.isFileURL {
            if let folder, let session, let (ref, path) = locate(url), ref.id == session.ref.id {
                // Already in this vault and dropped on a folder: that's a move.
                session.move(path, into: folder)
                opened = true
            } else if !opened, let (ref, path) = locate(url) {
                if session?.ref.id != ref.id { open(ref) }
                session?.refreshTree()
                session?.selection = path
                opened = true
            } else if locate(url) == nil {
                outside.append(url)
            }
        }
        guard !outside.isEmpty else { return }
        if let session {
            session.requestImport(outside, into: folder)
        } else {
            pendingImports += outside
        }
    }

    public func receive(_ url: URL) { receive([url]) }

    /// The vault holding `url` and its path inside it, if it's in one of the vaults Jet knows.
    public func locate(_ url: URL) -> (VaultRef, String)? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        for ref in vaults {
            let root = ref.url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(root + "/") else { continue }
            let relative = String(path.dropFirst(root.count + 1))
            // Hidden things (.git, a PDF's annotations) aren't opened as notes.
            guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
            return (ref, relative)
        }
        return nil
    }

    public func importPending() {
        guard let session, !pendingImports.isEmpty else { return }
        let urls = pendingImports
        pendingImports = []
        session.requestImport(urls)
    }

    /// iPadOS sometimes hands over a copy in Documents/Inbox; once imported it's just clutter.
    private static func removeInboxCopy(_ url: URL) {
        let inbox = vaultsDirectory.appendingPathComponent("Inbox").standardizedFileURL.path
        if url.standardizedFileURL.path.hasPrefix(inbox + "/") { try? FileManager.default.removeItem(at: url) }
    }

    /// Where new vaults are created.
    public nonisolated static var vaultsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        return documents.appendingPathComponent("Jet")
        #else
        return documents
        #endif
    }

    public static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    public var authorName: String {
        get { UserDefaults.standard.string(forKey: "jet.authorName") ?? Self.deviceName }
        set { UserDefaults.standard.set(newValue, forKey: "jet.authorName") }
    }

    public var authorEmail: String {
        get { UserDefaults.standard.string(forKey: "jet.authorEmail") ?? "jet@localhost" }
        set { UserDefaults.standard.set(newValue, forKey: "jet.authorEmail") }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(vaults) {
            UserDefaults.standard.set(data, forKey: Self.vaultsKey)
        }
    }

    private func freshFolder(named name: String) throws -> URL {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty, !clean.hasPrefix(".") else { throw JetError("Give the vault a name.") }
        let url = Self.vaultsDirectory.appendingPathComponent(clean)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw JetError("A folder named “\(clean)” already exists.")
        }
        try FileManager.default.createDirectory(at: Self.vaultsDirectory, withIntermediateDirectories: true)
        return url
    }

    private func register(name: String, url: URL) -> VaultRef {
        #if os(macOS)
        let ref = VaultRef(name: name, location: url.path)
        #else
        let ref = VaultRef(name: name, location: url.lastPathComponent)
        #endif
        vaults.append(ref)
        persist()
        return ref
    }

    public func createVault(name: String) throws {
        let url = try freshFolder(named: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try ".DS_Store\n".write(to: url.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try Self.welcomeNote.write(to: url.appendingPathComponent("Welcome.md"), atomically: true, encoding: .utf8)
        _ = try GitRepository.create(at: url.path)
        open(register(name: url.lastPathComponent, url: url))
    }

    public func cloneVault(remote: String, name: String, username: String, token: String) async throws {
        let url = try freshFolder(named: name)
        let credentials = token.isEmpty ? nil : GitCredentials(username: username.isEmpty ? "git" : username, password: token)
        let path = url.path
        let remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await Task.detached(priority: .userInitiated) {
                _ = try GitRepository.clone(from: remote, to: path, credentials: credentials)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        let ref = register(name: url.lastPathComponent, url: url)
        Keychain.set(token, for: ref.id.uuidString)
        UserDefaults.standard.set(username, forKey: "vault.\(ref.id.uuidString).username")
        open(ref)
    }

    /// Mac only: use any folder (an existing Obsidian vault, a git checkout) as a vault.
    public func addExistingFolder(_ url: URL) {
        if let existing = vaults.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            open(existing)
        } else {
            open(register(name: url.lastPathComponent, url: url))
        }
    }

    public func open(_ ref: VaultRef) {
        guard FileManager.default.fileExists(atPath: ref.url.path) else { return }
        session = VaultSession(ref: ref)
        UserDefaults.standard.set(ref.id.uuidString, forKey: Self.lastVaultKey)
    }

    public func closeVault() {
        session?.flushEditors()
        session = nil
        UserDefaults.standard.removeObject(forKey: Self.lastVaultKey)
    }

    /// Removes the vault from the list. Files are only deleted when asked.
    public func forget(_ ref: VaultRef, deleteFiles: Bool) {
        if session?.ref.id == ref.id { closeVault() }
        vaults.removeAll { $0.id == ref.id }
        persist()
        Keychain.set("", for: ref.id.uuidString)
        if deleteFiles { try? FileManager.default.removeItem(at: ref.url) }
    }

    private static let welcomeNote = """
    # Welcome to Jet

    Jet keeps your notes as plain files in a folder, and syncs that folder with **git**.

    - Text notes are Markdown (`.md`). Link notes with `[[Note name]]`.
    - Handwritten notes (`.ink`) open straight into drawing on iPad.
    - Embed a handwritten note in a text note with `![[Sketch.ink]]`.

    ## Sync

    - [ ] Open **Sync settings** (bottom of the sidebar)
    - [ ] Paste the HTTPS URL of a git repository and an access token
    - [ ] Clone the same repository on your other device

    """
}

public struct JetError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
