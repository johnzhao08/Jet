#if os(iOS)
import SwiftUI
import UIKit
import PencilKit

/// The iPad writing surface.
///
/// - Ink is PencilKit's own `PKCanvasView`, so latency, pressure, tilt, hover and palm rejection are
///   the system's (the same engine as Apple Notes).
/// - The canvas becomes first responder with the system tool picker as soon as the note appears, so
///   the Pencil writes immediately. A finger scrolls and pinches to zoom; "Draw with Finger" is in the
///   tool picker's own menu.
/// - Pencil double-tap and squeeze: while the tool picker is showing, the system handles both and
///   follows the user's choices in Settings > Apple Pencil. With the picker hidden, this controller
///   handles them itself (see `perform(_:)`), so the gestures keep working on a clean page.
struct InkCanvasRepresentable: UIViewControllerRepresentable {
    let model: InkNoteModel
    let generation: Int
    let paper: PaperStyle
    let showsToolPicker: Bool

    func makeUIViewController(context: Context) -> InkCanvasController {
        InkCanvasController(model: model)
    }

    func updateUIViewController(_ controller: InkCanvasController, context: Context) {
        controller.apply(generation: generation, paper: paper, showsToolPicker: showsToolPicker)
    }
}

final class InkCanvasController: UIViewController, PKCanvasViewDelegate, UIPencilInteractionDelegate,
    PKToolPickerObserver, UIGestureRecognizerDelegate {
    private let model: InkNoteModel
    private let canvas = PKCanvasView()
    private let paperView = PaperLinesView()
    private let spaceGuide = InsertSpaceGuideView()
    private lazy var insertSpacePan = UIPanGestureRecognizer(target: self, action: #selector(handleInsertSpace(_:)))
    private lazy var lassoWatcher = TouchWatcher { [weak self] path, touchType in self?.lassoGestureEnded(path, touchType) }

    // The tool picker holds Apple's tools plus the lasso and Jet's own Insert Space tool, so it shows
    // which one is active, and the Pencil's "switch to previous tool" moves between all of them.
    private let lassoItem = PKToolPickerLassoItem()
    private let spaceItem = InkCanvasController.makeInsertSpaceItem()
    private lazy var toolPicker = PKToolPicker(toolItems: [
        PKToolPickerInkingItem(type: .pen),
        PKToolPickerInkingItem(type: .monoline),
        PKToolPickerInkingItem(type: .marker),
        PKToolPickerInkingItem(type: .pencil),
        PKToolPickerEraserItem(type: .vector),
        lassoItem,
        spaceItem,
        PKToolPickerRulerItem(),
    ])

    private var mode = InkMode.draw
    /// The selected tool item, the one before it (for the Pencil's "switch to previous tool" while the
    /// picker is hidden) and the tool to go back to once a lasso or insert-space action is done.
    private var currentItemID = ""
    private var previousItemID = ""
    private var returnItemID = ""
    /// The lasso's outline (page points) while it has a selection, moved along when the selection is dragged.
    private var lassoSelection: [CGPoint]?
    /// The drawing as it was when an insert-space drag began, the line it started at (page points),
    /// and how far the strokes below may move up before they would overlap the strokes above.
    private var spaceDrag: (original: PKDrawing, lineY: CGFloat, maxUp: CGFloat)?
    /// Where the finger or Pencil first touched, in canvas coordinates. A pan is only recognised after
    /// some movement, so measuring from the touch-down keeps the line where the drag really started.
    private var spaceTouchStart: CGPoint?

    private var appliedGeneration = -1
    private var paper = PaperStyle.lined
    private var pickerWanted = true
    private var laidOutWidth: CGFloat = 0
    /// Page height in page points (the page is `InkDocument.pageWidth` wide). Only ever grows while open.
    private var pageHeight: CGFloat = 0

    init(model: InkNoteModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        paperView.frame = view.bounds
        paperView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        paperView.isUserInteractionEnabled = false
        view.addSubview(paperView)

        canvas.frame = view.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = self
        canvas.drawingPolicy = .default
        canvas.alwaysBounceVertical = true
        canvas.showsHorizontalScrollIndicator = false
        canvas.tool = PKInkingTool(.pen, color: .label, width: 3)
        view.addSubview(canvas)

        toolPicker.stateAutosaveName = "jet.ink.toolpicker"
        toolPicker.addObserver(canvas)
        toolPicker.addObserver(self)
        // A fresh page always starts with a writing tool, never the lasso or insert space.
        if isSpecial(toolPicker.selectedToolItemIdentifier) {
            toolPicker.selectedToolItemIdentifier = toolPicker.toolItems.first?.identifier ?? ""
        }
        currentItemID = toolPicker.selectedToolItemIdentifier
        previousItemID = toolPicker.toolItems.first { $0 is PKToolPickerEraserItem }?.identifier ?? currentItemID
        returnItemID = currentItemID

        spaceGuide.frame = view.bounds
        spaceGuide.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        spaceGuide.isUserInteractionEnabled = false
        view.addSubview(spaceGuide)

        // Insert space: the Pencil drags the line, so fingers keep scrolling. (The simulator has no
        // Pencil, so there a finger drags it and scrolling takes two.)
        insertSpacePan.maximumNumberOfTouches = 1
        #if targetEnvironment(simulator)
        insertSpacePan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue),
                                            NSNumber(value: UITouch.TouchType.direct.rawValue)]
        #else
        insertSpacePan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        #endif
        insertSpacePan.isEnabled = false
        insertSpacePan.delegate = self
        canvas.addGestureRecognizer(insertSpacePan)
        // Belt and braces: ink never starts while an insert-space drag could still begin.
        canvas.drawingGestureRecognizer.require(toFail: insertSpacePan)

        // Watches lasso gestures (without taking part in them) to know when the selection is finished.
        lassoWatcher.delegate = self
        lassoWatcher.isEnabled = false
        canvas.addGestureRecognizer(lassoWatcher)

        // Two-finger double tap undoes, three-finger double tap redoes.
        let undoTap = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap))
        undoTap.numberOfTouchesRequired = 2
        undoTap.numberOfTapsRequired = 2
        undoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        undoTap.delegate = self
        canvas.addGestureRecognizer(undoTap)
        let redoTap = UITapGestureRecognizer(target: self, action: #selector(handleRedoTap))
        redoTap.numberOfTouchesRequired = 3
        redoTap.numberOfTapsRequired = 2
        redoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        redoTap.delegate = self
        canvas.addGestureRecognizer(redoTap)

        view.addInteraction(UIPencilInteraction(delegate: self))

        model.toggleTool = { [weak self] tool in self?.toggle(tool) }
        model.undo = { [weak self] in self?.canvas.undoManager?.undo() }
        model.redo = { [weak self] in self?.canvas.undoManager?.redo() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        showToolPicker(pickerWanted)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.drawingChanged(canvas.drawing)
        model.saveNow()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = canvas.bounds.width
        guard width > 0 else { return }
        if abs(width - laidOutWidth) > 0.5 {
            // First layout, rotation or split-view resize: fit the page to the new width and stay at
            // the same place on the page.
            let pageY = laidOutWidth > 0 ? max(0, canvas.contentOffset.y) / max(canvas.zoomScale, 0.01) : 0
            laidOutWidth = width
            let fit = width / InkDocument.pageWidth
            canvas.minimumZoomScale = fit
            canvas.maximumZoomScale = fit * 4
            canvas.zoomScale = fit
            updateContentSize()
            canvas.contentOffset = CGPoint(x: 0, y: pageY > 0 ? pageY * fit : -canvas.adjustedContentInset.top)
        }
        updatePaper()
    }

    // MARK: State from SwiftUI

    func apply(generation: Int, paper: PaperStyle, showsToolPicker: Bool) {
        loadViewIfNeeded()
        if generation != appliedGeneration {
            appliedGeneration = generation
            canvas.drawing = model.drawing
            pageHeight = 0
            updateContentSize()
        }
        if paper != self.paper {
            self.paper = paper
            updatePaper()
        }
        if showsToolPicker != pickerWanted {
            pickerWanted = showsToolPicker
            if view.window != nil { showToolPicker(showsToolPicker) }
        }
    }

    // MARK: Tools, lasso and insert space

    private static func makeInsertSpaceItem() -> PKToolPickerCustomItem {
        var configuration = PKToolPickerCustomItem.Configuration(identifier: "jet.insert-space", name: "Insert Space")
        configuration.imageProvider = { _ in InsertSpaceToolImage.image }
        configuration.allowsColorSelection = false
        configuration.toolAttributeControls = []
        return PKToolPickerCustomItem(configuration: configuration)
    }

    private func isSpecial(_ identifier: String) -> Bool {
        identifier == lassoItem.identifier || identifier == spaceItem.identifier
    }

    /// The toolbar's lasso and insert-space buttons: turn that tool on, or off again if it's on.
    private func toggle(_ tool: InkMode) {
        switch tool {
        case _ where tool == mode, .draw: returnToPreviousTool()
        case .lasso: selectItem(lassoItem.identifier)
        case .insertSpace: selectItem(spaceItem.identifier)
        }
    }

    private func selectItem(_ identifier: String) {
        guard !identifier.isEmpty, identifier != toolPicker.selectedToolItemIdentifier else { return }
        toolPicker.selectedToolItemIdentifier = identifier
        toolPickerSelectedToolItemDidChange(toolPicker)
    }

    /// Goes back to the tool used before the lasso or insert space.
    private func returnToPreviousTool() {
        lassoSelection = nil
        selectItem(returnItemID)
    }

    /// The picker's selection is the single source of truth for which tool is active.
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        let identifier = toolPicker.selectedToolItemIdentifier
        guard identifier != currentItemID else {
            applyModeState()
            return
        }
        if !isSpecial(identifier), !identifier.isEmpty {
            returnItemID = identifier
        } else if !isSpecial(currentItemID) {
            returnItemID = currentItemID
        }
        previousItemID = currentItemID
        currentItemID = identifier

        let newMode: InkMode = identifier == lassoItem.identifier ? .lasso
            : identifier == spaceItem.identifier ? .insertSpace : .draw
        if newMode != mode {
            mode = newMode
            lassoSelection = nil
            spaceGuide.hint = switch newMode {
            case .lasso: "Lasso: circle handwriting to select it. Tap outside the selection when you're done."
            case .insertSpace: "Insert space: drag down with Apple Pencil to add space, up to remove it."
            case .draw: nil
            }
        }
        applyModeState()
        // PencilKit updates the canvas from the picker too, sometimes after us; settle it again afterwards.
        DispatchQueue.main.async { self.applyModeState() }
        if model.mode != newMode { model.mode = newMode }
    }

    /// Which gestures are live for the current mode.
    private func applyModeState() {
        let inserting = mode == .insertSpace
        insertSpacePan.isEnabled = inserting
        canvas.drawingGestureRecognizer.isEnabled = !inserting
        lassoWatcher.isEnabled = mode == .lasso
        #if targetEnvironment(simulator)
        canvas.panGestureRecognizer.minimumNumberOfTouches = inserting ? 2 : 1
        #endif
    }

    /// A lasso gesture on the page finished (a drag or a tap, in page points).
    private func lassoGestureEnded(_ path: [CGPoint], _ touchType: UITouch.TouchType) {
        guard mode == .lasso, let start = path.first, let end = path.last else { return }
        // Fingers only lasso when they draw; otherwise they were scrolling.
        let fingersDraw = canvas.drawingPolicy == .anyInput
            || (canvas.drawingPolicy == .default && !UIPencilInteraction.prefersPencilOnlyDrawing)
        guard touchType == .pencil || fingersDraw else { return }
        let length = zip(path, path.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        let isTap = length * max(canvas.zoomScale, 0.01) < 12

        if let selection = lassoSelection, Self.polygon(selection, contains: start) {
            // Dragging the selection moves it; a tap on it opens the edit menu.
            if !isTap {
                lassoSelection = selection.map { CGPoint(x: $0.x + end.x - start.x, y: $0.y + end.y - start.y) }
            }
        } else if isTap {
            // A tap away from the selection drops it: the lasso is done.
            returnToPreviousTool()
        } else {
            lassoSelection = path
        }
    }

    static func polygon(_ polygon: [CGPoint], contains point: CGPoint) -> Bool {
        guard polygon.count > 2 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    @objc private func handleInsertSpace(_ pan: UIPanGestureRecognizer) {
        let zoom = max(canvas.zoomScale, 0.01)
        switch pan.state {
        case .began:
            let start = spaceTouchStart?.y ?? (pan.location(in: canvas).y - pan.translation(in: canvas).y)
            let lineY = start / zoom
            let drawing = canvas.drawing
            let below = drawing.strokes.filter { $0.renderBounds.minY >= lineY }
            let above = drawing.strokes.filter { $0.renderBounds.minY < lineY }
            let belowTop = below.map(\.renderBounds.minY).min() ?? lineY
            let aboveBottom = above.map(\.renderBounds.maxY).max() ?? 0
            let maxUp = max(0, belowTop - max(aboveBottom, 0) - 4)
            spaceDrag = (drawing, lineY, maxUp)
            spaceGuide.show(lineAt: start - canvas.contentOffset.y, delta: 0)
        case .changed:
            guard let drag = spaceDrag else { return }
            let delta = max(pan.location(in: canvas).y / zoom - drag.lineY, -drag.maxUp)
            canvas.drawing = Self.shifting(drag.original, below: drag.lineY, by: delta)
            spaceGuide.show(lineAt: drag.lineY * zoom - canvas.contentOffset.y, delta: delta * zoom)
        case .ended, .cancelled, .failed:
            spaceGuide.hide()
            guard let drag = spaceDrag else { return }
            spaceDrag = nil
            let delta = max(pan.location(in: canvas).y / zoom - drag.lineY, -drag.maxUp)
            guard pan.state == .ended, abs(delta) >= 1 else {
                canvas.drawing = drag.original
                return
            }
            let result = Self.shifting(drag.original, below: drag.lineY, by: delta)
            canvas.drawing = result
            registerUndo(from: drag.original, to: result, name: delta > 0 ? "Insert Space" : "Remove Space")
            updateContentSize()
            // One drag per use, then back to writing.
            returnToPreviousTool()
        default:
            break
        }
    }

    /// Every stroke that starts below `lineY` moved down by `delta` page points (up if negative).
    static func shifting(_ drawing: PKDrawing, below lineY: CGFloat, by delta: CGFloat) -> PKDrawing {
        guard delta != 0 else { return drawing }
        let move = CGAffineTransform(translationX: 0, y: delta)
        return PKDrawing(strokes: drawing.strokes.map { stroke in
            guard stroke.renderBounds.minY >= lineY else { return stroke }
            var moved = stroke
            moved.transform = stroke.transform.concatenating(move)
            return moved
        })
    }

    private func registerUndo(from old: PKDrawing, to new: PKDrawing, name: String) {
        guard let undoManager = canvas.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { controller in
            controller.canvas.drawing = old
            controller.registerUndo(from: new, to: old, name: name)
        }
        undoManager.setActionName(name)
    }

    // MARK: Multi-finger taps

    @objc private func handleUndoTap() {
        canvas.undoManager?.undo()
    }

    @objc private func handleRedoTap() {
        canvas.undoManager?.redo()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === lassoWatcher { lassoWatcher.zoom = canvas.zoomScale }
        if gestureRecognizer === insertSpacePan, spaceDrag == nil {
            spaceTouchStart = touch.location(in: canvas)
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Let the taps be seen alongside scrolling and zooming, which also start with two fingers.
        true
    }

    private func showToolPicker(_ visible: Bool) {
        toolPicker.setVisible(visible, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
    }

    // MARK: Page geometry

    private func updateContentSize() {
        guard laidOutWidth > 0 else { return }
        let zoom = canvas.zoomScale
        let bounds = canvas.drawing.bounds
        let inkBottom = bounds.isNull ? 0 : bounds.maxY
        // Always leave most of a screen of fresh paper below the last stroke.
        pageHeight = max(pageHeight, inkBottom + 900, canvas.bounds.height / max(zoom, 0.01) + 300)
        let size = CGSize(width: InkDocument.pageWidth * zoom, height: pageHeight * zoom)
        if abs(canvas.contentSize.width - size.width) > 0.5 || abs(canvas.contentSize.height - size.height) > 0.5 {
            canvas.contentSize = size
        }
    }

    private func updatePaper() {
        paperView.update(style: paper, zoom: canvas.zoomScale, offset: canvas.contentOffset)
    }

    // MARK: PKCanvasViewDelegate / UIScrollViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        // Deleting or cutting the lassoed handwriting from its menu ends the lasso too.
        if mode == .lasso, lassoSelection != nil, canvasView.drawing.strokes.count < model.drawing.strokes.count {
            DispatchQueue.main.async { self.returnToPreviousTool() }
        }
        model.drawingChanged(canvasView.drawing)
        updateContentSize()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updatePaper()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updatePaper()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        updateContentSize()
        updatePaper()
    }

    // MARK: Apple Pencil double-tap and squeeze

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        // The visible system tool picker already responds to double-tap; acting here too would undo it.
        guard !toolPicker.isVisible else { return }
        perform(UIPencilInteraction.preferredTapAction)
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended, !toolPicker.isVisible else { return }
        perform(UIPencilInteraction.preferredSqueezeAction)
    }

    /// Follows what the user chose in Settings > Apple Pencil (used while the tool picker is hidden;
    /// the visible picker handles the Pencil itself, lasso and Insert Space included).
    private func perform(_ action: UIPencilPreferredAction) {
        switch action {
        case .switchEraser:
            let eraser = toolPicker.toolItems.first { $0 is PKToolPickerEraserItem }?.identifier ?? ""
            selectItem(currentItemID == eraser ? previousItemID : eraser)
        case .switchPrevious:
            selectItem(previousItemID)
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            model.showsToolPicker = true
        case .ignore, .runSystemShortcut:
            break
        @unknown default:
            break
        }
    }
}

/// Follows single-touch gestures on the canvas without taking part in them: reports each finished
/// touch's path (in page points) so the controller knows what the lasso did.
final class TouchWatcher: UIGestureRecognizer {
    var zoom: CGFloat = 1
    private let onEnd: ([CGPoint], UITouch.TouchType) -> Void
    private var path: [CGPoint] = []
    private var touchType = UITouch.TouchType.direct
    private var tracking = false

    init(onEnd: @escaping ([CGPoint], UITouch.TouchType) -> Void) {
        self.onEnd = onEnd
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let all = event.allTouches?.count ?? touches.count
        guard all == 1, let touch = touches.first else {
            tracking = false  // two fingers: scrolling or zooming
            return
        }
        tracking = true
        touchType = touch.type
        path = [point(touch)]
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracking, let touch = touches.first else { return }
        path.append(point(touch))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if tracking, let touch = touches.first {
            path.append(point(touch))
            onEnd(path, touchType)
        }
        tracking = false
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        tracking = false
        state = .failed
    }

    private func point(_ touch: UITouch) -> CGPoint {
        let location = touch.location(in: view)
        return CGPoint(x: location.x / max(zoom, 0.01), y: location.y / max(zoom, 0.01))
    }
}

/// The Insert Space tool as drawn in the tool picker: a slim tool with an up-and-down arrow.
enum InsertSpaceToolImage {
    static let image: UIImage = {
        let size = CGSize(width: 40, height: 116)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let body = UIBezierPath(roundedRect: CGRect(x: 6, y: 10, width: 28, height: 120), cornerRadius: 9)
            UIColor.white.setFill()
            body.fill()
            UIColor.systemGray3.setStroke()
            body.lineWidth = 1
            body.stroke()
            let symbol = UIImage(systemName: "arrow.up.and.down",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))?
                .withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
            symbol?.draw(in: CGRect(x: 10, y: 22, width: 20, height: 26))
            UIColor.systemBlue.setFill()
            UIBezierPath(rect: CGRect(x: 6, y: 58, width: 28, height: 4)).fill()
        }
    }()
}

