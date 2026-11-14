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
    let mode: InkMode

    func makeUIViewController(context: Context) -> InkCanvasController {
        InkCanvasController(model: model)
    }

    func updateUIViewController(_ controller: InkCanvasController, context: Context) {
        controller.apply(generation: generation, paper: paper, showsToolPicker: showsToolPicker, mode: mode)
    }
}

final class InkCanvasController: UIViewController, PKCanvasViewDelegate, UIPencilInteractionDelegate,
    PKToolPickerObserver, UIGestureRecognizerDelegate {
    private let model: InkNoteModel
    private let canvas = PKCanvasView()
    private let paperView = PaperLinesView()
    private let toolPicker = PKToolPicker()
    private let spaceGuide = InsertSpaceGuideView()
    private lazy var insertSpacePan = UIPanGestureRecognizer(target: self, action: #selector(handleInsertSpace(_:)))

    private var mode = InkMode.draw
    /// The tool to restore when leaving lasso or insert-space mode.
    private var drawingTool: PKTool = PKInkingTool(.pen, color: .label, width: 3)
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
    /// The tool to return to when double-tap toggles away from the eraser.
    private var alternateTool: PKTool = PKEraserTool(.vector)

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

        spaceGuide.frame = view.bounds
        spaceGuide.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        spaceGuide.isUserInteractionEnabled = false
        view.addSubview(spaceGuide)

        // Insert space: one finger or the Pencil drags the line; two fingers still scroll.
        insertSpacePan.maximumNumberOfTouches = 1
        insertSpacePan.isEnabled = false
        insertSpacePan.delegate = self
        canvas.addGestureRecognizer(insertSpacePan)

        view.addInteraction(UIPencilInteraction(delegate: self))

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

    func apply(generation: Int, paper: PaperStyle, showsToolPicker: Bool, mode: InkMode) {
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
        if mode != self.mode { setMode(mode) }
    }

    // MARK: Lasso and insert space

    private func setMode(_ newMode: InkMode) {
        if mode == .draw { drawingTool = canvas.tool }
        mode = newMode
        switch newMode {
        case .draw:
            canvas.tool = drawingTool
        case .lasso:
            canvas.tool = PKLassoTool()
        case .insertSpace:
            canvas.tool = drawingTool
        }
        let inserting = newMode == .insertSpace
        insertSpacePan.isEnabled = inserting
        canvas.drawingGestureRecognizer.isEnabled = !inserting
        // While inserting space, a single finger moves the line, so scrolling takes two.
        canvas.panGestureRecognizer.minimumNumberOfTouches = inserting ? 2 : 1
        spaceGuide.showsHint = inserting
    }

    /// Picking a tool in the tool picker goes back to writing.
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        leaveSpecialMode()
    }

    func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
        leaveSpecialMode()
    }

    private func leaveSpecialMode() {
        guard mode != .draw else { return }
        mode = .draw
        insertSpacePan.isEnabled = false
        canvas.drawingGestureRecognizer.isEnabled = true
        canvas.panGestureRecognizer.minimumNumberOfTouches = 1
        spaceGuide.showsHint = false
        // The canvas already follows the picker's new tool.
        DispatchQueue.main.async { self.model.mode = .draw }
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

    // MARK: Gesture delegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === insertSpacePan, spaceDrag == nil {
            spaceTouchStart = touch.location(in: canvas)
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
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

    /// Follows what the user chose in Settings > Apple Pencil.
    private func perform(_ action: UIPencilPreferredAction) {
        switch action {
        case .switchEraser:
            if canvas.tool is PKEraserTool {
                swapTools()
            } else {
                alternateTool = canvas.tool
                canvas.tool = PKEraserTool(.vector)
            }
        case .switchPrevious:
            swapTools()
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            model.showsToolPicker = true
        case .ignore, .runSystemShortcut:
            break
        @unknown default:
            break
        }
    }

    private func swapTools() {
        let current = canvas.tool
        canvas.tool = alternateTool
        alternateTool = current
    }
}

/// The insert-space line and its hint, drawn over the canvas.
final class InsertSpaceGuideView: UIView {
    private let line = UIView()
    private let band = UIView()
    private let hint = UILabel()

    var showsHint = false {
        didSet { hint.isHidden = !showsHint }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        band.backgroundColor = UIColor.tintColor.withAlphaComponent(0.08)
        line.backgroundColor = .tintColor
        hint.text = "Drag down to insert space, up to remove it"
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = .secondaryLabel
        hint.textAlignment = .center
        hint.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.92)
        hint.layer.cornerRadius = 10
        hint.layer.masksToBounds = true
        hint.isHidden = true
        [band, line, hint].forEach(addSubview)
        hide()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = hint.sizeThatFits(CGSize(width: bounds.width - 40, height: 40))
        let top = safeAreaInsets.top + 12
        hint.frame = CGRect(x: (bounds.width - size.width - 24) / 2, y: top, width: size.width + 24, height: size.height + 12)
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
