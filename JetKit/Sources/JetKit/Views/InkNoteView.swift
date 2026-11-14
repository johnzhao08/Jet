import SwiftUI
import PencilKit

/// A handwritten note. On iPad this is a live PencilKit canvas that is ready for the Pencil the
/// moment it appears; on the Mac (no Pencil) it renders the same page read-only.
struct InkNoteView: View {
    let session: VaultSession
    let path: String

    @State private var model: InkNoteModel
    @State private var editorID: UUID?
    @State private var showTools = false
    @State private var imageSource: ImageSource?
    @AppStorage(InkPickerTool.storageKey) private var storedTools = InkPickerTool.encode(InkPickerTool.defaults)

    init(session: VaultSession, path: String) {
        self.session = session
        self.path = path
        _model = State(initialValue: InkNoteModel(url: session.url(for: path)))
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
                    Button { model.toggleTool(.insertSpace) } label: {
                        Label("Insert space", systemImage: model.mode == .insertSpace
                              ? "arrow.up.and.down.square.fill" : "arrow.up.and.down.square")
                    }
                    .tint(model.mode == .insertSpace ? .accentColor : nil)
                    .help("Drag to insert or remove space")
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
                        Picker("Paper", selection: $model.paper) {
                            ForEach(PaperStyle.allCases) { style in
                                Text(style.label).tag(style)
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
                    .help("Paper style and pens")
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
            generation: model.generation,
            paper: model.paper,
            // The floating tool picker would sit on top of sheets, so it steps aside while one is up.
            showsToolPicker: model.showsToolPicker && imageSource == nil && !showTools,
            tools: InkPickerTool.decode(storedTools)
        )
        .ignoresSafeArea(.container, edges: .bottom)
        #else
        InkPagesView(drawing: model.drawing, images: model.images, root: session.root, paper: model.paper, generation: model.generation)
            .safeAreaInset(edge: .bottom) {
                Label("Handwriting is view-only on the Mac. Write on iPad and sync.", systemImage: "applepencil")
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
