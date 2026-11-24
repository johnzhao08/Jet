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
/// - Add Text (toolbar): the next tap on the page opens a text editor there. A finger tap on typed
///   text edits it; holding a finger on it and dragging moves it. The keyboard bar has Done and Delete.
/// - Hand (toolbar): a finger, the Pencil or a mouse drag scrolls the page instead of writing. With
///   an attached mouse or trackpad, dragging with the secondary button scrolls it whatever the tool.
struct InkCanvasRepresentable: UIViewControllerRepresentable {
    let model: InkNoteModel
    let root: URL
    /// Set when annotating a PDF: its pages go under the ink.
    var pdf: PDFPages?
    let generation: Int
    let paper: PaperStyle
    let showsToolPicker: Bool
    let tools: [InkPickerTool]
    /// The page zoom (`InkNoteModel.currentZoom`), which the magnifier menu changes.
    var zoom: CGFloat = 0

    func makeUIViewController(context: Context) -> InkCanvasController {
        InkCanvasController(model: model, root: root, tools: tools, pdf: pdf)
    }

    func updateUIViewController(_ controller: InkCanvasController, context: Context) {
        controller.apply(generation: generation, paper: paper, showsToolPicker: showsToolPicker, tools: tools)
        controller.apply(zoom: zoom)
    }
}

