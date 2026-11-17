import SwiftUI
import PencilKit

/// A handwritten note, or a PDF to write on. On iPad this is a live PencilKit canvas that is ready
/// for the Pencil the moment it appears; on the Mac (no Pencil) it renders the same pages read-only.
/// A PDF's ink is kept beside it in a hidden `.Name.pdf.ink`, so the PDF itself never changes.
struct InkNoteView: View {
    let session: VaultSession
    let path: String
    /// Set when this is a PDF: its pages go under the ink.
    let pdf: PDFPages?

    @State private var model: InkNoteModel
    @State private var editorID: UUID?
    @State private var showTools = false
    @State private var imageSource: ImageSource?
    @AppStorage(InkPickerTool.storageKey) private var storedTools = InkPickerTool.encode(InkPickerTool.defaults)

    init(session: VaultSession, path: String, pdf: PDFPages? = nil) {
        self.session = session
        self.path = path
        self.pdf = pdf
        let notes = pdf == nil ? path : VaultSession.annotationsPath(for: path)
        _model = State(initialValue: InkNoteModel(url: session.url(for: notes)))
    }

    var body: some View {
        @Bindable var model = model
        content
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.toggleTool(.lasso) } label: {
                        Label("Lasso select", systemImage: "lasso")
                            .symbolVariant(model.mode == .lasso ? .fill : .none)
                    }
                    .tint(model.mode == .lasso ? .accentColor : nil)
                    .help("Select handwriting to move, copy or delete it")
                    if pdf == nil {
                        Button { model.toggleTool(.insertSpace) } label: {
                            Label("Insert space", systemImage: model.mode == .insertSpace
                                  ? "arrow.up.and.down.square.fill" : "arrow.up.and.down.square")
                        }
                        .tint(model.mode == .insertSpace ? .accentColor : nil)
                        .help("Drag to insert or remove space")
                    }
                    Menu {
                        ImageSourceButtons(source: $imageSource)
                    } label: {
                        Label("Insert picture", systemImage: "photo.badge.plus")
                    }
                    .help("Add a photo or picture to the page")
                    Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    Button { model.showsToolPicker.toggle() } label: {
                        Label(model.showsToolPicker ? "Hide tools" : "Show tools",
                              systemImage: model.showsToolPicker ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                    }
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if let pdf {
                            ShareLink(item: AnnotatedPDF(pages: pdf, notes: model.url, root: session.root,
                                                         name: (path as NSString).lastPathComponent),
                                      preview: SharePreview((path as NSString).lastPathComponent)) {
                                Label("Share with Annotations…", systemImage: "square.and.arrow.up")
                            }
                            ShareLink(item: session.url(for: path)) {
                                Label(FileKind(path: path) == .pdf ? "Share Original PDF…" : "Share Original…",
                                      systemImage: "doc")
                            }
                        } else {
                            Picker("Paper", selection: $model.paper) {
                                ForEach(PaperStyle.allCases) { style in
                                    Text(style.label).tag(style)
                                }
                            }
                        }
                        #if os(iOS)
                        Divider()
                        Button { showTools = true } label: {
                            Label("Pens & Tools…", systemImage: "pencil.and.list.clipboard")
                        }
                        #endif
                    } label: {
                        Label("Page", systemImage: "ellipsis.circle")
                    }
                    .help(pdf == nil ? "Paper style and pens" : "Share and pens")
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
            #if os(iOS)
            .sheet(isPresented: $showTools) { InkToolsView() }
            .imageInsertion($imageSource, session: session) { path, pixels in model.insertImage(path, pixels) }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        InkCanvasRepresentable(
            model: model,
            root: session.root,
            pdf: pdf,
            generation: model.generation,
            paper: model.paper,
            // The floating tool picker would sit on top of sheets, so it steps aside while one is up.
            showsToolPicker: model.showsToolPicker && imageSource == nil && !showTools,
            tools: InkPickerTool.decode(storedTools)
        )
        .ignoresSafeArea(.container, edges: .bottom)
        #else
        Group {
            if let pdf {
                PDFPagesView(pages: pdf, drawing: model.drawing, images: model.images, root: session.root,
                             generation: model.generation, session: session, place: placePicture)
            } else {
                InkPagesView(drawing: model.drawing, images: model.images, root: session.root, paper: model.paper,
                             generation: model.generation, session: session, place: placePicture)
            }
        }
            .safeAreaInset(edge: .bottom) {
                Label(pdf == nil ? "Handwriting is view-only on the Mac (drop in pictures). Write on iPad and sync."
                                 : "Handwriting is view-only on the Mac (drop in pictures). Write on iPad and sync.",
                      systemImage: "applepencil")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        #endif
    }
}

#if os(macOS)
extension InkNoteView {
    /// A picture dropped on the page, at that spot (page points), kept inside the page it landed on.
    private func placePicture(_ path: String, pixelSize: CGSize, at point: CGPoint, within bounds: CGRect) {
        model.addPicture(path, pixelSize: pixelSize, at: point, within: bounds)
        model.saveNow()
    }
}