/// The insert-space line and its hint, drawn over the canvas.
final class InsertSpaceGuideView: UIView {
    private let line = UIView()
    private let band = UIView()
    private let hintLabel = UILabel()

    var hint: String? {
        didSet {
            hintLabel.text = hint
            hintLabel.isHidden = hint == nil
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        band.backgroundColor = UIColor.tintColor.withAlphaComponent(0.08)
        line.backgroundColor = .tintColor
        hintLabel.font = .preferredFont(forTextStyle: .footnote)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .center
        hintLabel.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.92)
        hintLabel.layer.cornerRadius = 10
        hintLabel.layer.masksToBounds = true
        hintLabel.isHidden = true
        [band, line, hintLabel].forEach(addSubview)
        hide()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = hintLabel.sizeThatFits(CGSize(width: bounds.width - 40, height: 40))
        let top = safeAreaInsets.top + 12
        hintLabel.frame = CGRect(x: (bounds.width - size.width - 24) / 2, y: top, width: size.width + 24, height: size.height + 12)
    }

    /// `lineY` is where the drag started, `delta` how far it has moved, both in view points.
    func show(lineAt lineY: CGFloat, delta: CGFloat) {
        line.isHidden = false
        band.isHidden = delta == 0
        line.frame = CGRect(x: 0, y: lineY + max(delta, 0) - 1, width: bounds.width, height: 2)
        band.frame = CGRect(x: 0, y: min(lineY, lineY + delta), width: bounds.width, height: abs(delta))
    }