final class InkCanvasController: UIViewController, PKCanvasViewDelegate, UIPencilInteractionDelegate,
    PKToolPickerObserver, UIGestureRecognizerDelegate, UITextViewDelegate {
    private let model: InkNoteModel
    private let pdf: PDFPages?
    private let canvas = PKCanvasView()
    private let paperView = PaperLinesView()
    private let pageContent: PageContentView
    private let imageOverlay = ImageSelectionOverlay()
    private let spaceGuide = InsertSpaceGuideView()
    private lazy var insertSpacePan = UIPanGestureRecognizer(target: self, action: #selector(handleInsertSpace(_:)))
    /// A secondary-button (right mouse) drag moves the page around, with any tool.
    private lazy var mousePan = UIPanGestureRecognizer(target: self, action: #selector(handleMousePan(_:)))
    /// The scroll position when a secondary-button drag began.
    private var mousePanStart: CGPoint?
    /// PencilKit's own settings for the canvas's scrolling, put back when the Hand is put down.
    private var scrollDefaults: (touchTypes: [NSNumber], minimumTouches: Int)?
    private lazy var lassoWatcher = TouchWatcher { [weak self] path, touchType in self?.lassoGestureEnded(path, touchType) }

    // The tool picker holds the pens the user picked (Pens & Tools) plus the lasso and Jet's own
    // Insert Space tool, so it shows which one is active, and the Pencil's "switch to previous tool"
    // moves between all of them.
    private var tools: [InkPickerTool]
    private var lassoItem = PKToolPickerLassoItem()
    private var spaceItem = InkCanvasController.makeInsertSpaceItem()
    private var toolPicker: PKToolPicker

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
    private var spaceDrag: (original: PKDrawing, images: [InkImage], texts: [InkText], lineY: CGFloat, maxUp: CGFloat)?
    /// Where the finger or Pencil first touched, in canvas coordinates. A pan is only recognised after
    /// some movement, so measuring from the touch-down keeps the line where the drag really started.
    private var spaceTouchStart: CGPoint?

    /// Pictures on the page, the selected one (being moved or resized) and its frame when a drag began.
    private var images: [InkImage] = []
    private var selectedImageID: String?
    private var imageDragStart: (images: [InkImage], frame: CGRect)?
    private lazy var imageLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleImageLongPress(_:)))
    private lazy var deselectTap = UITapGestureRecognizer(target: self, action: #selector(handleDeselectTap(_:)))

    /// Typed text: the open editor and the text it edits (new text gets its id up front), whether Add
    /// Text is waiting for a tap to place it, and typed text being dragged (its start and the texts then).
    private var textEditor: InkTextEditorView?
    private var editingText: InkText?
    private var placingText = false
    private var textMove: (text: InkText, start: CGPoint, before: [InkText])?
    private lazy var placeTextTap = UITapGestureRecognizer(target: self, action: #selector(handlePlaceTextTap(_:)))
    private lazy var editTextTap = UITapGestureRecognizer(target: self, action: #selector(handleEditTextTap(_:)))
    private var keyboardObserver: NSObjectProtocol?

    private var appliedGeneration = -1
    private var paper = PaperStyle.lined
    private var pickerWanted = true
    private var laidOutWidth: CGFloat = 0
    /// Page height in page points. Only ever grows while open.
    private var pageHeight: CGFloat = 0
    /// Page width in page points: at least `InkDocument.pageWidth`, wider when the view shows more than that.
    private var pageWidth: CGFloat = InkDocument.pageWidth

    init(model: InkNoteModel, root: URL, tools: [InkPickerTool], pdf: PDFPages? = nil) {
        self.model = model
        self.pdf = pdf
        self.tools = tools
        pageContent = PageContentView(root: root)
        toolPicker = PKToolPicker()
        super.init(nibName: nil, bundle: nil)
        toolPicker = makeToolPicker()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if let pdf {
            // PDF pages are white paper, so ink keeps its light-mode colours here even in dark mode.
            overrideUserInterfaceStyle = .light
            view.backgroundColor = .systemGray5
            paperView.isHidden = true
            pageContent.setPDF(pdf)
        }

        paperView.frame = view.bounds
        paperView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        paperView.isUserInteractionEnabled = false
        view.addSubview(paperView)

        canvas.accessibilityIdentifier = "ink-page-canvas"
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
        // Pictures go inside the scroll view, behind PencilKit's own views, so ink draws over them.
        canvas.insertSubview(pageContent, at: 0)

        imageOverlay.frame = view.bounds
        imageOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageOverlay.onDelete = { [weak self] in self?.deleteSelectedImage() }
        imageOverlay.onDone = { [weak self] in self?.selectImage(nil) }
        imageOverlay.box.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleImageMove(_:))))
        imageOverlay.handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleImageResize(_:))))
        view.addSubview(imageOverlay)

        // A finger held on a picture selects it (the Pencil keeps writing over pictures).
        imageLongPress.minimumPressDuration = 0.4
        imageLongPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        imageLongPress.delegate = self
        canvas.addGestureRecognizer(imageLongPress)
        deselectTap.isEnabled = false
        deselectTap.delegate = self
        canvas.addGestureRecognizer(deselectTap)

        // Add Text: the next tap (finger or Pencil) places the text. Ink is off until then.
        placeTextTap.isEnabled = false
        placeTextTap.delegate = self
        canvas.addGestureRecognizer(placeTextTap)
        // A finger tap on typed text edits it (it only takes touches that land on text, so ink never waits for it).
        editTextTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        editTextTap.delegate = self
        canvas.addGestureRecognizer(editTextTap)
        canvas.drawingGestureRecognizer.require(toFail: editTextTap)
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
        ) { [weak self] note in
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            MainActor.assumeIsolated { self?.keyboardMoved(to: frame) }
        }

        configureToolPicker()

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

        // A secondary-button drag (mouse or trackpad) moves the page; a right-click that doesn't move
        // is left to whatever it does. Primary-button drags keep writing.
        mousePan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        mousePan.maximumNumberOfTouches = 1
        mousePan.delegate = self
        canvas.addGestureRecognizer(mousePan)

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
        model.undo = { [weak self] in
            self?.endTextEditing()
            self?.canvas.undoManager?.undo()
        }
        model.insertImage = { [weak self] path, pixels in self?.insertImage(path, pixelSize: pixels) }
        model.redo = { [weak self] in
            self?.endTextEditing()
            self?.canvas.undoManager?.redo()
        }
        model.beginAddingText = { [weak self] in self?.addTextCommand() }
        model.textsEdited = { [weak self] before, name in self?.textsEdited(before: before, name: name) }
        model.textDraftReloaded = { [weak self] draft in self?.textDraftReloaded(draft) }
    }

    deinit {
        if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        showToolPicker(pickerWanted)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        endTextEditing(refocus: false)
        stopPlacingText()
        model.drawingChanged(canvas.drawing)
        model.saveNow()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = canvas.bounds.width
        guard width > 0 else { return }
        if abs(width - laidOutWidth) > 0.5 {
            // First layout, rotation, sidebar or split-view resize: keep the zoom (see `InkNoteModel.zoom(fitting:)`;
            // the plain page extends sideways into a wider view) and stay at the same place on the page.
            let pageY = laidOutWidth > 0 ? max(0, canvas.contentOffset.y) / max(canvas.zoomScale, 0.01) : 0
            laidOutWidth = width
            let fit = width / InkDocument.pageWidth
            model.viewFits(fit)
            // Pinching out past the page's width shows more of a plain page; a PDF's pages stop at the width.
            canvas.minimumZoomScale = pdf == nil ? InkNoteModel.zoomLimits.lowerBound : fit
            canvas.maximumZoomScale = InkNoteModel.zoomLimits.upperBound
            let zoom = min(max(model.zoom(fitting: fit), canvas.minimumZoomScale), canvas.maximumZoomScale)
            canvas.zoomScale = zoom
            updateContentSize()
            canvas.contentOffset = CGPoint(x: 0, y: pageY > 0 ? pageY * zoom : -canvas.adjustedContentInset.top)
        }
        updatePaper()
    }

    // MARK: State from SwiftUI

    /// Zooms to `zoom` from the magnifier menu (or a wider or narrower view), keeping the middle of the
    /// view on the same place on the page. Ignored mid-pinch, which sets the zoom itself when it ends.
    func apply(zoom: CGFloat) {
        guard laidOutWidth > 0, zoom > 0, !canvas.isZooming, !canvas.isZoomBouncing else { return }
        let target = min(max(zoom, canvas.minimumZoomScale), canvas.maximumZoomScale)
        let old = max(canvas.zoomScale, 0.01)
        guard abs(target - old) > 0.001 else {
            // Out of this canvas's range (a PDF can't be smaller than its width): show what it really is.
            if abs(target - zoom) > 0.001 { DispatchQueue.main.async { self.model.setZoom(target) } }
            return
        }
        let size = canvas.bounds.size
        let center = CGPoint(x: (canvas.contentOffset.x + size.width / 2) / old,
                             y: (canvas.contentOffset.y + size.height / 2) / old)
        canvas.zoomScale = target
        updateContentSize()
        layoutTextEditor()
        canvas.contentOffset = clampedOffset(CGPoint(x: center.x * target - size.width / 2,
                                                     y: center.y * target - size.height / 2))
        updatePaper()
        updateImageOverlay()
        if abs(target - zoom) > 0.001 { DispatchQueue.main.async { self.model.setZoom(target) } }
    }

    /// `offset` kept within the page: the canvas's scroll range, insets included.
    private func clampedOffset(_ offset: CGPoint) -> CGPoint {
        let size = canvas.bounds.size
        let inset = canvas.adjustedContentInset
        let content = canvas.contentSize
        let maxX = max(content.width - size.width + inset.right, -inset.left)
        let maxY = max(content.height - size.height + inset.bottom, -inset.top)
        return CGPoint(x: min(max(offset.x, -inset.left), maxX), y: min(max(offset.y, -inset.top), maxY))
    }

    /// A secondary-button drag: the page follows the pointer, within its scroll range. Only scrolls.
    @objc private func handleMousePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            // Throw away any ink the press started.
            canvas.drawingGestureRecognizer.isEnabled = false
            applyModeState()
            mousePanStart = canvas.contentOffset
        case .changed:
            guard let start = mousePanStart else { return }
            let moved = pan.translation(in: view)
            canvas.contentOffset = clampedOffset(CGPoint(x: start.x - moved.x, y: start.y - moved.y))
        default:
            mousePanStart = nil
        }
    }

    func apply(generation: Int, paper: PaperStyle, showsToolPicker: Bool, tools: [InkPickerTool]) {
        loadViewIfNeeded()
        if tools != self.tools {
            self.tools = tools
            rebuildToolPicker()
        }
        if generation != appliedGeneration {
            let reloaded = appliedGeneration >= 0
            appliedGeneration = generation
            if reloaded { dropStaleSnapshots() }
            canvas.drawing = model.drawing
            images = model.images
            selectImage(nil)
            pageContent.setImages(images)
            refreshTexts()
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

    /// The note was replaced from disk (a sync). Undo steps and gestures under way hold the page as it
    /// was, and applying them would put back what the sync replaced, so they are dropped (as on the Mac).
    /// Text being typed carries on, showing the reloaded wording (see `textDraftReloaded`); closing it
    /// records a fresh change against the reloaded page only if something was typed since.
    private func dropStaleSnapshots() {
        canvas.undoManager?.removeAllActions()
        if spaceDrag != nil {
            spaceDrag = nil
            spaceGuide.hide()
        }
        textMove = nil
        imageDragStart = nil
        applyModeState()
    }

    /// The note was reloaded while text is being typed: the open editor takes the text as the reload
    /// left it (another device may have reworded or moved it), right away, so closing or saving can't
    /// put back the old wording. Nil means it was deleted elsewhere: the editor closes, adding nothing.
    private func textDraftReloaded(_ draft: InkText?) {
        guard let editor = textEditor, editingText != nil else { return }
        guard let draft else {
            endTextEditing(commit: false, refocus: editor.isFirstResponder)
            return
        }
        editingText = draft
        if editor.text != draft.text {
            editor.text = draft.text
            editor.applyPageStyle()
            // Its typing steps were for the old wording (the reload drops the page's other steps too).
            editor.undoManager?.removeAllActions()
        }
        layoutTextEditor()
        updateContentSize()
    }

    // MARK: Tools, lasso and insert space

    private func makeToolPicker() -> PKToolPicker {
        lassoItem = PKToolPickerLassoItem()
        spaceItem = Self.makeInsertSpaceItem()
        var items: [PKToolPickerItem] = tools.filter { $0 != .ruler }.map(Self.item)
        items.append(lassoItem)
        if pdf == nil { items.append(spaceItem) }  // a PDF's pages can't make room
        if tools.contains(.ruler) { items.append(PKToolPickerRulerItem()) }
        return PKToolPicker(toolItems: items)
    }

    private static func item(_ tool: InkPickerTool) -> PKToolPickerItem {
        switch tool {
        case .pen: PKToolPickerInkingItem(type: .pen)
        case .monoline: PKToolPickerInkingItem(type: .monoline)
        case .fountainPen: PKToolPickerInkingItem(type: .fountainPen)
        case .marker: PKToolPickerInkingItem(type: .marker)
        case .pencil: PKToolPickerInkingItem(type: .pencil)
        case .watercolor: PKToolPickerInkingItem(type: .watercolor)
        case .crayon: PKToolPickerInkingItem(type: .crayon)
        case .eraser: PKToolPickerEraserItem(type: .vector)
        case .ruler: PKToolPickerRulerItem()
        }
    }

    private func configureToolPicker() {
        toolPicker.stateAutosaveName = "jet.ink.toolpicker"
        toolPicker.addObserver(canvas)
        toolPicker.addObserver(self)
        // A fresh page always starts with a writing tool, never the lasso or insert space.
        if isSpecial(toolPicker.selectedToolItemIdentifier)
            || !toolPicker.toolItems.contains(where: { $0.identifier == toolPicker.selectedToolItemIdentifier }) {
            toolPicker.selectedToolItemIdentifier = toolPicker.toolItems.first?.identifier ?? ""
        }
        currentItemID = toolPicker.selectedToolItemIdentifier
        previousItemID = toolPicker.toolItems.first { $0 is PKToolPickerEraserItem }?.identifier ?? currentItemID
        returnItemID = currentItemID
        mode = .draw
        lassoSelection = nil
        spaceGuide.hint = nil
        applyModeState()
        if model.mode != .draw { model.mode = .draw }
        canvas.tool = toolPicker.selectedTool
    }

    /// The pens changed in Pens & Tools: swap in a picker with the new set, keeping the tool in hand if it's still there.
    private func rebuildToolPicker() {
        let selected = toolPicker.selectedToolItemIdentifier
        toolPicker.setVisible(false, forFirstResponder: canvas)
        toolPicker.removeObserver(canvas)
        toolPicker.removeObserver(self)
        toolPicker = makeToolPicker()
        if !isSpecial(selected), toolPicker.toolItems.contains(where: { $0.identifier == selected }) {
            toolPicker.selectedToolItemIdentifier = selected
        }
        configureToolPicker()
        if view.window != nil { showToolPicker(pickerWanted) }
    }

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
        endTextEditing()
        stopPlacingText()
        switch tool {
        case _ where tool == mode, .draw: if mode == .pan { stopPanning() } else { returnToPreviousTool() }
        case .lasso: selectItem(lassoItem.identifier)
        case .insertSpace: if pdf == nil { selectItem(spaceItem.identifier) }
        case .pan: startPanning()
        }
    }

    /// Picks up the Hand. It isn't a tool picker item, so the pen in hand stays selected underneath, and
    /// picking any tool in the picker puts the Hand down again.
    private func startPanning() {
        if mode == .lasso || mode == .insertSpace { returnToPreviousTool() }
        guard mode == .draw else { return }
        mode = .pan
        lassoSelection = nil
        selectImage(nil)
        spaceGuide.hint = "Hand: drag to move around the page. Tap the hand again to write."
        applyModeState()
        if model.mode != .pan { model.mode = .pan }
    }

    private func stopPanning() {
        guard mode == .pan else { return }
        mode = .draw
        spaceGuide.hint = nil
        applyModeState()
        if model.mode != .draw { model.mode = .draw }
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
            endTextEditing()
            stopPlacingText()
            mode = newMode
            lassoSelection = nil
            selectImage(nil)
            spaceGuide.hint = switch newMode {
            case .lasso: "Lasso: circle handwriting to select it. Tap outside the selection when you're done."
            case .insertSpace: "Insert space: drag down with Apple Pencil to add space, up to remove it."
            case .draw, .pan: nil
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
        let panning = mode == .pan
        insertSpacePan.isEnabled = inserting
        // No ink while text is being placed or typed: a Pencil touch off the editor only finishes it.
        canvas.drawingGestureRecognizer.isEnabled = !inserting && !panning && !placingText && textEditor == nil
        lassoWatcher.isEnabled = mode == .lasso
        // With the Hand nothing on the page can be picked up, and one finger, the Pencil or a mouse drag scrolls.
        imageLongPress.isEnabled = !panning
        let scroll = canvas.panGestureRecognizer
        if panning {
            if scrollDefaults == nil { scrollDefaults = (scroll.allowedTouchTypes, scroll.minimumNumberOfTouches) }
            scroll.allowedTouchTypes = [UITouch.TouchType.direct, .pencil, .indirect, .indirectPointer]
                .map { NSNumber(value: $0.rawValue) }
            scroll.minimumNumberOfTouches = 1
        } else if let defaults = scrollDefaults {
            scrollDefaults = nil
            scroll.allowedTouchTypes = defaults.touchTypes
            scroll.minimumNumberOfTouches = defaults.minimumTouches
        }
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
            let texts = model.texts
            let frames = drawing.strokes.map(\.renderBounds) + images.map(\.frame) + texts.map(\.frame)
            let belowTop = frames.filter { $0.minY >= lineY }.map(\.minY).min() ?? lineY
            let aboveBottom = frames.filter { $0.minY < lineY }.map(\.maxY).max() ?? 0
            let maxUp = max(0, belowTop - max(aboveBottom, 0) - 4)
            spaceDrag = (drawing, images, texts, lineY, maxUp)
            spaceGuide.show(lineAt: start - canvas.contentOffset.y, delta: 0)
        case .changed:
            guard let drag = spaceDrag else { return }
            let delta = max(pan.location(in: canvas).y / zoom - drag.lineY, -drag.maxUp)
            canvas.drawing = Self.shifting(drag.original, below: drag.lineY, by: delta)
            pageContent.setImages(Self.shifting(drag.images, below: drag.lineY, by: delta))
            pageContent.setTexts(Self.shifting(drag.texts, below: drag.lineY, by: delta), hiding: nil)
            spaceGuide.show(lineAt: drag.lineY * zoom - canvas.contentOffset.y, delta: delta * zoom)
        case .ended, .cancelled, .failed:
            spaceGuide.hide()
            guard let drag = spaceDrag else { return }
            spaceDrag = nil
            let delta = max(pan.location(in: canvas).y / zoom - drag.lineY, -drag.maxUp)
            guard pan.state == .ended, abs(delta) >= 1 else {
                canvas.drawing = drag.original
                pageContent.setImages(drag.images)
                refreshTexts()
                return
            }
            let result = PageState(drawing: Self.shifting(drag.original, below: drag.lineY, by: delta),
                                   images: Self.shifting(drag.images, below: drag.lineY, by: delta),
                                   texts: Self.shifting(drag.texts, below: drag.lineY, by: delta))
            apply(result)
            registerUndo(from: PageState(drawing: drag.original, images: drag.images, texts: drag.texts), to: result,
                         name: delta > 0 ? "Insert Space" : "Remove Space")
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

    /// Pictures that start below `lineY` moved down by `delta` (up if negative).
    static func shifting(_ images: [InkImage], below lineY: CGFloat, by delta: CGFloat) -> [InkImage] {
        images.map { image in
            guard image.frame.minY >= lineY else { return image }
            var moved = image
            moved.frame = image.frame.offsetBy(dx: 0, dy: delta)
            return moved
        }
    }

    /// Typed text that starts below `lineY` moved down by `delta` (up if negative).
    static func shifting(_ texts: [InkText], below lineY: CGFloat, by delta: CGFloat) -> [InkText] {
        texts.map { text in
            guard CGFloat(text.y) >= lineY else { return text }
            var moved = text
            moved.y += Double(delta)
            return moved
        }
    }

    /// The page's ink, pictures and typed text, for undo.
    struct PageState {
        var drawing: PKDrawing
        var images: [InkImage]
        var texts: [InkText]
    }

    private var pageState: PageState { PageState(drawing: canvas.drawing, images: images, texts: model.texts) }

    private func apply(_ state: PageState) {
        endTextEditing()
        if state.drawing != canvas.drawing { canvas.drawing = state.drawing }
        model.textsChanged(state.texts)
        refreshTexts()
        setImages(state.images)
    }

    private func setImages(_ newImages: [InkImage]) {
        images = newImages
        if let id = selectedImageID, !images.contains(where: { $0.id == id }) { selectImage(nil) }
        pageContent.setImages(images)
        updateImageOverlay()
        model.imagesChanged(images)
        updateContentSize()
    }

    private func registerUndo(from old: PageState, to new: PageState, name: String) {
        guard let undoManager = canvas.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { controller in
            controller.apply(old)
            controller.registerUndo(from: new, to: old, name: name)
        }
        undoManager.setActionName(name)
    }

    // MARK: Pictures

    /// Puts a picture in the middle of what's on screen, sized to fit comfortably, and selects it.
    private func insertImage(_ path: String, pixelSize: CGSize) {
        let zoom = max(canvas.zoomScale, 0.01)
        let visible = CGRect(x: canvas.contentOffset.x / zoom, y: max(0, canvas.contentOffset.y) / zoom,
                             width: canvas.bounds.width / zoom, height: canvas.bounds.height / zoom)
        let natural = CGSize(width: max(pixelSize.width, 1) / 2, height: max(pixelSize.height, 1) / 2)
        let fit = min(1, 560 / natural.width, (visible.height * 0.6) / natural.height, (InkDocument.pageWidth - 80) / natural.width)
        let size = CGSize(width: max(natural.width * fit, 60), height: max(natural.height * fit, 60 * natural.height / natural.width))
        let origin = CGPoint(x: (InkDocument.pageWidth - size.width) / 2, y: max(16, visible.midY - size.height / 2))
        let image = InkImage(path: path, frame: CGRect(origin: origin, size: size))
        let before = pageState
        setImages(images + [image])
        registerUndo(from: before, to: pageState, name: "Insert Picture")
        selectImage(mode == .pan ? nil : image.id)
    }

    private func selectImage(_ id: String?) {
        selectedImageID = id
        deselectTap.isEnabled = id != nil || textEditor != nil
        updateImageOverlay()
    }

    private func deleteSelectedImage() {
        guard let id = selectedImageID else { return }
        let before = pageState
        selectImage(nil)
        setImages(images.filter { $0.id != id })
        registerUndo(from: before, to: pageState, name: "Delete Picture")
    }

    /// Page rect -> overlay (view) rect.
    private func viewRect(forPage rect: CGRect) -> CGRect {
        let zoom = canvas.zoomScale
        let content = CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
        return canvas.convert(content, to: view)
    }

    private func updateImageOverlay() {
        guard let id = selectedImageID, let frame = pageContent.frame(ofImage: id) else {
            imageOverlay.hide()
            return
        }
        imageOverlay.show(viewRect(forPage: frame))
    }

    private func pageImage(at point: CGPoint) -> InkImage? {
        images.last { $0.frame.contains(point) }
    }

    @objc private func handleImageLongPress(_ press: UILongPressGestureRecognizer) {
        let zoom = max(canvas.zoomScale, 0.01)
        let location = press.location(in: canvas)
        if textMove != nil || press.state == .began {
            if moveText(press, at: CGPoint(x: location.x / zoom, y: location.y / zoom)) { return }
        }
        guard press.state == .began, mode != .insertSpace else { return }
        guard let image = pageImage(at: CGPoint(x: location.x / zoom, y: location.y / zoom)) else { return }
        // Throw away any ink the finger started.
        canvas.drawingGestureRecognizer.isEnabled = false
        applyModeState()
        selectImage(image.id)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @objc private func handleDeselectTap(_ tap: UITapGestureRecognizer) {
        if let editor = textEditor {
            // A tap off the text being typed finishes it.
            if !editor.bounds.contains(tap.location(in: editor)) { endTextEditing() }
            return
        }
        let point = tap.location(in: view)
        if !imageOverlay.box.frame.contains(point) { selectImage(nil) }
    }

    @objc private func handleImageMove(_ pan: UIPanGestureRecognizer) {
        guard let id = selectedImageID, let index = images.firstIndex(where: { $0.id == id }) else { return }
        let zoom = max(canvas.zoomScale, 0.01)
        switch pan.state {
        case .began:
            imageDragStart = (images, images[index].frame)
        case .changed:
            guard let start = imageDragStart else { return }
            let t = pan.translation(in: view)
            var frame = start.frame.offsetBy(dx: t.x / zoom, dy: t.y / zoom)
            frame.origin.x = min(max(frame.minX, -frame.width + 40), InkDocument.pageWidth - 40)
            frame.origin.y = max(frame.minY, 0)
            pageContent.setFrame(frame, ofImage: id)
            updateImageOverlay()
        case .ended, .cancelled:
            finishImageDrag(id)
        default:
            break
        }
    }

    @objc private func handleImageResize(_ pan: UIPanGestureRecognizer) {
        guard let id = selectedImageID, let index = images.firstIndex(where: { $0.id == id }) else { return }
        let zoom = max(canvas.zoomScale, 0.01)
        switch pan.state {
        case .began:
            imageDragStart = (images, images[index].frame)
        case .changed:
            guard let start = imageDragStart else { return }
            // Keeps the picture's proportions; the top-left corner stays put.
            let t = pan.translation(in: view)
            let aspect = start.frame.height / max(start.frame.width, 1)
            let width = min(max(start.frame.width + max(t.x, t.y / max(aspect, 0.01)) / zoom, 40), InkDocument.pageWidth * 1.5)
            let frame = CGRect(x: start.frame.minX, y: start.frame.minY, width: width, height: width * aspect)
            pageContent.setFrame(frame, ofImage: id)
            updateImageOverlay()
        case .ended, .cancelled:
            finishImageDrag(id)
        default:
            break
        }
    }

    private func finishImageDrag(_ id: String) {
        guard let start = imageDragStart, let frame = pageContent.frame(ofImage: id),
              let index = images.firstIndex(where: { $0.id == id }) else { return }
        imageDragStart = nil
        guard frame != start.frame else { return }
        var updated = images
        updated[index].frame = frame
        let before = PageState(drawing: canvas.drawing, images: start.images, texts: model.texts)
        setImages(updated)
        registerUndo(from: before, to: pageState, name: "Move Picture")
    }

    // MARK: Typed text

    private func pagePoint(_ canvasPoint: CGPoint) -> CGPoint {
        let zoom = max(canvas.zoomScale, 0.01)
        return CGPoint(x: canvasPoint.x / zoom, y: canvasPoint.y / zoom)
    }

    /// The Add Text command: wait for a tap to place the text (again: stop waiting, or finish typing).
    private func addTextCommand() {
        if textEditor != nil {
            endTextEditing()
        } else if placingText {
            stopPlacingText()
        } else {
            if mode == .pan { stopPanning() } else if mode != .draw { returnToPreviousTool() }
            selectImage(nil)
            placingText = true
            placeTextTap.isEnabled = true
            spaceGuide.hint = "Add Text: tap the page where the text should go."
            model.isAddingText = true
            applyModeState()
        }
    }

    private func stopPlacingText() {
        guard placingText else { return }
        placingText = false
        placeTextTap.isEnabled = false
        if mode == .draw { spaceGuide.hint = nil }
        model.isAddingText = textEditor != nil
        applyModeState()
    }

    @objc private func handlePlaceTextTap(_ tap: UITapGestureRecognizer) {
        guard placingText else { return }
        let point = pagePoint(tap.location(in: canvas))
        stopPlacingText()
        beginTextEditing(model.text(at: point), at: point)
    }

    @objc private func handleEditTextTap(_ tap: UITapGestureRecognizer) {
        guard let text = model.text(at: pagePoint(tap.location(in: canvas))) else { return }
        beginTextEditing(text, at: text.origin)
    }

    /// Holding a finger on typed text and dragging moves it. Returns whether the press is about text.
    private func moveText(_ press: UILongPressGestureRecognizer, at point: CGPoint) -> Bool {
        switch press.state {
        case .began:
            guard mode == .draw, textEditor == nil, let text = model.text(at: point) else { return false }
            canvas.drawingGestureRecognizer.isEnabled = false
            applyModeState()
            selectImage(nil)
            textMove = (text, point, model.texts)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            guard let move = textMove else { return false }
            // Shown where it would land, rewrapped if it moved right.
            pageContent.showMoved(InkText.moved(move.text, to: CGPoint(x: move.text.x + point.x - move.start.x,
                                                                       y: move.text.y + point.y - move.start.y)))
        default:
            guard let move = textMove else { return false }
            textMove = nil
            let target = CGPoint(x: move.text.x + point.x - move.start.x,
                                 y: InkText.lineAligned(move.text.y + point.y - move.start.y + InkText.lineHeight / 2))
            if press.state == .ended { model.moveText(move.text.id, to: target) }
            refreshTexts()
        }
        return true
    }

    /// A text change made through the model: redraw it and make it undoable.
    private func textsEdited(before: [InkText], name: String) {
        refreshTexts()
        updateContentSize()
        registerUndo(from: PageState(drawing: canvas.drawing, images: images, texts: before), to: pageState, name: name)
    }

    private func refreshTexts() {
        pageContent.setTexts(model.texts, hiding: model.editingTextID)
    }

    /// Opens an editor on `text`, or on new text at page point `point`.
    private func beginTextEditing(_ text: InkText?, at point: CGPoint) {
        endTextEditing()
        let editing: InkText
        if let text {
            editing = text
        } else {
            let placement = InkText.placement(at: point)
            editing = InkText(text: "", origin: placement.origin, width: placement.width)
        }
        editingText = editing
        model.updateTextDraft(editing)
        model.editingTextID = editing.id
        model.isAddingText = true
        refreshTexts()

        let editor = InkTextEditorView()
        editor.text = editing.text
        editor.applyPageStyle()
        editor.delegate = self
        editor.onDone = { [weak self] in self?.endTextEditing() }
        editor.onDelete = { [weak self] in
            self?.textEditor?.text = ""
            self?.endTextEditing()
        }
        textEditor = editor
        canvas.addSubview(editor)
        // PencilKit supplies its own accessibility children. Expose the active text field directly.
        view.accessibilityElements = [editor]
        deselectTap.isEnabled = true
        applyModeState()
        layoutTextEditor()
        editor.becomeFirstResponder()
    }

    /// Closes the editor, making what was typed one undoable change (emptied text is removed), unless
    /// `commit` is false. With `refocus`, the canvas takes focus back (and shows the tool picker); not
    /// when focus already went somewhere else, which it would take away again.
    private func endTextEditing(commit: Bool = true, refocus: Bool = true) {
        guard let editor = textEditor, var text = editingText else { return }
        textEditor = nil
        editingText = nil
        text.text = editor.text
        editor.delegate = nil
        editor.resignFirstResponder()
        editor.removeFromSuperview()
        view.accessibilityElements = nil
        model.updateTextDraft(nil)
        model.textEditorBottom = nil
        model.editingTextID = nil
        model.isAddingText = placingText
        deselectTap.isEnabled = selectedImageID != nil
        applyModeState()
        if commit {
            if model.texts.contains(where: { $0.id == text.id }) {
                model.updateText(text.id, to: text.text)
            } else {
                model.addText(text.text, at: text.origin, id: text.id)
            }
        }
        refreshTexts()
        updateContentSize()
        // Back to writing: the canvas takes focus again, with the tool picker.
        if refocus, view.window != nil { showToolPicker(pickerWanted) }
    }

    /// Keeps the editor's layout in page points so zooming preserves its glyphs and line breaks.
    private func layoutTextEditor() {
        guard let editor = textEditor, let text = editingText else { return }
        let zoom = max(canvas.zoomScale, 0.01)
        let size = InkTextLayout.size(editor.text, width: CGFloat(text.width))
        editor.bounds = CGRect(origin: .zero, size: size)
        editor.center = CGPoint(x: (CGFloat(text.x) + size.width / 2) * zoom, y: (CGFloat(text.y) + size.height / 2) * zoom)
        editor.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        let bottom = CGFloat(text.y) + size.height
        if model.textEditorBottom != bottom { model.textEditorBottom = bottom }
    }

    func textViewDidChange(_ textView: UITextView) {
        guard textView === textEditor, var text = editingText else { return }
        text.text = textView.text
        editingText = text
        model.updateTextDraft(text)
        layoutTextEditor()
        updateContentSize()
        scrollEditorIntoView()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        // The keyboard was put away (or focus went elsewhere): the text is done. If focus went to
        // something else (a search field, say) it stays there; only when nothing took it does the
        // canvas take it back, with the tool picker.
        guard textView === textEditor else { return }
        endTextEditing(refocus: false)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view.window != nil, UIResponder.currentFirstResponder == nil else { return }
            self.showToolPicker(self.pickerWanted)
        }
    }

    /// Keeps the text being typed above the keyboard.
    private func keyboardMoved(to frame: CGRect?) {
        guard let frame, let window = view.window else { return }
        let local = view.convert(frame, from: window.screen.coordinateSpace)
        let overlap = max(0, view.bounds.maxY - local.minY)
        canvas.contentInset.bottom = textEditor == nil ? 0 : overlap
        scrollEditorIntoView()
    }

    private func scrollEditorIntoView() {
        guard let editor = textEditor else { return }
        // The line being typed on, with a little room around it.
        let caret = editor.selectedTextRange.map { editor.caretRect(for: $0.end) } ?? .zero
        let target = editor.convert(caret, to: canvas).insetBy(dx: 0, dy: -24)
        canvas.scrollRectToVisible(target, animated: true)
    }

    // MARK: Multi-finger taps

    @objc private func handleUndoTap() {
        endTextEditing()
        canvas.undoManager?.undo()
    }

    @objc private func handleRedoTap() {
        endTextEditing()
        canvas.undoManager?.redo()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === editTextTap {
            guard mode == .draw, !placingText, textEditor == nil else { return false }
            return model.text(at: pagePoint(touch.location(in: canvas))) != nil
        }
        if gestureRecognizer === lassoWatcher { lassoWatcher.zoom = canvas.zoomScale }
        if gestureRecognizer === insertSpacePan, spaceDrag == nil {
            spaceTouchStart = touch.location(in: canvas)
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        // Only secondary-button (right mouse) drags move the page this way; primary ones write as usual.
        gestureRecognizer === mousePan ? event.buttonMask.contains(.secondary) : true
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
        var bounds = images.reduce(canvas.drawing.bounds) { $0.union($1.frame) }
        bounds = model.texts.reduce(bounds) { $0.union($1.frame) }
        if let draft = model.textDraft { bounds = bounds.union(draft.frame) }
        var inkBottom = bounds.isNull ? 0 : bounds.maxY
        // The open editor, which can be a line or two taller than its text on the page.
        if textEditor != nil, let editorBottom = model.textEditorBottom { inkBottom = max(inkBottom, editorBottom) }
        if let pdf {
            pageHeight = max(pdf.height, inkBottom + 40)
        } else {
            // Always leave most of a screen of fresh paper below the last stroke.
            pageHeight = max(pageHeight, inkBottom + 900, canvas.bounds.height / max(zoom, 0.01) + 300)
        }
        // As wide as the view at this zoom (the plain page extends sideways into it), and wide enough for
        // whatever is already there.
        let visibleWidth = pdf == nil ? canvas.bounds.width / max(zoom, 0.01) : 0
        pageWidth = max(InkDocument.pageWidth, visibleWidth, bounds.isNull || pdf != nil ? 0 : bounds.maxX)
        let size = CGSize(width: pageWidth * zoom, height: pageHeight * zoom)
        if abs(canvas.contentSize.width - size.width) > 0.5 || abs(canvas.contentSize.height - size.height) > 0.5 {
            canvas.contentSize = size
        }
        pageContent.layout(pageSize: CGSize(width: pageWidth, height: pageHeight), zoom: zoom)
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
        updateAccessibilityValue()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updatePaper()
        updateImageOverlay()
        updateAccessibilityValue()
    }

    /// How much is written and where the page is scrolled to, e.g. "3 strokes, scroll y 120".
    private func updateAccessibilityValue() {
        let count = canvas.drawing.strokes.count
        canvas.accessibilityValue = (count == 1 ? "1 stroke" : "\(count) strokes")
            + ", scroll y \(Int(canvas.contentOffset.y.rounded()))"
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        pageContent.layout(pageSize: CGSize(width: pageWidth, height: pageHeight), zoom: canvas.zoomScale)
        layoutTextEditor()
        updatePaper()
        updateImageOverlay()
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        // Writing elsewhere puts the picture down, and finishes typed text.
        if selectedImageID != nil { selectImage(nil) }
        endTextEditing()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        model.setZoom(scale)
        layoutTextEditor()
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

/// The editor for typed text on the page: plain multiline text laid out like `InkTextLayout` draws
/// it (system font, ruled-line spacing) at the canvas's zoom, with Done and Delete above the keyboard.
/// Typing has its own undo history; the canvas records the finished edit as one change.
final class InkTextEditorView: UITextView {
    var onDone: () -> Void = {}
    var onDelete: () -> Void = {}
    private let typingUndo = UndoManager()
    override var undoManager: UndoManager? { typingUndo }

    init() {
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        isScrollEnabled = false
        autocorrectionType = .default
        layer.borderColor = UIColor.tintColor.withAlphaComponent(0.7).cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 3
        isAccessibilityElement = true
        accessibilityIdentifier = "ink-text-editor"
        accessibilityLabel = "Text on the page"

        let bar = UIToolbar()
        let delete = UIBarButtonItem(title: "Delete", image: UIImage(systemName: "trash"),
                                     primaryAction: UIAction { [weak self] _ in self?.onDelete() })
        delete.tintColor = .systemRed
        let done = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.onDone() })
        done.title = "Done"
        bar.items = [delete, .flexibleSpace(), done]
        bar.sizeToFit()
        inputAccessoryView = bar
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The caret only as tall as the type. Each line is a whole ruled line tall with the letters at its
    /// foot (as the page draws them), so the default caret, the full line, would reach up into the line above.
    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        guard let font = typingAttributes[.font] as? UIFont, rect.height > font.lineHeight + 1 else { return rect }
        rect.origin.y = rect.maxY - font.lineHeight
        rect.size.height = font.lineHeight
        return rect
    }

    /// Sets the font and line spacing in page points.
    func applyPageStyle() {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = InkText.lineHeight
        style.maximumLineHeight = InkText.lineHeight
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: InkText.fontSize),
            .paragraphStyle: style,
            .foregroundColor: UIColor.label,
        ]
        let selection = selectedRange
        textStorage.setAttributes(attributes, range: NSRange(location: 0, length: textStorage.length))
        typingAttributes = attributes
        selectedRange = selection
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

private extension UIResponder {
    private static weak var foundFirstResponder: UIResponder?

    /// The app's current first responder, if any.
    static var currentFirstResponder: UIResponder? {
        foundFirstResponder = nil
        UIApplication.shared.sendAction(#selector(reportFirstResponder), to: nil, from: nil, for: nil)
        return foundFirstResponder
    }

    @objc private func reportFirstResponder() {
        UIResponder.foundFirstResponder = self
    }
}
#endif
