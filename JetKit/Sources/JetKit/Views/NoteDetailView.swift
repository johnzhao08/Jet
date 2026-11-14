import SwiftUI

/// Picks the right editor for the selected file.
struct NoteDetailView: View {
    let session: VaultSession
    let path: String

    private var ext: String { (path as NSString).pathExtension.lowercased() }
    private var title: String {
        let name = (path as NSString).lastPathComponent
        return [.ink, .markdown].contains(FileKind(path: path)) ? (name as NSString).deletingPathExtension : name
    }

    private var fileSize: Int {
        (try? FileManager.default.attributesOfItem(atPath: session.url(for: path).path)[.size] as? Int) ?? 0
    }

    var body: some View {
        Group {
            switch FileKind(path: path) {
            case .ink:
                InkNoteView(session: session, path: path)
            case .markdown:
                MarkdownNoteView(session: session, path: path)
            case .text where fileSize < 4_000_000:
                PlainTextView(session: session, path: path)
            case .pdf:
                if let pdf = PDFPages(url: session.url(for: path)) {
                    InkNoteView(session: session, path: path, pdf: pdf)
                } else {
                    // Locked or damaged: Quick Look can still show it (and ask for a password).
                    FilePreview(url: session.url(for: path))
                }
            case .image, .text, .other:
                FilePreview(url: session.url(for: path))
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: session.url(for: path)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
            }
        }
        .navigationTitle(title)
        .inlineTitle()
    }
}

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#else
import UIKit
typealias PlatformImage = UIImage
extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#endif
