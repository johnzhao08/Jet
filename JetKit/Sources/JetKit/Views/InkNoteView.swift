import SwiftUI
import PencilKit

/// A handwritten note, or a PDF to write on. On iPad this is a live PencilKit canvas that is ready
/// for the Pencil the moment it appears; on the Mac the same pages are written on with a mouse,
/// trackpad or drawing tablet (`InkCanvas_macOS.swift`) and saved as the same PencilKit strokes.
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
                    if pdf == nil {
                        Button { model.beginAddingText() } label: {
                            Label("Add Text", systemImage: "character.textbox")
                                .symbolVariant(model.isAddingText ? .fill : .none)
                        }
                        .tint(model.isAddingText ? .accentColor : nil)
                        .accessibilityIdentifier("ink-add-text")
                        .help("Tap the page where the text should go, then type")
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
                #else
                InkSurfaceToolbar(model: model, allowsText: pdf == nil)
                #endif
                ToolbarItem(placement: .primaryAction) {
                    InkZoomMenu(model: model)
                }
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
            tools: InkPickerTool.decode(storedTools),
            zoom: model.currentZoom
        )
        .ignoresSafeArea(.container, edges: .bottom)
        #else
        // Reading the revision makes this view redraw the page whenever strokes are added or erased.
        let _ = model.revision
        Group {
            if let pdf {
                PDFPagesView(pages: pdf, drawing: model.drawing, images: model.images, root: session.root,
                             generation: model.generation, session: session, place: placePicture, writer: model)
            } else {
                InkPagesView(drawing: model.drawing, images: model.images,
                             texts: model.texts.filter { $0.id != model.editingTextID },
                             editorBottom: model.textEditorBottom,
                             root: session.root, paper: model.paper,
                             generation: model.generation, session: session, place: placePicture, writer: model)
            }
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
    static func compose(_ drawing: PKDrawing, images: [InkImage], texts: [InkText] = [], root: URL, rect: CGRect,
                        scale: CGFloat, dark: Bool, background: CGColor? = nil) -> CGImage? {
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
                let frame = image.frame
                let fill = max(frame.width / CGFloat(picture.width), frame.height / CGFloat(picture.height))
                let size = CGSize(width: CGFloat(picture.width) * fill, height: CGFloat(picture.height) * fill)
                context.saveGState()
                context.clip(to: frame)
                draw(picture, in: CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                         width: size.width, height: size.height))
                context.restoreGState()
            }
        }
        // Typed text over the pictures, under the ink, so handwriting can mark it up.
        for text in texts where text.frame.intersects(rect) {
            InkTextLayout.draw(text, in: context, color: InkTextLayout.color(dark: dark))
        }
        if !drawing.strokes.isEmpty, drawing.bounds.intersects(rect), let ink = cgImage(InkRenderer.image(drawing, rect: rect, scale: scale, dark: dark)) {
            // Keep PencilKit's pixel scale when the requested area ends on a partial pixel.
            context.clip(to: rect)
            draw(ink, in: CGRect(x: rect.minX, y: rect.minY, width: CGFloat(ink.width) / scale, height: CGFloat(ink.height) / scale))
        }
        return context.makeImage()
    }

    /// A number that changes when the typed text touching `rect` changes.
    static func signature(of texts: [InkText], in rect: CGRect) -> Int {
        var hasher = Hasher()
        for text in texts where text.frame.intersects(rect) {
            hasher.combine(text.id)
            hasher.combine(text.text)
            hasher.combine(text.x)
            hasher.combine(text.y)
            hasher.combine(text.width)
        }
        return hasher.finalize()
    }

    /// A number that changes when the strokes touching `rect` change (one added, erased or replaced), so a
    /// tile or page is redrawn only when its own ink did.
    static func signature(of drawing: PKDrawing, in rect: CGRect) -> Int {
        var hasher = Hasher()
        for stroke in drawing.strokes where stroke.renderBounds.intersects(rect) {
            hasher.combine(stroke.path.creationDate.timeIntervalSinceReferenceDate)
            hasher.combine(stroke.path.count)
        }
        return hasher.finalize()
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
    var texts: [InkText] = []
    /// The bottom of an open text editor (page points), which the page grows to fit.
    var editorBottom: CGFloat?
    var root: URL = URL(fileURLWithPath: "/")
    let paper: PaperStyle
    let generation: Int
    #if os(macOS)
    var session: VaultSession?
    var place: PicturePlacement?
    /// The note being written on; the page takes its pen, mouse and tablet input.
    var writer: InkNoteModel?
    #endif

    @Environment(\.colorScheme) private var colorScheme
    private let tile = InkDocument.pageWidth

    private var zoomModel: InkNoteModel? {
        #if os(macOS)
        writer
        #else
        nil
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            let fit = max(geometry.size.width / InkDocument.pageWidth, 0.01)
            // The note's zoom (see `InkNoteModel.zoom(fitting:)`): a wider window keeps it and shows more page.
            let scale = zoomModel?.zoom(fitting: fit) ?? fit
            let content = texts.reduce(images.reduce(drawing.bounds) { $0.union($1.frame) }) { $0.union($1.frame) }
            let bottom = max(content.isNull ? 0 : content.maxY, editorBottom ?? 0)
            let inkBottom = bottom > 0 ? bottom + 200 : 0
            let pageHeight = max(inkBottom, geometry.size.height / scale)
            let count = max(1, Int((pageHeight / tile).rounded(.up)))
            // The page extends sideways to fill the window, and to whatever is already written there.
            let pageWidth = max(InkDocument.pageWidth, geometry.size.width / scale, content.isNull ? 0 : content.maxX)
            let width = pageWidth * scale
            let columns = max(1, Int((pageWidth / tile).rounded(.up)))
            ScrollView(width > geometry.size.width + 0.5 ? [.vertical, .horizontal] : .vertical) {
                ZStack(alignment: .topLeading) {
                    // Square tiles of a fixed size on the page, so zooming or a wider window only adds
                    // columns on the right; a tile's drawing is never stretched to a new shape.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<count, id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(0..<columns, id: \.self) { column in
                                    let rect = CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile,
                                                      width: tile, height: tile)
                                    InkTile(
                                        drawing: drawing,
                                        images: images,
                                        texts: texts,
                                        root: root,
                                        rect: rect,
                                        dark: colorScheme == .dark,
                                        generation: generation,
                                        inkKey: InkRenderer.signature(of: drawing, in: rect),
                                        textKey: InkRenderer.signature(of: texts, in: rect)
                                    )
                                    .frame(width: tile * scale, height: tile * scale)
                                }
                            }
                            .frame(width: width, height: tile * scale, alignment: .leading)
                            .clipped()
                            .background(PaperLines(paper: paper, spacing: InkDocument.lineSpacing * scale))
                        }
                    }
                    #if os(macOS)
                    if let writer {
                        InkSurface(writer: writer, scale: scale, origin: .zero, dark: colorScheme == .dark)
                            .frame(width: width, height: CGFloat(count) * tile * scale)
                    }
                    #endif
                }
                #if os(macOS)
                .modifier(PictureDropTarget(session: session, place: place, origin: .zero, scale: scale,
                                            bounds: { _ in CGRect(x: 0, y: 0, width: pageWidth, height: .infinity) }))
                #endif
            }
            .onAppear { if geometry.size.width > 0 { zoomModel?.viewFits(fit) } }
            .onChange(of: fit) { _, fit in zoomModel?.viewFits(fit) }
        }
    }
}

