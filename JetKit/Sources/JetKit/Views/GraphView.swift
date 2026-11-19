import SwiftUI

/// Notes as dots and `[[links]]` as lines, laid out by a small force simulation.
/// "This note" shows the open note with everything within a few links of it (the depth setting); "Whole vault"
/// shows every note. A filter narrows what is shown, and colour groups paint the notes they match.
struct GraphView: View {
    @Environment(\.dismiss) private var dismiss
    let session: VaultSession

    enum Scope: String, CaseIterable, Identifiable {
        case local = "This note", global = "Whole vault"
        var id: Self { self }
    }

    @State private var scope: Scope
    @State private var query = ""
    @State private var groups: [GraphGroup]
    @State private var showFilters = false
    /// Tags of the notes on screen, kept so changing a group can recolour without rebuilding the graph.
    @State private var tags: [String: [String]] = [:]
    @AppStorage("graph.depth") private var storedDepth = 1
    @AppStorage("graph.groups") private var storedGroups = "[]"
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
        _groups = State(initialValue: GraphGroup.decode(UserDefaults.standard.string(forKey: "graph.groups")))
    }

    private var depth: Binding<Int> {
        Binding(get: { min(max(storedDepth, GraphSelection.depthRange.lowerBound), GraphSelection.depthRange.upperBound) },
                set: { storedDepth = $0 })
    }

    private var isFiltering: Bool { !GraphQuery(query).isEmpty }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let _ = layout.tick  // redraw on every simulation step
                Canvas { context, size in
                    draw(in: &context, size: size)
                }
                .task(id: layout.isMoving) {
                    // Ask the background engine for a new frame about once a frame while it is still settling.
                    while layout.isMoving, !Task.isCancelled {
                        await layout.advance()
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
                        if isFiltering {
                            ContentUnavailableView("No matching notes", systemImage: "line.3.horizontal.decrease.circle",
                                                   description: Text("Nothing matches the filter."))
                        } else {
                            ContentUnavailableView("No notes to show", systemImage: "point.3.connected.trianglepath.dotted",
                                                   description: Text("Link notes with [[Note name]] and they appear here."))
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    // Above the canvas, so touches on the panel never reach the graph's gestures.
                    if showFilters { filterPanel }
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
                    Button { showFilters.toggle() } label: {
                        Label("Filters and groups", systemImage: showFilters || isFiltering || !groups.isEmpty
                              ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .help("Filter the graph and colour notes by group")
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
        .onAppear { load() }
        .onChange(of: scope) { load() }
        .onChange(of: session.indexVersion) { load() }
        // Narrowing the filter or changing depth keeps the view where the user left it.
        .onChange(of: query) { load(resetView: false) }
        .onChange(of: storedDepth) { load(resetView: false) }
        .onChange(of: groups) {
            storedGroups = GraphGroup.encode(groups)
            recolor()
        }
    }

    // MARK: Filters and groups

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Filter: words, #tag, path:folder, -skip", text: $query)
                .accessibilityIdentifier("graph-filter")
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            Stepper(value: depth, in: GraphSelection.depthRange) {
                Text("Depth: \(depth.wrappedValue)")
            }
            .disabled(scope != .local || session.selection == nil)
            .help("How many links away from this note to show")
            if scope != .local {
                Text("Depth applies to “This note”.").font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("Groups").font(.headline)
                Spacer()
                Button {
                    groups.append(GraphGroup(query: "", color: GraphGroup.nextColor(after: groups)))
                } label: { Label("Add group", systemImage: "plus") }
                    .labelStyle(.iconOnly)
            }
            if groups.isEmpty {
                Text("Add a group to colour the notes that match a filter, like #project.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($groups) { $group in
                HStack(spacing: 8) {
                    Menu {
                        ForEach(GraphColor.allCases) { option in
                            Button { group.color = option } label: {
                                Label(option.name, systemImage: group.color == option ? "checkmark" : "circle")
                            }
                        }
                    } label: {
                        Circle().fill(group.color.color).frame(width: 16, height: 16)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Colour: \(group.color.name)")
                    TextField("#tag or words", text: $group.query)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button(role: .destructive) { groups.removeAll { $0.id == group.id } } label: {
                        Label("Remove group", systemImage: "minus.circle")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }

            Text("\(layout.nodes.count) notes · \(layout.edges.count) links")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .padding(12)
    }

    private func recolor() {
        layout.setGroups(GraphGroup.assignments(paths: layout.nodes.map(\.path), tags: tags, groups: groups))
    }

    // MARK: Data

    /// Rebuilds the graph from the vault, the scope, the depth and the filter. `resetView` also re-frames the whole graph.
    private func load(resetView: Bool = true) {
        var edges: [(String, String)] = []
        for (source, targets) in session.index.outgoing {
            for target in targets { edges.append((source, target)) }
        }
        let center = session.selection
        let source = GraphSource(paths: session.allNotes.map(\.path), edges: edges, tags: session.index.noteTags)
        let shown = GraphSelection.select(source, center: center, local: scope == .local && center != nil,
                                          depth: depth.wrappedValue, query: GraphQuery(query))
        tags = source.tags
        layout.load(paths: shown.paths, edges: shown.edges, center: center)
        recolor()
        if resetView {
            followsLayout = true
            fit(easing: 1)
        }
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
            let p = screen(layout.positions[index], size: size)
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
            let pa = screen(layout.positions[a], size: size), pb = screen(layout.positions[b], size: size)
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
            let p = screen(layout.positions[index], size: size)
            guard p.x > -40, p.y > -40, p.x < size.width + 40, p.y < size.height + 40 else { continue }
            let r = radius(of: node) * max(0.6, min(effectiveScale, 1.6))
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            let isCenter = node.path == center
            let grouped = node.group.flatMap { groups.indices.contains($0) ? groups[$0].color.color : nil }
            let color: Color = isCenter ? .accentColor : grouped ?? (node.isInk ? .orange : neighbors.contains(index) ? .accentColor.opacity(0.75) : .secondary)
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

/// What the graph view draws and hit-tests. The layout itself is computed by `GraphEngine` on a background actor;
/// this class sends it commands (load, pin, unpin) and copies its positions back once per frame, so the main
/// thread only ever does cheap work and gestures never wait for a simulation step.
@MainActor
@Observable
final class GraphLayout {
    struct Node {
        let path: String
        let title: String
        let isInk: Bool
        var degree = 0
        /// Index into the view's colour groups, if the note belongs to one.
        var group: Int?
    }

    private(set) var nodes: [Node] = []
    private(set) var positions: [CGPoint] = []
    private(set) var edges: [(Int, Int)] = []
    private(set) var tick = 0
    private(set) var alpha: CGFloat = 0

    @ObservationIgnored private let engine = GraphEngine()
    /// Dots being held by a drag. Their positions come from the gesture, not from the engine.
    @ObservationIgnored private var pinned: Set<Int> = []
    /// How many times `load` has run; frames from an earlier load are stale and dropped.
    @ObservationIgnored private var loads = 0
    /// The newest command queued for the engine.
    @ObservationIgnored private var lastSent = 0

    var isMoving: Bool { alpha > 0.01 && !nodes.isEmpty }

    var bounds: CGRect? {
        guard let first = positions.first else { return nil }
        return positions.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }.insetBy(dx: -70, dy: -50)
    }

    func load(paths: [String], edges pairs: [(String, String)], center: String?) {
        var ordered = paths.sorted()
        if let center, let i = ordered.firstIndex(of: center) { ordered.insert(ordered.remove(at: i), at: 0) }
        let indexOf = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) })
        // Notes that stay on screen keep their place, so narrowing a filter does not scramble the layout.
        let previous = Dictionary(zip(nodes.map(\.path), positions), uniquingKeysWith: { first, _ in first })
        // Anything new starts on a sunflower spiral, so the first layout is the same every time it opens.
        positions = ordered.enumerated().map { i, path in
            previous[path] ?? {
                let radius = 12 * sqrt(CGFloat(i) + 0.5)
                let angle = CGFloat(i) * .pi * (3 - sqrt(5))
                return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
            }()
        }
        nodes = ordered.map { path in
            Node(path: path, title: GraphNaming.title(of: path), isInk: path.lowercased().hasSuffix(".ink"))
        }
        var seen = Set<[Int]>()
        edges = pairs.compactMap { a, b in
            guard let i = indexOf[a], let j = indexOf[b], i != j, seen.insert([min(i, j), max(i, j)]).inserted else { return nil }
            return (i, j)
        }
        for (a, b) in edges { nodes[a].degree += 1; nodes[b].degree += 1 }
        pinned = []
        alpha = previous.isEmpty ? 1 : 0.6
        loads += 1
        lastSent = engine.inbox.push(.load(positions: positions, edges: edges, alpha: alpha))
        tick += 1
    }

    func setGroups(_ groups: [Int?]) {
        guard groups.count == nodes.count else { return }
        for i in nodes.indices { nodes[i].group = groups[i] }
        tick += 1
    }

    /// Runs one simulation step on the engine's actor and copies the result in. The step itself never runs on the main thread.
    func advance() async {
        let frame = await engine.step()
        guard frame.generation == loads, frame.positions.count == positions.count else { return }
        var updated = frame.positions
        for index in pinned { updated[index] = positions[index] }
        positions = updated
        // While commands are still queued, the frame cannot know about them (a pin should wake a settled layout).
        alpha = frame.processed >= lastSent ? frame.alpha : max(frame.alpha, alpha)
        tick += 1
    }

    func pin(_ index: Int, at point: CGPoint) {
        guard positions.indices.contains(index) else { return }
        pinned.insert(index)
        positions[index] = point  // the dot follows the finger immediately; the engine catches up
        alpha = max(alpha, 0.3)
        lastSent = engine.inbox.push(.pin(index, point))
        tick += 1
    }

    func unpin(_ index: Int) {
        pinned.remove(index)
        lastSent = engine.inbox.push(.unpin(index))
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