/// Where a picture dropped on a page goes: the picture's path and pixel size, the page point it was
/// dropped on, and the page area it has to stay inside.
typealias PicturePlacement = (_ path: String, _ pixelSize: CGSize, _ at: CGPoint, _ within: CGRect) -> Void
#endif

// MARK: - Rendering (shared)

enum InkRenderer {
    /// Renders part of a drawing with ink colours adapted to light or dark mode, the way the canvas shows them.
    static func image(_ drawing: PKDrawing, rect: CGRect, scale: CGFloat, dark: Bool) -> PlatformImage {
        var result = PlatformImage()
        #if os(macOS)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            result = drawing.image(from: rect, scale: scale)
        }
        #else
        UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
            result = drawing.image(from: rect, scale: scale)
        }
        #endif
        return result
    }

    /// The page area `rect` with its pictures under the ink, as a bitmap `scale` pixels per point.
    /// `background` fills it first (nil leaves it transparent).
    static func compose(_ drawing: PKDrawing, images: [InkImage], root: URL, rect: CGRect, scale: CGFloat,
                        dark: Bool, background: CGColor? = nil) -> CGImage? {
        let width = max(1, Int((rect.width * scale).rounded())), height = max(1, Int((rect.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        if let background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Page coordinates: origin at the top left of `rect`, y down.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        func draw(_ image: CGImage, in frame: CGRect) {
            context.saveGState()
            context.translateBy(x: frame.minX, y: frame.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: frame.size))
            context.restoreGState()
        }
        for image in images where image.frame.intersects(rect) {
            let pixels = Int(max(image.frame.width, image.frame.height) * scale)
            if let picture = ImageFiles.cgImage(at: root.appendingPathComponent(image.path), maxPixels: min(max(pixels, 64), 4096)) {
                draw(picture, in: image.frame)
            }
        }
        if !drawing.strokes.isEmpty, drawing.bounds.intersects(rect), let ink = cgImage(InkRenderer.image(drawing, rect: rect, scale: scale, dark: dark)) {
            draw(ink, in: rect)
        }
        return context.makeImage()
    }

    static func cgImage(_ image: PlatformImage) -> CGImage? {
        #if os(macOS)
        var proposed = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }

    static func platformImage(_ image: CGImage, scale: CGFloat) -> PlatformImage {
        #if os(macOS)
        NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        #else
        UIImage(cgImage: image, scale: scale, orientation: .up)
        #endif
    }
}

struct PaperLines: View {
    let paper: PaperStyle
    let spacing: CGFloat

    var body: some View {
        Canvas { context, size in
            guard paper != .blank, spacing > 4 else { return }
            var path = Path()
            var y = spacing
            while y <= size.height + 0.5 {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            if paper == .grid {
                var x = spacing
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += spacing
                }
            }
            context.stroke(path, with: .color(.secondary.opacity(0.28)), lineWidth: 1)
        }
    }
}

/// The whole page, rendered lazily in square tiles so long notes stay cheap.
struct InkPagesView: View {
    let drawing: PKDrawing
    var images: [InkImage] = []
    var root: URL = URL(fileURLWithPath: "/")
    let paper: PaperStyle
    let generation: Int
    #if os(macOS)
    var session: VaultSession?
    var place: PicturePlacement?
    #endif

    @Environment(\.colorScheme) private var colorScheme
    private let tile = InkDocument.pageWidth

    var body: some View {
        GeometryReader { geometry in
            let scale = max(geometry.size.width / InkDocument.pageWidth, 0.01)
            let content = images.reduce(drawing.bounds) { $0.union($1.frame) }
            let inkBottom = content.isNull ? 0 : content.maxY + 200
            let pageHeight = max(inkBottom, geometry.size.height / scale)
            let count = max(1, Int((pageHeight / tile).rounded(.up)))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { index in
                        InkTile(
                            drawing: drawing,
                            images: images,
                            root: root,
                            rect: CGRect(x: 0, y: CGFloat(index) * tile, width: tile, height: tile),
                            dark: colorScheme == .dark,
                            generation: generation
                        )
                        .background(PaperLines(paper: paper, spacing: InkDocument.lineSpacing * scale))
                        .frame(width: geometry.size.width, height: tile * scale)
                        #if os(macOS)
                        .modifier(PictureDropTarget(session: session, place: place,
                                                    origin: CGPoint(x: 0, y: CGFloat(index) * tile), scale: scale,
                                                    bounds: CGRect(x: 0, y: 0, width: tile, height: .infinity)))
                        #endif
                    }
                }
            }
        }
    }
}

