import SwiftUI
import PencilKit

/// A handwritten note. On iPad this is a live PencilKit canvas that is ready for the Pencil the
/// moment it appears; on the Mac (no Pencil) it renders the same page read-only.
struct InkNoteView: View {
    let session: VaultSession
    let path: String

    @State private var model: InkNoteModel
    @State private var editorID: UUID?

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
                    Button { model.mode = model.mode == .lasso ? .draw : .lasso } label: {
                        Label("Lasso select", systemImage: "lasso")
                            .symbolVariant(model.mode == .lasso ? .fill : .none)
                    }
                    .tint(model.mode == .lasso ? .accentColor : nil)
                    .help("Select handwriting to move, copy or delete it")
                    Button { model.mode = model.mode == .insertSpace ? .draw : .insertSpace } label: {
                        Label("Insert space", systemImage: model.mode == .insertSpace
                              ? "arrow.up.and.down.square.fill" : "arrow.up.and.down.square")
                    }
                    .tint(model.mode == .insertSpace ? .accentColor : nil)
                    .help("Drag to insert or remove space")
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
                    } label: {
                        Label("Paper", systemImage: "squareshape.split.3x3")
                    }
                    .help("Paper style")
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

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        InkCanvasRepresentable(
            model: model,
            generation: model.generation,
            paper: model.paper,
            showsToolPicker: model.showsToolPicker,
            mode: model.mode
        )
        .ignoresSafeArea(.container, edges: .bottom)
        #else
        InkPagesView(drawing: model.drawing, paper: model.paper, generation: model.generation)
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
    let paper: PaperStyle
    let generation: Int

    @Environment(\.colorScheme) private var colorScheme
    private let tile = InkDocument.pageWidth

    var body: some View {
        GeometryReader { geometry in
            let scale = max(geometry.size.width / InkDocument.pageWidth, 0.01)
            let inkBottom = drawing.bounds.isNull ? 0 : drawing.bounds.maxY + 200
            let pageHeight = max(inkBottom, geometry.size.height / scale)
            let count = max(1, Int((pageHeight / tile).rounded(.up)))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { index in
                        InkTile(
                            drawing: drawing,
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
        .task(id: "\(generation)-\(dark)") {
            image = drawing.bounds.intersects(rect)
                ? InkRenderer.image(drawing, rect: rect, scale: 2, dark: dark)
                : nil
        }
    }
}

/// A handwritten note shown inline inside a Markdown note (`![[Sketch.ink]]`).
struct InkEmbedView: View {
    let url: URL
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
            let drawing = InkDocument.decode(data)?.pkDrawing ?? PKDrawing()
            let bounds = drawing.bounds
            guard !bounds.isNull, bounds.width > 1, bounds.height > 1 else {
                image = nil
                return
            }
            let rect = bounds.insetBy(dx: -16, dy: -16)
            aspect = rect.width / rect.height
            image = InkRenderer.image(drawing, rect: rect, scale: 2, dark: colorScheme == .dark)
        }
    }
}
