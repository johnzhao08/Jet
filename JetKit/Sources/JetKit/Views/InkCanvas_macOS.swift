#if os(macOS)
import SwiftUI
import AppKit
import PencilKit

/// The Mac's writing surface for handwritten notes and PDFs.
///
/// - The page itself (paper, pictures, PDF pages, ink) is still drawn by `InkPagesView` and
///   `PDFPagesView`. This view is a transparent `NSView` laid over it that only takes the pointer:
///   a mouse, a trackpad (pressure on a Force Touch one) or a drawing tablet.
/// - Each press, drag and release becomes one `PKStroke` through `InkStrokeBuilder`, handed to the
///   `InkNoteModel` the way the iPad canvas hands over its drawing, so both save the same file.
/// - While the pointer is down the stroke is previewed here; once it is saved the page redraws it.
/// - Scroll wheel and trackpad scrolling are not handled here, so they reach the page's scroll view.
struct InkSurface: NSViewRepresentable {
    let model: InkNoteModel
    /// View points per page point.
    let scale: CGFloat
    /// The page point under this view's top-left corner.
    let origin: CGPoint
    let tool: InkSurfaceTool
    let swatch: InkSwatch
    let thickness: InkThickness
    let dark: Bool
    /// Changes when the note was reloaded from disk, which ends the undo history.
    let generation: Int

    /// Reads the toolbar's choices from the model, so the page redraws the surface when they change.
    init(writer model: InkNoteModel, scale: CGFloat, origin: CGPoint, dark: Bool) {
        self.model = model
        self.scale = scale
        self.origin = origin
        self.dark = dark
        tool = model.surfaceTool
        swatch = model.surfaceTool == .highlighter ? model.highlighterSwatch : model.penSwatch
        thickness = model.thickness
        generation = model.generation
    }

    func makeNSView(context: Context) -> InkSurfaceView {
        let view = InkSurfaceView(model: model)
        model.undo = { [weak view] in view?.undoLast() }
        model.redo = { [weak view] in view?.redoLast() }
        return view
    }

    func updateNSView(_ view: InkSurfaceView, context: Context) {
        view.configure(scale: scale, origin: origin, tool: tool, swatch: swatch, thickness: thickness,
                       dark: dark, generation: generation)
    }
}

final class InkSurfaceView: NSView {
    private let model: InkNoteModel
    private let history = UndoManager()
    private var observers: [NSObjectProtocol] = []

    private var scale: CGFloat = 1
    private var origin: CGPoint = .zero
    private var tool: InkSurfaceTool = .pen
    private var swatch: InkSwatch = .black
    private var thickness: InkThickness = .medium
    private var dark = false
    private var generation: Int?

    /// The stroke being written: the pointer readings so far, in page points, and what it is written with.
    private var samples: [InkSample] = []
    private var activeTool: InkSurfaceTool?
    /// The inking tool of the stroke on screen, which outlives the press until the page has drawn it.
    private var previewTool: InkSurfaceTool?
    private var activeSwatch: InkSwatch = .black
    private var activeThickness: InkThickness = .medium
    /// The page before this press, to undo back to.
    private var drawingBefore: PKDrawing?
    private var lastEraserPoint: CGPoint = .zero
    /// True while a tablet's eraser end is near the surface.
    private var tabletEraser = false
    private var proximityMonitor: Any?
    /// Bumped to cancel a pending clean-up of the preview.
    private var previewToken = 0

