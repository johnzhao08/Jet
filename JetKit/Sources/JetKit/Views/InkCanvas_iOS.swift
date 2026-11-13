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

final class InkCanvasController: UIViewController, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    private let model: InkNoteModel
    private let canvas = PKCanvasView()
    private let paperView = PaperLinesView()
    private let toolPicker = PKToolPicker()

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
