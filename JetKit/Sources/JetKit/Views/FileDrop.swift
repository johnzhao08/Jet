import SwiftUI
import UniformTypeIdentifiers

/// Files dragged onto Jet: from Finder (as file URLs) or from the Files app and other iPad apps (as
/// file representations, copied to a temporary folder first because the system deletes its copy).
enum FileDrop {
    static let types: [UTType] = [.fileURL, .item]

    /// Reads the dropped files and hands their URLs to `receive` on the main actor. Returns false when
    /// nothing in the drop is a file.
    static func handle(_ providers: [NSItemProvider], receive: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || isFileLike($0) }
        guard !files.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in files {
                if let url = await load(provider) { urls.append(url) }
            }
            if !urls.isEmpty { await receive(urls) }
        }
        return true
    }

    /// Plain dragged text or a link isn't a file to import.
    private static func isFileLike(_ provider: NSItemProvider) -> Bool {
        provider.registeredTypeIdentifiers.contains { identifier in
            guard let type = UTType(identifier) else { return false }
            return !type.conforms(to: .text) && !type.conforms(to: .url) && (type.conforms(to: .data) || type.conforms(to: .content))
        }
    }

    private static func load(_ provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            if let url, url.isFileURL { return url }
        }
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0).map { !$0.conforms(to: .text) } ?? false })
                ?? provider.registeredTypeIdentifiers.first else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                // Only valid inside this callback: keep a copy under the name the drag suggested.
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("JetDrops").appendingPathComponent(UUID().uuidString)
                var name = url.lastPathComponent
                if let suggested = provider.suggestedName, !suggested.isEmpty {
                    name = (suggested as NSString).pathExtension.isEmpty && !url.pathExtension.isEmpty
                        ? suggested + "." + url.pathExtension : suggested
                }
                let copy = folder.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
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
