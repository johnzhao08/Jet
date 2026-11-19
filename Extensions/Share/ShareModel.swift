import SwiftUI
import UniformTypeIdentifiers
import JetCapture

/// What the share sheet received, and the choices made about it. Nothing here touches a vault: Save
/// leaves a capture in the shared inbox for the app to file.
@MainActor
final class ShareModel: ObservableObject {
    @Published var title = ""
    @Published var text = ""
    @Published var link: String?
    @Published var destination = CaptureItem.Destination.inbox
    @Published var vaultID: UUID?
    @Published private(set) var files: [Staged] = []
    @Published private(set) var skipped: [String] = []
    @Published private(set) var isLoading = true
    @Published var errorMessage: String?

    let directory = VaultDirectory.load()
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("JetShare-\(UUID().uuidString)", isDirectory: true)

    struct Staged: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let isImage: Bool
    }

    init() { vaultID = directory.current ?? directory.vaults.first?.id }

    deinit { try? FileManager.default.removeItem(at: scratch) }

    var canSave: Bool { !isLoading && (!text.trimmed.isEmpty || link != nil || !files.isEmpty) }

    // MARK: Reading what was shared

    func load(_ items: [NSExtensionItem]) async {
        defer { isLoading = false }
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var pageTitle = ""
        var texts: [String] = []
        for item in items {
            if pageTitle.isEmpty {
                pageTitle = (item.attributedTitle?.string ?? item.attributedContentText?.string ?? "").trimmed
            }
            for provider in item.attachments ?? [] {
                if files.count >= CaptureLimits.mostAttachments { skipped.append("more than \(CaptureLimits.mostAttachments) files"); break }
                await read(provider, texts: &texts)
            }
        }
        text = texts.joined(separator: "\n\n")
        // A shared page carries its title; text shared on its own gets one from the app.
        if title.isEmpty, link != nil || !files.isEmpty { title = String(pageTitle.prefix(120)) }
        if text.trimmed == pageTitle { text = "" }
    }

    private func read(_ provider: NSItemProvider, texts: inout [String]) async {
        // Pictures and documents first: sharing a photo can also offer a file URL or text.
        if let type = [UTType.image, .pdf, .movie, .audio].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
            await stage(provider, type: type)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            await stageFileURL(provider)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadURL(provider) {
                if url.isFileURL { await stage(provider, type: .data) } else if link == nil { link = url.absoluteString } else { texts.append(url.absoluteString) }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                    || provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            if let string = await loadString(provider)?.trimmed, !string.isEmpty {
                // Text that is really just a link is a link.
                if link == nil, !string.contains(where: \.isWhitespace), let url = URL(string: string), url.scheme?.hasPrefix("http") == true {
                    link = string
                } else {
                    texts.append(string)
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            await stage(provider, type: .data)
        }
    }

    private func loadURL(_ provider: NSItemProvider) async -> URL? {
        let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
        return (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:))
    }

    private func loadString(_ provider: NSItemProvider) async -> String? {
        for type in [UTType.plainText, .text] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let value = try? await provider.loadItem(forTypeIdentifier: type.identifier)
            if let string = value as? String { return string }
            if let attributed = value as? NSAttributedString { return attributed.string }
            if let data = value as? Data, let string = String(data: data, encoding: .utf8) { return string }
        }
        return nil
    }

    private func stageFileURL(_ provider: NSItemProvider) async {
        // Files app and other apps hand over a file URL; copy it out at once, while access is granted.
        guard let url = (try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)) as? URL else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        add(copying: url, suggestedName: url.lastPathComponent)
    }

    /// Asks the provider for a file (the system copies large ones to disk rather than memory) and keeps
    /// a copy in the scratch folder, because the provider's file is deleted when the handler returns.
    private func stage(_ provider: NSItemProvider, type: UTType) async {
        let identifier = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: type) == true } ?? type.identifier
        let name = provider.suggestedName
        let copy: (url: URL, name: String)? = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let folder = self.scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
                var fileName = url.lastPathComponent
                if let name, !name.isEmpty {
                    let ext = url.pathExtension
                    fileName = ext.isEmpty || name.lowercased().hasSuffix("." + ext.lowercased()) ? name : name + "." + ext
                }
                let target = folder.appendingPathComponent(CaptureNaming.fileName(fileName) ?? "File")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: (target, target.lastPathComponent))
                } catch { continuation.resume(returning: nil) }
            }
        }
        guard let copy else { skipped.append(name ?? "an item"); return }
        register(copy.url, name: copy.name)
    }

    private func add(copying source: URL, suggestedName: String) {
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory != true, values?.isSymbolicLink != true else { skipped.append("\(suggestedName) (folders can't be shared)"); return }
        let folder = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = folder.appendingPathComponent(CaptureNaming.fileName(suggestedName) ?? "File")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: target)
            register(target, name: target.lastPathComponent)
        } catch { skipped.append(suggestedName) }
    }

    private func register(_ url: URL, name: String) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= CaptureLimits.largestAttachment else {
            skipped.append("\(name) (over 100 MB)")
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            return
        }
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        files.append(Staged(url: url, name: name, isImage: isImage))
    }

    func remove(_ file: Staged) { files.removeAll { $0.id == file.id } }

    // MARK: Saving

    /// Leaves the capture in the shared inbox. Throws if the inbox can't be reached or a file is refused.
    func save() throws {
        guard let inbox = CaptureInbox.shared else { throw CaptureInbox.Failure.unavailable }
        let item = CaptureItem(destination: destination, vaultID: vaultID, title: title.trimmed, text: text.trimmed,
                               link: link, origin: "Share Sheet")
        try inbox.enqueue(item, files: files.map(\.url))
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