private struct InkTile: View {
    let drawing: PKDrawing
    let images: [InkImage]
    let texts: [InkText]
    let root: URL
    let rect: CGRect
    let dark: Bool
    let generation: Int
    /// Changes when the ink on this tile does (see `InkRenderer.signature`).
    let inkKey: Int
    /// Changes when the typed text on this tile does.
    let textKey: Int
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image).resizable()
            } else {
                Color.clear
            }
        }
        .task(id: "\(rect.debugDescription)-\(generation)-\(dark)-\(inkKey)-\(textKey)-\(images.map(\.frame.debugDescription).joined())") {
            let hasImages = images.contains { $0.frame.intersects(rect) } || texts.contains { $0.frame.intersects(rect) }
            if hasImages {
                image = InkRenderer.compose(drawing, images: images, texts: texts, root: root, rect: rect, scale: 2, dark: dark)
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
            image = InkRenderer.compose(document.pkDrawing, images: document.images ?? [], texts: document.texts ?? [],
                                        root: root, rect: rect, scale: 2, dark: colorScheme == .dark)
                .map { InkRenderer.platformImage($0, scale: 2) }
        }
    }
}

/// A PDF with its annotations (the Mac): each page rendered with its ink, lazily, with the writing surface over it.
struct PDFPagesView: View {
    let pages: PDFPages
    let drawing: PKDrawing
    let images: [InkImage]
    let root: URL
    let generation: Int
    #if os(macOS)
    var session: VaultSession?
    var place: PicturePlacement?
    /// The PDF's ink; the pages take its pen, mouse and tablet input.
    var writer: InkNoteModel?
    #endif

