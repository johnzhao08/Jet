import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Which picker an "Insert picture" menu asked for.
enum ImageSource: Identifiable {
    case photos, files
    var id: Self { self }
}

extension View {
    /// Presents the photo library or a file picker for `source`, saves what was picked in the vault's
    /// `Attachments/` folder, and hands each saved picture's path and pixel size to `insert`.
    func imageInsertion(_ source: Binding<ImageSource?>, session: VaultSession,
                        insert: @escaping (_ path: String, _ pixels: CGSize) -> Void) -> some View {
        modifier(ImageInsertion(source: source, session: session, insert: insert))
    }
}

private struct ImageInsertion: ViewModifier {
    @Binding var source: ImageSource?
    let session: VaultSession
    let insert: (String, CGSize) -> Void

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var failed = false

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: Binding(get: { source == .photos }, set: { if !$0, source == .photos { source = nil } }),
                selection: $photoItems,
                maxSelectionCount: 10,
                matching: .images
            )
            .fileImporter(
                isPresented: Binding(get: { source == .files }, set: { if !$0, source == .files { source = nil } }),
                allowedContentTypes: [.image],
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result else { return }
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url) else { failed = true; continue }
                    save(data, type: UTType(filenameExtension: url.pathExtension), name: url.deletingPathExtension().lastPathComponent)
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task {
                    for item in items {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { failed = true; continue }
                        save(data, type: item.supportedContentTypes.first, name: nil)
                    }
                }
            }
            .alert("Couldn't add that picture", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Jet couldn't read it as an image.")
            }
    }

    private func save(_ data: Data, type: UTType?, name: String?) {
        guard let path = session.addImage(data, type: type, named: name) else {
            failed = true
            return
        }
        insert(path, ImageFiles.pixelSize(of: session.url(for: path)) ?? CGSize(width: 800, height: 600))
    }
}

/// The items of an "Insert picture" menu.
struct ImageSourceButtons: View {
    @Binding var source: ImageSource?

    var body: some View {
        Button { source = .photos } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
        Button { source = .files } label: { Label("Choose File…", systemImage: "folder") }
    }
}
