import SwiftUI

/// Picks the right editor for the selected file.
struct NoteDetailView: View {
    let session: VaultSession
    let path: String

    @State private var history = false
    @State private var properties = false

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
            case .image:
                ImageFileView(session: session, path: path)
            case .text, .other:
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
        .toolbar {
            if VaultSession.noteExtensions.contains(ext) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Version history", systemImage: "clock.arrow.circlepath") { history = true }
                        if FileKind(path: path) == .markdown {
                            Button("Edit properties", systemImage: "list.bullet.rectangle") { properties = true }
                        }
                    } label: { Label("Note actions", systemImage: "doc.badge.ellipsis") }
                }
            }
        }
        .sheet(isPresented: $history) {
            NavigationStack {
                NoteHistoryList(session: session, path: path)
                    .navigationTitle("Version history")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { history = false } } }
            }.sheetSize(width: 600, height: 460)
        }
        .sheet(isPresented: $properties) { PropertyEditorView(session: session, path: path) }
        .navigationTitle(title)
        .inlineTitle()
    }
}

/// An image file, opened as a page to put pictures (and, on iPad, ink) on, like a PDF; the image file
/// itself never changes. Formats ImageIO can't read, like SVG, fall back to Quick Look.
private struct ImageFileView: View {
    let session: VaultSession
    let path: String
    @State private var page: PDFPages?
    @State private var loaded = false

    var body: some View {
        Group {
            if let page {
                InkNoteView(session: session, path: path, pdf: page)
            } else if loaded {
                FilePreview(url: session.url(for: path))
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: session.url(for: path)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
            } else {
                ProgressView()
            }
        }
        .task(id: path) {
            loaded = false
            let url = session.url(for: path)
            // Wrapping a big photo takes a moment: do it off the main thread, once per file.
            page = await Task.detached(priority: .userInitiated) { PDFPages(imageAt: url) }.value
            loaded = true
        }
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