    @Environment(\.colorScheme) private var colorScheme

    private var zoomModel: InkNoteModel? {
        #if os(macOS)
        writer
        #else
        nil
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            let fit = max((geometry.size.width - 32) / InkDocument.pageWidth, 0.01)
            let scale = zoomModel?.zoom(fitting: fit) ?? fit
            let wide = InkDocument.pageWidth * scale + 32 > geometry.size.width + 0.5
            ScrollView(wide ? [.vertical, .horizontal] : .vertical) {
                ZStack(alignment: .topLeading) {
                    LazyVStack(spacing: PDFPages.gap * scale) {
                        ForEach(pages.frames.indices, id: \.self) { index in
                            PDFPageTile(pages: pages, index: index, drawing: drawing, images: images, root: root,
                                        generation: generation,
                                        inkKey: InkRenderer.signature(of: drawing, in: pages.frames[index]))
                                .id(pages.frames[index].debugDescription)
                                .frame(width: pages.frames[index].width * scale, height: pages.frames[index].height * scale)
                                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                        }
                    }
                    #if os(macOS)
                    if let writer {
                        // Spans the pages and the gaps between them; the first page starts one gap down the page.
                        InkSurface(writer: writer, scale: scale, origin: CGPoint(x: 0, y: PDFPages.gap),
                                   dark: colorScheme == .dark)
                            .frame(width: InkDocument.pageWidth * scale, height: (pages.height - 2 * PDFPages.gap) * scale)
                    }
                    #endif
                }
                #if os(macOS)
                .modifier(PictureDropTarget(session: session, place: place, origin: CGPoint(x: 0, y: PDFPages.gap),
                                            scale: scale, bounds: { point in
                    pages.frames.min { verticalDistance(from: point.y, to: $0) < verticalDistance(from: point.y, to: $1) }
                        ?? CGRect(x: 0, y: 0, width: InkDocument.pageWidth, height: pages.height)
                }))
                #endif
                .padding(.vertical, PDFPages.gap * scale)
                .padding(.horizontal, 16)
                .frame(minWidth: geometry.size.width)
            }
            .background(Color.gray.opacity(0.18))
            .onAppear { if geometry.size.width > 0 { zoomModel?.viewFits(fit) } }
            .onChange(of: fit) { _, fit in zoomModel?.viewFits(fit) }
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
    /// Changes when the ink on this page does (see `InkRenderer.signature`).
    let inkKey: Int
    @State private var image: CGImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            let pixels = (geometry.size.width * displayScale).rounded()
            Color.white
                .overlay(alignment: .topLeading) {
                    if let image {
                        // The last raster row can include padding. Clip it outside the page.
                        Image(decorative: image, scale: displayScale).resizable()
                            .frame(width: geometry.size.width,
                                   height: geometry.size.width * CGFloat(image.height) / CGFloat(image.width))
                    }
                }
                .clipped()
                .task(id: "\(ObjectIdentifier(pages))-\(generation)-\(pixels)-\(images.count)-\(inkKey)") {
                    guard pixels > 0 else { return }
                    image = pages.render(index, drawing: drawing, images: images, root: root, scale: pixels / pages.frames[index].width)
                }
        }
    }
}

#if os(macOS)
/// Distance from page height `y` to the vertical span of `frame` (0 inside it).
private func verticalDistance(from y: CGFloat, to frame: CGRect) -> CGFloat {
    y < frame.minY ? frame.minY - y : (y > frame.maxY ? y - frame.maxY : 0)
}

/// Makes the page take dropped pictures, turning the drop point into page points.
private struct PictureDropTarget: ViewModifier {
    let session: VaultSession?
    let place: PicturePlacement?
    /// The dropped-on view's top-left corner in page points, and view points per page point.
    let origin: CGPoint
    let scale: CGFloat
    /// The page area a picture dropped at a page point has to stay inside.
    let bounds: (CGPoint) -> CGRect

    func body(content: Content) -> some View {
        if let session, let place {
            content.onDrop(of: FileDrop.acceptedTypes, delegate: PictureDrop(session: session) { path, pixels, at in
                let point = CGPoint(x: origin.x + at.x / scale, y: origin.y + at.y / scale)
                place(path, pixels, point, bounds(point))
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
