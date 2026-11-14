import SwiftUI

/// Notes as dots and `[[links]]` as lines, laid out by a small force simulation.
/// "This note" shows the open note with everything it links to and from; "Whole vault" shows every note.
struct GraphView: View {
    @Environment(\.dismiss) private var dismiss
    let session: VaultSession

    enum Scope: String, CaseIterable, Identifiable {
        case local = "This note", global = "Whole vault"
        var id: Self { self }
    }

    @State private var scope: Scope
    @State private var layout = GraphLayout()
    @State private var offset = CGSize.zero
    @State private var scale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var drag: DragState?
    @State private var canvasSize = CGSize(width: 800, height: 600)
    /// Until the user pans or zooms, the view keeps the whole graph in frame as it settles.
    @State private var followsLayout = true

    private struct DragState {
        var node: Int?
        var startOffset: CGSize
    }

    init(session: VaultSession) {
        self.session = session
        let hasNote = session.selection.map { VaultSession.noteExtensions.contains(($0 as NSString).pathExtension.lowercased()) } ?? false
        _scope = State(initialValue: hasNote ? .local : .global)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let _ = layout.tick  // redraw on every simulation step
                Canvas { context, size in
                    draw(in: &context, size: size)
                }
                .task(id: layout.isMoving) {
                    // Advance the simulation about once a frame while it is still settling.
                    while layout.isMoving, !Task.isCancelled {
                        layout.step()
                        if followsLayout { fit(easing: 0.2) }
                        try? await Task.sleep(for: .milliseconds(16))
                    }
                }
                .onAppear { canvasSize = geometry.size }
                .onChange(of: geometry.size) { _, size in canvasSize = size }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    // Tap a dot to open that note.
                    guard let index = node(at: location, size: geometry.size) else { return }
                    session.selection = layout.nodes[index].path
                    dismiss()
                }
                .gesture(dragGesture(size: geometry.size))
                .simultaneousGesture(MagnifyGesture()
                    .onChanged {
                        followsLayout = false
                        gestureScale = $0.magnification
                    }
                    .onEnded { value in
                        scale = clampScale(scale * value.magnification)
                        gestureScale = 1
                    })
                .accessibilityElement()
                .accessibilityLabel("Graph of \(layout.nodes.count) notes and \(layout.edges.count) links")
                .overlay {
                    if layout.nodes.isEmpty {
                        ContentUnavailableView("No notes to show", systemImage: "point.3.connected.trianglepath.dotted",
                                               description: Text("Link notes with [[Note name]] and they appear here."))
                    }
                }
            }
            .background(.background)
            .navigationTitle("Graph")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $scope) {
                        ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(session.selection == nil)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { zoom(by: 1 / 1.4) } label: { Label("Zoom out", systemImage: "minus.magnifyingglass") }
                    Button { zoom(by: 1.4) } label: { Label("Zoom in", systemImage: "plus.magnifyingglass") }
                    Button {
                        followsLayout = true
                        withAnimation(.easeOut(duration: 0.25)) { fit(easing: 1) }
                    } label: { Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right") }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .graphSheetSize()
        .onAppear(perform: load)
        .onChange(of: scope) { load() }
        .onChange(of: session.indexVersion) { load() }
    }

    // MARK: Data

    private func load() {
        let notes = session.allNotes.map(\.path)
        var edges: [(String, String)] = []
        for (source, targets) in session.index.outgoing {
            for target in targets { edges.append((source, target)) }
        }
        var paths = notes
        let center = session.selection
        if scope == .local, let center {
            var keep: Set<String> = [center]
            for (a, b) in edges where a == center || b == center {
                keep.insert(a)
                keep.insert(b)
            }
            paths = notes.filter(keep.contains)
            edges = edges.filter { keep.contains($0.0) && keep.contains($0.1) }
        }
        layout.load(paths: paths, edges: edges, center: center)
        followsLayout = true
        fit(easing: 1)
    }

    /// Moves the view toward showing the whole graph; `easing` 1 jumps there, smaller values glide.
    private func fit(easing: CGFloat) {
        guard let bounds = layout.bounds, canvasSize.width > 0, canvasSize.height > 0 else { return }
        let target = min(1.4, max(0.15, min(canvasSize.width / bounds.width, canvasSize.height / bounds.height)))
        let targetOffset = CGSize(width: -bounds.midX * target, height: -bounds.midY * target)
        scale += (target - scale) * easing
        offset.width += (targetOffset.width - offset.width) * easing
        offset.height += (targetOffset.height - offset.height) * easing
    }

    private func zoom(by factor: CGFloat) {
        followsLayout = false
        let newScale = clampScale(scale * factor)
        // Zoom around the centre of the view.
        offset = CGSize(width: offset.width * newScale / scale, height: offset.height * newScale / scale)
        scale = newScale
    }

    private func clampScale(_ value: CGFloat) -> CGFloat { min(max(value, 0.15), 4) }

    // MARK: Geometry

    private var effectiveScale: CGFloat { scale * gestureScale }

    private func screen(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + offset.width + point.x * effectiveScale,
                y: size.height / 2 + offset.height + point.y * effectiveScale)
    }

    private func world(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (point.x - size.width / 2 - offset.width) / effectiveScale,
                y: (point.y - size.height / 2 - offset.height) / effectiveScale)
    }

    private func node(at point: CGPoint, size: CGSize) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, node) in layout.nodes.enumerated() {
            let p = screen(node.position, size: size)
            let distance = hypot(p.x - point.x, p.y - point.y)
            if distance <= max(14, radius(of: node) * effectiveScale + 6), distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        return best?.index
    }

    private func radius(of node: GraphLayout.Node) -> CGFloat { 4 + sqrt(CGFloat(node.degree)) * 1.6 }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let center = session.selection
        let neighbors: Set<Int> = {
            guard let focus = drag?.node ?? layout.nodes.firstIndex(where: { $0.path == center }) else { return [] }
            var set: Set<Int> = [focus]
            for (a, b) in layout.edges where a == focus || b == focus { set.insert(a); set.insert(b) }
            return set
        }()

        var lines = Path()
        var strong = Path()
        for (a, b) in layout.edges {
            let pa = screen(layout.nodes[a].position, size: size), pb = screen(layout.nodes[b].position, size: size)
            if neighbors.contains(a) && neighbors.contains(b) {
                strong.move(to: pa); strong.addLine(to: pb)
            } else {
                lines.move(to: pa); lines.addLine(to: pb)
            }
        }
        context.stroke(lines, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
        context.stroke(strong, with: .color(.accentColor.opacity(0.7)), lineWidth: 1.5)

        let showAllLabels = effectiveScale >= 0.9 || layout.nodes.count <= 40
        for (index, node) in layout.nodes.enumerated() {
            let p = screen(node.position, size: size)
            guard p.x > -40, p.y > -40, p.x < size.width + 40, p.y < size.height + 40 else { continue }
            let r = radius(of: node) * max(0.6, min(effectiveScale, 1.6))
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            let isCenter = node.path == center
            let color: Color = isCenter ? .accentColor : node.isInk ? .orange : neighbors.contains(index) ? .accentColor.opacity(0.75) : .secondary
            context.fill(Path(ellipseIn: rect), with: .color(color))
            if isCenter {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(.accentColor.opacity(0.5)), lineWidth: 2)
            }
            if showAllLabels || neighbors.contains(index) {
                let label = Text(node.title)
                    .font(.system(size: isCenter ? 12 : 11, weight: isCenter ? .semibold : .regular))
                    .foregroundStyle(neighbors.isEmpty || neighbors.contains(index) ? .primary : .secondary)
                context.draw(label, at: CGPoint(x: p.x, y: p.y + r + 3), anchor: .top)
            }
        }
    }

    // MARK: Gestures

    /// Drag a dot to move it; drag the background to pan.
    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if drag == nil {
                    drag = DragState(node: node(at: value.startLocation, size: size), startOffset: offset)
                }
                guard let state = drag else { return }
                if let index = state.node {
                    layout.pin(index, at: world(value.location, size: size))
                } else {
                    followsLayout = false
                    offset = CGSize(width: state.startOffset.width + value.translation.width,
                                    height: state.startOffset.height + value.translation.height)
                }
            }
            .onEnded { _ in
                if let index = drag?.node { layout.unpin(index) }
                drag = nil
            }
    }
}

