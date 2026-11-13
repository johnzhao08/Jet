import SwiftUI

/// Picks the right editor for the selected file.
struct NoteDetailView: View {
    let session: VaultSession
    let path: String

    private var ext: String { (path as NSString).pathExtension.lowercased() }
    private var title: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    var body: some View {
        Group {
            switch ext {
            case "ink":
                InkNoteView(session: session, path: path)
            case "md", "markdown", "txt":
                MarkdownNoteView(session: session, path: path)
            case "png", "jpg", "jpeg", "gif", "heic", "webp":
                ScrollView([.vertical, .horizontal]) {
                    if let image = PlatformImage(contentsOfFile: session.url(for: path).path) {
                        Image(platformImage: image)
                    }
                }
            default:
                ContentUnavailableView(
                    "Can't open this file",
                    systemImage: "doc.questionmark",
                    description: Text("Jet opens Markdown (.md), handwritten (.ink) and image files.")
                )
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
