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
    /// For List rows, which drag through an item provider (on iPad, `.draggable` rows don't start a drag).
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

/// Something dropped on Jet: a row from its own sidebar (to move), or a file from Finder, the Files
/// app or another app (to open or import).
public enum DroppedItem: Transferable {
    case vaultItem(String)
    case file(URL)

    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (item: VaultItem) in DroppedItem.vaultItem(item.path) })
        #if os(macOS)
        // Finder drags carry the file's URL: use the original file where it is.
        ProxyRepresentation(importing: { (url: URL) in DroppedItem.file(url) })
        #endif
        // Finder hands over the original file (so files already in a vault open in place); the Files
        // app and other apps hand over a copy that's only valid in here, so it's copied out first.
        FileRepresentation(importedContentType: .item, shouldAttemptToOpenInPlace: true) { received in
            if received.isOriginalFile { return .file(received.file) }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("JetDrops").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return .file(copy)
        }
    }
}

extension AppModel {
    /// Handles a drop: sidebar rows move into `folder` (when dropped on a folder), files are opened or
    /// imported (into `folder` if given).
    func handleDrop(_ items: [DroppedItem], into folder: String?) -> Bool {
        var files: [URL] = []
        var moved = false
        for item in items {
            switch item {
            case .vaultItem(let path):
                if let folder, let session { moved = session.move(path, into: folder) != nil || moved }
            case .file(let url):
                files.append(url)
            }
        }
        if !files.isEmpty { receive(files, into: folder) }
        return moved || !files.isEmpty
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
        if !tooLarge.isEmpty {
            parts.append("Over 100 MB, so they can't be synced with git and won't be imported: \(list(tooLarge)).")
        }
        if !large.isEmpty {
            parts.append("Large files make every device's sync slower and the vault's history bigger for good, even after they're deleted: \(list(large)).")
        }
        return parts.joined(separator: "\n\n")
    }
}