    init(model: InkNoteModel) {
        self.model = model
        super.init(frame: .zero)
        history.groupsByEvent = false
        history.levelsOfUndo = 200
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: history, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUndoState() }
            })
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("ink-surface")
        setAccessibilityLabel("Handwriting")
        setAccessibilityHelp("Press and drag with a mouse, trackpad or pen to write on the page.")
    }

    override func accessibilityValue() -> Any? {
        let count = model.drawing.strokes.count
        return count == 1 ? "1 stroke" : "\(count) strokes"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Configuration

    func configure(scale: CGFloat, origin: CGPoint, tool: InkSurfaceTool, swatch: InkSwatch,
                   thickness: InkThickness, dark: Bool, generation: Int) {
        let toolChanged = tool != self.tool
        self.scale = max(scale, 0.01)
        self.origin = origin
        self.tool = tool
        self.swatch = swatch
        self.thickness = thickness
        self.dark = dark
        if let previous = self.generation, previous != generation {
            // The note was replaced from disk (a sync), so what the history undoes no longer exists.
            history.removeAllActions()
            refreshUndoState()
        }
        self.generation = generation
        if toolChanged { refreshCursor() }
    }

    // MARK: Undo and redo

    override var undoManager: UndoManager? { history }

    func undoLast() { if history.canUndo { history.undo() } }
    func redoLast() { if history.canRedo { history.redo() } }

    private func refreshUndoState() {
        if model.canUndo != history.canUndo { model.canUndo = history.canUndo }
        if model.canRedo != history.canRedo { model.canRedo = history.canRedo }
    }

    /// Makes `new` the page and remembers `old` so it can be undone.
    private func record(from old: PKDrawing, to new: PKDrawing, name: String) {
        history.beginUndoGrouping()
        history.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(old, then: new, name: name) }
        }
        history.setActionName(name)
        history.endUndoGrouping()
    }

    /// Puts `drawing` on the page, registering the way back to `other` (this is both undo and redo).
    private func restore(_ drawing: PKDrawing, then other: PKDrawing, name: String) {
        model.drawingChanged(drawing)
        history.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(other, then: drawing, name: name) }
        }
        history.setActionName(name)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Command-Z and Shift-Command-Z while the page has focus (the Edit menu does the same through `undoManager`).
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.type == .keyDown, window?.firstResponder === self, flags.contains(.command),
              !flags.contains(.option), !flags.contains(.control),
              event.charactersIgnoringModifiers?.lowercased() == "z"
        else { return super.performKeyEquivalent(with: event) }
        if flags.contains(.shift) { redoLast() } else { undoLast() }
        return true
    }

    // MARK: First responder, window and cursor

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, proximityMonitor == nil {
            // A tablet reports which end of the pen is near before any touch: the eraser end erases.
            proximityMonitor = NSEvent.addLocalMonitorForEvents(matching: .tabletProximity) { [weak self] event in
                MainActor.assumeIsolated { self?.handleProximity(event) }
                return event
            }
        } else if window == nil, let monitor = proximityMonitor {
            NSEvent.removeMonitor(monitor)
            proximityMonitor = nil
            tabletEraser = false
        }
    }

    private func handleProximity(_ event: NSEvent) {
        tabletEraser = event.isEnteringProximity && event.pointingDeviceType == .eraser
        refreshCursor()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private var effectiveTool: InkSurfaceTool { tabletEraser ? .eraser : tool }

    private static let eraserCursor: NSCursor = {
        let radius = InkEraser.screenRadius
        let size = NSSize(width: radius * 2 + 4, height: radius * 2 + 4)
        let image = NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            NSColor.white.setStroke()
            circle.lineWidth = 3
            circle.stroke()
            NSColor.black.setStroke()
            circle.lineWidth = 1.2
            circle.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()

    override func cursorUpdate(with event: NSEvent) {
        (effectiveTool == .eraser ? Self.eraserCursor : NSCursor.crosshair).set()
    }

    private func refreshCursor() {
        guard let window else { return }
        let mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if visibleRect.contains(mouse) {
            (effectiveTool == .eraser ? Self.eraserCursor : NSCursor.crosshair).set()
        }
    }

    // MARK: Pointer to page

    /// The pointer reading for `event`, in page points.
    private func sample(from event: NSEvent) -> InkSample {
        let local = convert(event.locationInWindow, from: nil)
        let location = CGPoint(x: min(max(origin.x + local.x / scale, 0), InkDocument.pageWidth),
                               y: max(origin.y + local.y / scale, 0))
        var force: CGFloat?
        var azimuth: CGFloat = 0
        var altitude: CGFloat = .pi / 2
        if event.subtype == .tabletPoint {
            force = CGFloat(event.pressure)
            let tilt = event.tilt
            azimuth = atan2(tilt.y, tilt.x)
            altitude = (.pi / 2) * (1 - min(1, hypot(tilt.x, tilt.y)))
        } else if event.pressure > 0, event.pressure < 1 {
            // A Force Touch trackpad. A mouse reports 0 or 1, which says nothing about how hard it is pressed.
            force = CGFloat(event.pressure)
        }
        return InkSample(location: location, time: event.timestamp, force: force, azimuth: azimuth, altitude: altitude)
    }

    // MARK: Writing

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        previewToken += 1
        clearPreview()
        let point = sample(from: event)
        let chosen = effectiveTool
        activeTool = chosen
        activeSwatch = swatch
        activeThickness = thickness
        drawingBefore = model.drawing
        if chosen == .eraser {
            samples = []
            lastEraserPoint = point.location
            erase(to: point.location)
        } else {
            samples = [point]
            previewTool = chosen
            invalidate(around: [point])
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let activeTool else { return }
        let point = sample(from: event)
        if activeTool == .eraser {
            erase(to: point.location)
        } else {
            let previous = samples.last
            samples.append(point)
            invalidate(around: [previous, point].compactMap { $0 })
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let finished = activeTool, let before = drawingBefore else { return }
        activeTool = nil
        drawingBefore = nil
        if finished == .eraser {
            if model.drawing != before { record(from: before, to: model.drawing, name: "Erase") }
            return
        }
        samples.append(sample(from: event))
        guard let stroke = InkStrokeBuilder.stroke(from: samples, tool: finished, swatch: activeSwatch,
                                                   thickness: activeThickness) else {
            clearPreview()
            return
        }
        var after = before
        after.strokes.append(stroke)
        model.drawingChanged(after)
        record(from: before, to: after, name: finished == .highlighter ? "Highlight" : "Stroke")
        // Keep the preview up until the page has drawn the saved stroke, so it does not blink off.
        previewToken += 1
        let token = previewToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.previewToken == token else { return }
            self.clearPreview()
        }
    }

    private func erase(to point: CGPoint) {
        let radius = InkEraser.screenRadius / scale
        if let erased = InkEraser.erasing(in: model.drawing, from: lastEraserPoint, to: point, radius: radius) {
            model.drawingChanged(erased)
        }
        lastEraserPoint = point
    }

    // MARK: Preview

    private func clearPreview() {
        guard !samples.isEmpty else { return }
        let area = bounds
        samples = []
        previewTool = nil
        setNeedsDisplay(area)
    }

    private func viewPoint(_ sample: InkSample) -> CGPoint {
        CGPoint(x: (sample.location.x - origin.x) * scale, y: (sample.location.y - origin.y) * scale)
    }

    private func invalidate(around points: [InkSample]) {
        let width = activeThickness.width(for: previewTool ?? .pen) * scale * 1.6 + 4
        var rect = CGRect.null
        for point in points { rect = rect.union(CGRect(origin: viewPoint(point), size: .zero)) }
        setNeedsDisplay(rect.insetBy(dx: -width, dy: -width))
    }

    private var previewColor: NSColor {
        // PencilKit shows black ink as white on a dark page; the preview follows.
        activeSwatch == .black && dark ? .white : activeSwatch.platformColor
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let drawn = previewTool, !samples.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let base = activeThickness.width(for: drawn) * scale
        let points = samples.map(viewPoint)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if drawn == .highlighter {
            // One path, so the see-through colour does not darken where the stroke crosses itself.
            context.setStrokeColor(previewColor.withAlphaComponent(0.35).cgColor)
            context.setLineWidth(base)
            context.beginPath()
            context.move(to: points[0])
            points.dropFirst().forEach { context.addLine(to: $0) }
            if points.count == 1 { context.addLine(to: points[0]) }
            context.strokePath()
        } else {
            context.setStrokeColor(previewColor.cgColor)
            if points.count == 1 {
                context.setLineWidth(base)
                context.move(to: points[0])
                context.addLine(to: points[0])
                context.strokePath()
            }
            for index in points.indices.dropFirst() {
                let force = [samples[index - 1].force, samples[index].force].compactMap { $0 }
                let average = force.isEmpty ? nil : force.reduce(0, +) / CGFloat(force.count)
                context.setLineWidth(base * InkStrokeBuilder.widthFactor(force: average))
                context.move(to: points[index - 1])
                context.addLine(to: points[index])
                context.strokePath()
            }
        }
    }
}

// MARK: - Toolbar

/// The Mac toolbar for writing: pen, highlighter and eraser, colour and thickness, undo and redo.
struct InkSurfaceToolbar: ToolbarContent {
    @Bindable var model: InkNoteModel

    private var swatch: Binding<InkSwatch> {
        Binding(
            get: { model.surfaceTool == .highlighter ? model.highlighterSwatch : model.penSwatch },
            set: { if model.surfaceTool == .highlighter { model.highlighterSwatch = $0 } else { model.penSwatch = $0 } }
        )
    }

    private func dot(_ swatch: InkSwatch, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            swatch.platformColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.separatorColor.setStroke()
            let outline = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            outline.lineWidth = 1
            outline.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ForEach(InkSurfaceTool.allCases) { tool in
                Button { model.surfaceTool = tool } label: {
                    Label(tool.label, systemImage: tool.symbol)
                        .symbolVariant(model.surfaceTool == tool ? .fill : .none)
                }
                .tint(model.surfaceTool == tool ? .accentColor : nil)
                .help(tool.detail)
            }
            Menu {
                Picker("Colour", selection: swatch) {
                    ForEach(InkSwatch.choices(for: model.surfaceTool)) { choice in
                        Label { Text(choice.label) } icon: { Image(nsImage: dot(choice, size: 14)) }
                            .tag(choice)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label { Text("Colour") } icon: { Image(nsImage: dot(swatch.wrappedValue, size: 16)) }
            }
            .disabled(!model.surfaceTool.inks)
            .help("Ink colour")
            Menu {
                Picker("Thickness", selection: $model.thickness) {
                    ForEach(InkThickness.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Thickness", systemImage: "lineweight")
            }
            .disabled(!model.surfaceTool.inks)
            .help("Pen and highlighter thickness")
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help("Undo the last stroke")
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .help("Redo")
        }
    }
}

#endif