private struct InkTile: View {
    let drawing: PKDrawing
    let images: [InkImage]
    let root: URL
    let rect: CGRect
    let dark: Bool
    let generation: Int
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image).resizable()
            } else {
                Color.clear
            }
        }
        .task(id: "\(generation)-\(dark)-\(images.map(\.frame.debugDescription).joined())") {
            let hasImages = images.contains { $0.frame.intersects(rect) }
            if hasImages {
                image = InkRenderer.compose(drawing, images: images, root: root, rect: rect, scale: 2, dark: dark)
                    .map { InkRenderer.platformImage($0, scale: 2) }
            } else {
                image = drawing.bounds.intersects(rect)
                    ? InkRenderer.image(drawing, rect: rect, scale: 2, dark: dark)
                    : nil
            }
        }
    }
}

/// A handwritten note shown inline inside a Markdown note (`![[Sketch.ink]]`).
struct InkEmbedView: View {
    let url: URL
    let root: URL
    let version: Int
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: PlatformImage?
    @State private var aspect: CGFloat = 2

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4))
            if let image {
                Image(platformImage: image).resizable().scaledToFit().padding(8)
            } else {
                Label("Empty handwritten note", systemImage: "pencil.tip").foregroundStyle(.secondary)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: 640)
        .task(id: "\(version)-\(colorScheme == .dark)") {
            let data = (try? Data(contentsOf: url)) ?? Data()
            let document = InkDocument.decode(data) ?? InkDocument()
            let bounds = document.contentBounds
            guard !bounds.isNull, bounds.width > 1, bounds.height > 1 else {
                image = nil
                return
            }
            let rect = bounds.insetBy(dx: -16, dy: -16)
            aspect = rect.width / rect.height
            image = InkRenderer.compose(document.pkDrawing, images: document.images ?? [], root: root, rect: rect,
                                        scale: 2, dark: colorScheme == .dark)
                .map { InkRenderer.platformImage($0, scale: 2) }
        }
    }
}

/// A PDF with its annotations, read-only (the Mac): each page rendered with its ink, lazily.
struct PDFPagesView: View {
    let pages: PDFPages
    let drawing: PKDrawing
    let images: [InkImage]
    let root: URL
    let generation: Int
    #if os(macOS)
    var session: VaultSession?
    var place: PicturePlacement?
    #endif

    var body: some View {
        GeometryReader { geometry in
            let scale = max((geometry.size.width - 32) / InkDocument.pageWidth, 0.01)
            ScrollView {
                LazyVStack(spacing: PDFPages.gap * scale) {
                    ForEach(pages.frames.indices, id: \.self) { index in
                        PDFPageTile(pages: pages, index: index, drawing: drawing, images: images, root: root,
                                    generation: generation)
                            .frame(width: pages.frames[index].width * scale, height: pages.frames[index].height * scale)
                            #if os(macOS)
                            .modifier(PictureDropTarget(session: session, place: place, origin: pages.frames[index].origin,
                                                        scale: scale, bounds: pages.frames[index]))
                            #endif
                            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    }
                }
                .padding(.vertical, PDFPages.gap * scale)
                .frame(maxWidth: .infinity)
            }
            .background(Color.gray.opacity(0.18))
        }
    }
}

private struct PDFPageTile: View {
    let pages: PDFPages
    let index: Int
    let drawing: PKDrawing
    let images: [InkImage]
    let root: URL
    let generation: Int
    @State private var image: PlatformImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white
                if let image { Image(platformImage: image).resizable() }
            }
            .task(id: "\(generation)-\(Int(geometry.size.width))-\(images.count)") {
                let scale = geometry.size.width / InkDocument.pageWidth * displayScale
                let rendered = pages.render(index, drawing: drawing, images: images, root: root, scale: scale)
                image = rendered.map { InkRenderer.platformImage($0, scale: displayScale) }
            }
        }
    }
}

#if os(macOS)
/// Makes a page tile take dropped pictures, turning the drop point into page points.
private struct PictureDropTarget: ViewModifier {
    let session: VaultSession?
    let place: PicturePlacement?
    /// The tile's top-left corner in page points, and view points per page point.
    let origin: CGPoint
    let scale: CGFloat
    let bounds: CGRect

    func body(content: Content) -> some View {
        if let session, let place {
            content.onDrop(of: FileDrop.acceptedTypes, delegate: PictureDrop(session: session) { path, pixels, at in
                place(path, pixels, CGPoint(x: origin.x + at.x / scale, y: origin.y + at.y / scale), bounds)
            })
        } else {
            content
        }
    }
}
#endif

/// A PDF with its annotations drawn in, made when it's shared.
struct AnnotatedPDF: Transferable {
    let pages: PDFPages
    let notes: URL
    let root: URL
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { item in
            let document = InkDocument.decode((try? Data(contentsOf: item.notes)) ?? Data()) ?? InkDocument()
            guard let data = item.pages.annotatedPDF(drawing: document.pkDrawing, images: document.images ?? [], root: item.root)
            else { throw CocoaError(.fileWriteUnknown) }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = (item.name as NSString).deletingPathExtension
            let url = folder.appendingPathComponent("\(base) (annotated).pdf")
            try data.write(to: url)
            return SentTransferredFile(url)
        }
    }
}