    func hide() {
        line.isHidden = true
        band.isHidden = true
    }
}

/// Ruled or squared paper behind the transparent canvas. Lines are a handful of reused layers
/// positioned from the canvas's scroll offset and zoom, so they track the ink exactly and cost nothing.
final class PaperLinesView: UIView {
    private var horizontal: [CALayer] = []
    private var vertical: [CALayer] = []

    func update(style: PaperStyle, zoom: CGFloat, offset: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let step = InkDocument.lineSpacing * zoom
        let color = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        var usedHorizontal = 0
        var usedVertical = 0

        if style != .blank, step > 4 {
            var k = max(1, Int((offset.y / step).rounded(.up)))
            while CGFloat(k) * step - offset.y <= bounds.height, usedHorizontal < 400 {
                let layer = dequeue(&horizontal, at: usedHorizontal)
                layer.backgroundColor = color
                layer.frame = CGRect(x: 0, y: (CGFloat(k) * step - offset.y).rounded(), width: bounds.width, height: 1)
                usedHorizontal += 1
                k += 1
            }
            if style == .grid {
                var j = max(1, Int((offset.x / step).rounded(.up)))
                while CGFloat(j) * step - offset.x <= bounds.width, usedVertical < 400 {
                    let layer = dequeue(&vertical, at: usedVertical)
                    layer.backgroundColor = color
                    layer.frame = CGRect(x: (CGFloat(j) * step - offset.x).rounded(), y: 0, width: 1, height: bounds.height)
                    usedVertical += 1
                    j += 1
                }
            }
        }
        for index in usedHorizontal..<horizontal.count { horizontal[index].isHidden = true }
        for index in usedVertical..<vertical.count { vertical[index].isHidden = true }
    }

    private func dequeue(_ pool: inout [CALayer], at index: Int) -> CALayer {
        if index == pool.count {
            let created = CALayer()
            layer.addSublayer(created)
            pool.append(created)
        }
        pool[index].isHidden = false
        return pool[index]
    }
}
#endif
