import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A file or folder being dragged around inside Jet's own sidebar.
    static let jetVaultItem = UTType(exportedAs: "com.johnzhao.jet.vault-item")
}

/// Sidebar rows being dragged: their paths in the open vault (several when you drag a selection).
public struct VaultItem: Codable, Transferable {
    public let paths: [String]
    public init(path: String) { paths = [path] }
    public init(paths: [String]) { self.paths = paths }

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
        provider.suggestedName = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) items"
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

    /// A file another app promises to write once the drop lands (browsers drag web images this way).
    static let promiseTypes: Set<String> = {
        var types: Set<String> = ["com.apple.pasteboard.promised-file-url", "Apple files promise pasteboard type"]
        let legacy = UTTagClass(rawValue: "com.apple.nspboard-type")
        if let dynamic = UTType(tag: "Apple files promise pasteboard type", tagClass: legacy, conformingTo: nil) {
            types.insert(dynamic.identifier)
        }
        return types
    }()

    /// Whether a dragged type is a file's content, as opposed to text, a link or app-private data.
    static func isFileContent(_ identifier: String) -> Bool {
        guard let type = UTType(identifier), !type.isDynamic else { return false }
        return !type.conforms(to: .text) && !type.conforms(to: .url)
            && (type.conforms(to: .data) || type.conforms(to: .content))
    }

    /// Jet's own rows are recognised by their type before anything else, so a row being moved is
    /// never mistaken for a file to import. Dragged text and links aren't files.
    public static func classify(_ providers: [NSItemProvider]) -> Contents {
        classify(types: providers.flatMap(\.registeredTypeIdentifiers))
    }

    /// The same, from type identifiers alone. During a drag, check this rather than asking for item
    /// providers: on the Mac each request for a browser image's providers starts a thread that waits for
    /// the browser to deliver the file, and asking on every mouse move used up every thread and froze Jet.
    public static func classify(types: [String]) -> Contents {
        if types.contains(UTType.jetVaultItem.identifier) { return .vaultItems }
        let files = types.contains { identifier in
            promiseTypes.contains(identifier)
                || UTType(identifier)?.conforms(to: .fileURL) == true
                || isFileContent(identifier)
        }
        return files ? .files : .nothing
    }

    /// Whether a drag holds a picture: image data, a promised file (browsers drag web images that way;
    /// anything that turns out not to be a picture is skipped on drop), or image files from Finder.
    public static func carriesImage(types: [String], fileURLs: [URL]) -> Bool {
        if types.contains(UTType.jetVaultItem.identifier) { return false }
        if types.contains(where: promiseTypes.contains) { return true }
        if types.contains(where: { identifier in
            guard let type = UTType(identifier), !type.isDynamic else { return false }
            return type.conforms(to: .image)
        }) { return true }
        return fileURLs.contains { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    }

    #if os(macOS)
    /// The file URLs on the drag, read from its pasteboard without loading any promised files.
    @MainActor
    static func draggedFileURLs() -> [URL] {
        let urls = NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls ?? []
    }
    #endif

    public static func operation(for providers: [NSItemProvider], into folder: String?) -> DropOperation {
        operation(for: classify(providers), into: folder)
    }

    public static func operation(for contents: Contents, into folder: String?) -> DropOperation {
        switch contents {
        case .vaultItems: return folder == nil ? .forbidden : .move
        case .files: return .copy
        case .nothing: return .forbidden
        }
    }

    /// Picked rows to move or delete together, in `order` (as shown), leaving out any inside a picked
    /// folder: they go with it.
    public static func outermost(_ paths: Set<String>, order: [String]) -> [String] {
        order.filter { path in
            paths.contains(path) && !paths.contains { other in path.hasPrefix(other + "/") }
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
            if let data, let item = try? JSONDecoder().decode(VaultItem.self, from: data) { paths += item.paths }
        }
        return paths
    }

    public static func fileURLs(in providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            #if os(macOS)
            // A browser image carries its web address too, which isn't a file: read the image itself.
            if !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let type = provider.registeredTypeIdentifiers.first(where: isFileContent) {
                if let url = await copyOut(provider, type: type) { urls.append(url) }
                continue
            }
            #endif
            let file: DroppedFile? = await withCheckedContinuation { continuation in
                _ = provider.loadTransferable(type: DroppedFile.self) { continuation.resume(returning: try? $0.get()) }
            }
            if let url = file?.url, url.isFileURL { urls.append(url) }
        }
        return urls
    }

    /// Copies a provider's file out of the system's temporary drop location, which only lasts for the callback.
    static func copyOut(_ provider: NSItemProvider, type: String) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { file, _ in
                guard let file else { return continuation.resume(returning: nil) }
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("JetDrops").appendingPathComponent(UUID().uuidString)
                var name = provider.suggestedName.map { ($0 as NSString).lastPathComponent } ?? file.lastPathComponent
                if (name as NSString).pathExtension.isEmpty, let ext = UTType(type)?.preferredFilenameExtension {
                    name += "." + ext
                }
                let copy = folder.appendingPathComponent(name.isEmpty ? file.lastPathComponent : name)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: file, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
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

    /// Decided from the dragged types only; item providers are loaded once, on the drop.
    private func operation(_ info: DropInfo) -> DropOperation {
        FileDrop.operation(for: FileDrop.classify(types: info.draggedTypes), into: folder)
    }

    func validateDrop(info: DropInfo) -> Bool { operation(info) != .forbidden }

    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: operation(info)) }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info) else { return false }
        return FileDrop.handle(info.itemProviders(for: FileDrop.acceptedTypes), app: app, into: folder)
    }
}

extension DropInfo {
    /// The dragged types, read without loading anything.
    var draggedTypes: [String] {
        #if os(macOS)
        NSPasteboard(name: .drag).types?.map(\.rawValue) ?? []
        #else
        itemProviders(for: FileDrop.acceptedTypes).flatMap(\.registeredTypeIdentifiers)
        #endif
    }
}

extension View {
    /// Takes drag feedback (an insertion line, a highlighted target) down once the mouse button is up.
    /// SwiftUI doesn't always tell a drop target that the drag left (a drop on a different target, or
    /// rows rebuilt during the drag), which left the line on screen after the drop.
    func clearsWhenDragEnds<T>(_ feedback: Binding<T?>) -> some View {
        clearsWhenDragEnds(active: feedback.wrappedValue != nil) { feedback.wrappedValue = nil }
    }

    func clearsWhenDragEnds(_ feedback: Binding<Bool>) -> some View {
        clearsWhenDragEnds(active: feedback.wrappedValue) { feedback.wrappedValue = false }
    }

    private func clearsWhenDragEnds(active: Bool, clear: @escaping () -> Void) -> some View {
        #if os(macOS)
        task(id: active) {
            guard active else { return }
            // While dragging, the button is held; the drag ends (dropped or cancelled) when it's let go.
            while NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(120))
                if Task.isCancelled { return }
            }
            clear()
        }
        #else
        self
        #endif
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
