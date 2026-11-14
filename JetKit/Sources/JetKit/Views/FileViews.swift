import SwiftUI
import QuickLook

/// Text files that aren't Markdown (.txt, .csv, .json, code…): edited as they are, saved like notes.
struct PlainTextView: View {
    let session: VaultSession
    let path: String

    @State private var model: MarkdownNoteModel
    @State private var editorID: UUID?

    init(session: VaultSession, path: String) {
        self.session = session
        self.path = path
        _model = State(initialValue: MarkdownNoteModel(url: session.url(for: path)))
    }

    var body: some View {
        @Bindable var model = model
        TextEditor(text: $model.text)
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: session.url(for: path)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .onAppear {
                model.onWrite = { session.didWriteFile() }
                editorID = session.registerEditor { model.saveNow() }
            }
            .onDisappear {
                model.saveNow()
                session.unregisterEditor(editorID)
            }
            .onChange(of: session.contentVersion) { model.reloadIfChangedOnDisk() }
    }
}

#if os(iOS)
/// Quick Look, for pictures, Office and iWork documents, audio, video, web pages, 3D models and more.
struct FilePreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            controller.reloadData()
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
#else
import Quartz

/// Quick Look, for pictures, Office and iWork documents, audio, video, web pages, 3D models and more.
struct FilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
#endif