/// A force-directed layout: linked notes pull together, all notes push apart, and a weak pull keeps
/// unlinked notes from drifting off. It cools over a few seconds and then stops.
@MainActor
@Observable
final class GraphLayout {
    struct Node {
        let path: String
        let title: String
        let isInk: Bool
        var degree = 0
        var position: CGPoint
        var velocity = CGVector.zero
        var pinned = false
    }

    private(set) var nodes: [Node] = []
    private(set) var edges: [(Int, Int)] = []
    private(set) var tick = 0
    private var alpha: CGFloat = 1

    var isMoving: Bool { alpha > 0.01 && !nodes.isEmpty }

    var bounds: CGRect? {
        guard let first = nodes.first else { return nil }
        return nodes.dropFirst().reduce(CGRect(origin: first.position, size: .zero)) {
            $0.union(CGRect(origin: $1.position, size: .zero))
        }.insetBy(dx: -70, dy: -50)
    }

    func load(paths: [String], edges pairs: [(String, String)], center: String?) {
        var ordered = paths.sorted()
        if let center, let i = ordered.firstIndex(of: center) { ordered.insert(ordered.remove(at: i), at: 0) }
        let indexOf = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) })
        // Start on a sunflower spiral so the layout is the same every time it opens.
        nodes = ordered.enumerated().map { i, path in
            let radius = 12 * sqrt(CGFloat(i) + 0.5)
            let angle = CGFloat(i) * .pi * (3 - sqrt(5))
            return Node(path: path,
                        title: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                        isInk: path.lowercased().hasSuffix(".ink"),
                        position: CGPoint(x: radius * cos(angle), y: radius * sin(angle)))
        }
        var seen = Set<[Int]>()
        edges = pairs.compactMap { a, b in
            guard let i = indexOf[a], let j = indexOf[b], i != j, seen.insert([min(i, j), max(i, j)]).inserted else { return nil }
            return (i, j)
        }
        for (a, b) in edges { nodes[a].degree += 1; nodes[b].degree += 1 }
        alpha = 1
        tick += 1
    }

    func step() {
        let count = nodes.count
        guard count > 0 else { return }
        var force = [CGVector](repeating: .zero, count: count)

        // Every pair repels (n² is fine for a personal vault of a few hundred notes).
        for i in 0..<count {
            for j in (i + 1)..<count {
                var dx = nodes[i].position.x - nodes[j].position.x
                var dy = nodes[i].position.y - nodes[j].position.y
                if dx == 0 && dy == 0 { dx = CGFloat.random(in: -1...1); dy = CGFloat.random(in: -1...1) }
                let distanceSquared = max(dx * dx + dy * dy, 25)
                let push = 700 / distanceSquared
                force[i].dx += dx * push; force[i].dy += dy * push
                force[j].dx -= dx * push; force[j].dy -= dy * push
            }
        }
        // Links act as springs.
        for (a, b) in edges {
            let dx = nodes[b].position.x - nodes[a].position.x
            let dy = nodes[b].position.y - nodes[a].position.y
            let distance = max(hypot(dx, dy), 0.01)
            let pull = (distance - 60) * 0.05 / distance
            force[a].dx += dx * pull; force[a].dy += dy * pull
            force[b].dx -= dx * pull; force[b].dy -= dy * pull
        }
        for i in 0..<count where !nodes[i].pinned {
            force[i].dx -= nodes[i].position.x * 0.04
            force[i].dy -= nodes[i].position.y * 0.04
            nodes[i].velocity.dx = (nodes[i].velocity.dx + force[i].dx * alpha) * 0.6
            nodes[i].velocity.dy = (nodes[i].velocity.dy + force[i].dy * alpha) * 0.6
            nodes[i].position.x += nodes[i].velocity.dx
            nodes[i].position.y += nodes[i].velocity.dy
        }
        alpha *= 0.985
        tick += 1
    }

    func pin(_ index: Int, at point: CGPoint) {
        nodes[index].pinned = true
        nodes[index].position = point
        nodes[index].velocity = .zero
        alpha = max(alpha, 0.3)
        tick += 1
    }

    func unpin(_ index: Int) {
        nodes[index].pinned = false
    }
}

private extension View {
    @ViewBuilder
    func graphSheetSize() -> some View {
        #if os(macOS)
        frame(minWidth: 760, minHeight: 560)
        #else
        presentationSizing(.page)
        #endif
    }
}
