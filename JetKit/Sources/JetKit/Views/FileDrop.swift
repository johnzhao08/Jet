import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A file or folder being dragged around inside Jet's own sidebar.
    static let jetVaultItem = UTType(exportedAs: "com.johnzhao.jet.vault-item")
}

/// A sidebar row being dragged: its path in the open vault.
public struct VaultItem: Codable, Transferable {
    public let path: String
    public init(path: String) { self.path = path }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .jetVaultItem)
    }
}

extension VaultItem {
    /// The private representation keeps sidebar moves distinct from external file imports.
    public var itemProvider: NSItemProvider {
        let provider = NSItemProvider()
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.jetVaultItem.identifier, visibility: .ownProcess) { done in
            done(data, nil)
            return nil
        }
        provider.suggestedName = (path as NSString).lastPathComponent
        return provider
    }
}

/// A file dropped on Jet from Finder, the Files app or another app.
public struct DroppedFile: Transferable {
    public let url: URL

    public static var transferRepresentation: some TransferRepresentation {
        #if os(macOS)
        // Finder drags carry the file's URL: use the original file where it is.
        ProxyRepresentation(importing: { (url: URL) in DroppedFile(url: url) })
        #endif
        // The Files app and other apps hand over a copy that's only valid in here, so copy it out.
        FileRepresentation(importedContentType: .item, shouldAttemptToOpenInPlace: true) { received in
            if received.isOriginalFile { return DroppedFile(url: received.file) }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("JetDrops").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return DroppedFile(url: copy)
        }
    }
}

/// What a drop on Jet is: rows dragged within its own sidebar (to move), or files from elsewhere.
public enum FileDrop {
    static let acceptedTypes: [UTType] = [.jetVaultItem, .fileURL, .item]

    public enum Contents: Equatable {
        case vaultItems
        case files
        case nothing
    }

    /// Jet's own rows are recognised by their type before anything else, so a row being moved is
    /// never mistaken for a file to import. Dragged text and links aren't files.
    public static func classify(_ providers: [NSItemProvider]) -> Contents {
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.jetVaultItem.identifier) }) {
            return .vaultItems
        }
        let files = providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || provider.registeredTypeIdentifiers.contains { identifier in
                    guard let type = UTType(identifier) else { return false }
                    return !type.conforms(to: .text) && !type.conforms(to: .url)
                        && (type.conforms(to: .data) || type.conforms(to: .content))
                }
        }
        return files ? .files : .nothing
    }

    public static func operation(for providers: [NSItemProvider], into folder: String?) -> DropOperation {
        switch classify(providers) {
        case .vaultItems: return folder == nil ? .forbidden : .move
        case .files: return .copy
        case .nothing: return .forbidden
        }
    }

    /// The paths of dragged sidebar rows.
    public static func vaultPaths(in providers: [NSItemProvider]) async -> [String] {
        var paths: [String] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.jetVaultItem.identifier) {
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.jetVaultItem.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            if let data, let item = try? JSONDecoder().decode(VaultItem.self, from: data) { paths.append(item.path) }
        }
        return paths
    }

    public static func fileURLs(in providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let file: DroppedFile? = await withCheckedContinuation { continuation in
                _ = provider.loadTransferable(type: DroppedFile.self) { continuation.resume(returning: try? $0.get()) }
            }
            if let url = file?.url, url.isFileURL { urls.append(url) }
        }
        return urls
    }

    /// Handles a drop on the window (`folder` nil) or on a folder: rows move into the folder (rows
    /// dropped elsewhere stay put); files are opened or imported.
    @MainActor
    static func handle(_ providers: [NSItemProvider], app: AppModel, into folder: String?) -> Bool {
        switch classify(providers) {
        case .vaultItems:
            guard let folder, let session = app.session else { return false }
            Task { @MainActor in
                for path in await vaultPaths(in: providers) { session.move(path, into: folder) }
            }
            return true
        case .files:
            Task { @MainActor in
                let urls = await fileURLs(in: providers)
                if !urls.isEmpty { app.receive(urls, into: folder) }
            }
            return true
        case .nothing:
            return false
        }
    }
}

/// Explicit proposals give internal drags a move cursor and keep them off the window import target.
struct FileDropTarget: DropDelegate {
    let app: AppModel
    let folder: String?
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        FileDrop.operation(for: info.itemProviders(for: FileDrop.acceptedTypes), into: folder) != .forbidden
    }

    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: FileDrop.operation(for: info.itemProviders(for: FileDrop.acceptedTypes), into: folder))
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info) else { return false }
        return FileDrop.handle(info.itemProviders(for: FileDrop.acceptedTypes), app: app, into: folder)
    }
}

/// Files the Mac asked Jet to open (Finder, the Dock icon) before or after the window was ready.
@MainActor
final class OpenRequests {
    static let shared = OpenRequests()
    private var pending: [URL] = []
    var handler: (([URL]) -> Void)? {
        didSet {
            guard let handler, !pending.isEmpty else { return }
            let urls = pending
            pending = []
            handler(urls)
        }
    }

    func deliver(_ urls: [URL]) {
        if let handler { handler(urls) } else { pending += urls }
    }
}

extension VaultSession.ImportReview {
    var message: String {
        func list(_ items: [(url: URL, size: Int)]) -> String {
            items.map { "\($0.url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file)))" }
                .joined(separator: ", ")
        }
        var parts: [String] = []
        if !refused.isEmpty {
            parts.append(refused.map { "Not imported: \($0.url.lastPathComponent), because \($0.reason)." }.joined(separator: "\n"))
        }
        if !tooLarge.isEmpty {
            parts.append("Over 100 MB, so they can't be synced with git and won't be imported: \(list(tooLarge)).")
        }
        if !large.isEmpty {
            parts.append("Large files make every device's sync slower and the vault's history bigger for good, even after they're deleted: \(list(large)).")
        }
        return parts.joined(separator: "\n\n")
    }
}
