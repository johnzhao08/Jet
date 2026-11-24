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
/// - The Hand tool, or a drag with the right mouse button whatever the tool, moves the page around by
///   scrolling that same scroll view, so zoom and scroll limits stay its own and nothing on the page
///   changes. A right-click that doesn't move still opens the context menu.
/// - With the Add Text tool, a click opens a text editor (an `NSTextView`) on the page at that spot,
///   or on the typed text clicked; dragging typed text moves it. Right-clicking typed text with any
///   tool offers Edit Text and Delete Text. The page draws committed text; the editor shows the text
///   being typed, laid out the same way (`InkTextLayout`).
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
        model.textsEdited = { [weak view, weak model] before, name in
            guard let view, let model else { return }
            view.recordTexts(from: before, to: model.texts, name: name)
        }
        model.beginAddingText = { [weak model] in model?.surfaceTool = .text }
        return view
    }

    func updateNSView(_ view: InkSurfaceView, context: Context) {
        view.configure(scale: scale, origin: origin, tool: tool, swatch: swatch, thickness: thickness,
                       dark: dark, generation: generation)
    }
}

final class InkSurfaceView: NSView, NSTextViewDelegate {
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

    /// The open text editor and the text it edits (its id is made up front for new text).
    private var textEditor: NSTextView?
    private var editingText: InkText?
    /// Typing's own undo history, separate from the page's: the whole edit becomes one page undo when it closes.
    private let editorUndo = UndoManager()
    /// Typed text being pressed on with Add Text: the text, where the press began, the page's texts
    /// then, and whether it has been dragged (a press without a drag edits it instead).
    private var textDrag: (text: InkText, start: CGPoint, before: [InkText], moved: Bool)?
    /// A drag moving the page around: where it began (window coordinates) and the page's scroll
    /// position then (its clip view's bounds origin).
    private var pan: (start: NSPoint, origin: NSPoint)?
    /// A right-button press that hasn't moved yet: moving makes it a pan, releasing it in place a right-click.
    private var rightDown: NSEvent?

    init(model: InkNoteModel) {
        self.model = model
        super.init(frame: .zero)
        layerContentsRedrawPolicy = .duringViewResize
        model.textDraftReloaded = { [weak self] draft in self?.textDraftReloaded(draft) }
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
        let strokes = count == 1 ? "1 stroke" : "\(count) strokes"
        let texts = model.texts.count
        guard texts > 0 else { return strokes }
        return strokes + (texts == 1 ? ", 1 text box" : ", \(texts) text boxes")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Configuration

    func configure(scale: CGFloat, origin: CGPoint, tool: InkSurfaceTool, swatch: InkSwatch,
                   thickness: InkThickness, dark: Bool, generation: Int) {
        let scale = max(scale, 0.01)
        if !samples.isEmpty, scale != self.scale || origin != self.origin || dark != self.dark {
            needsDisplay = true
        }
        let toolChanged = tool != self.tool
        self.scale = scale
        self.origin = origin
        self.tool = tool
        self.swatch = swatch
        self.thickness = thickness
        self.dark = dark
        if let previous = self.generation, previous != generation {
            // The note was replaced from disk (a sync), so what the history undoes no longer exists.
            history.removeAllActions()
            refreshUndoState()
            // A text drag under way would put back the texts from before the sync when dropped.
            textDrag = nil
        }
        self.generation = generation
        if toolChanged {
            if tool != .text { endTextEditing() }
            refreshCursor()
        }
        layoutTextEditor()
    }

    // MARK: Undo and redo

    override var undoManager: UndoManager? { history }

    func undoLast() {
        endTextEditing()
        if history.canUndo { history.undo() }
    }

    func redoLast() {
        endTextEditing()
        if history.canRedo { history.redo() }
    }

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

    /// Registers a change to the typed text (made through the model) so it can be undone.
    func recordTexts(from old: [InkText], to new: [InkText], name: String) {
        history.beginUndoGrouping()
        history.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restoreTexts(old, then: new, name: name) }
        }
        history.setActionName(name)
        history.endUndoGrouping()
    }

    private func restoreTexts(_ texts: [InkText], then other: [InkText], name: String) {
        model.textsChanged(texts)
        history.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restoreTexts(other, then: texts, name: name) }
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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // Leaving the page (closing the note) keeps what was being typed.
        if newWindow == nil { endTextEditing() }
        super.viewWillMove(toWindow: newWindow)
    }

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

    /// The tool a press uses. The Hand stays the Hand even with a tablet's eraser end near, so it never changes the page.
    private var effectiveTool: InkSurfaceTool { tool == .hand ? .hand : (tabletEraser ? .eraser : tool) }

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

    private var cursor: NSCursor {
        if pan != nil { return .closedHand }
        return switch effectiveTool {
        case .eraser: Self.eraserCursor
        case .text: .iBeam
        case .hand: .openHand
        default: .crosshair
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    private func refreshCursor() {
        guard let window else { return }
        let mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if visibleRect.contains(mouse) { cursor.set() }
    }

    // MARK: Trackpad zoom

    /// Pinching on the trackpad zooms the page, like the magnifier menu.
    override func magnify(with event: NSEvent) {
        model.setZoom(model.currentZoom * (1 + event.magnification))
    }

    // MARK: Moving the page around

    /// Starts moving the page from window point `start`, if it is in a scroll view.
    private func beginPan(at start: NSPoint) {
        guard let clip = enclosingScrollView?.contentView else { return }
        pan = (start, clip.bounds.origin)
        refreshCursor()
    }

    /// Scrolls so the page point that was under the pointer when the pan began is under it again, as far
    /// as the page reaches (sideways only where it is wider than the window).
    private func continuePan(_ event: NSEvent) {
        guard let pan, let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        // Both converted with the clip view as it is now, so its current scroll position cancels out.
        let from = clip.convert(pan.start, from: nil), to = clip.convert(event.locationInWindow, from: nil)
        var proposed = clip.bounds
        proposed.origin = NSPoint(x: pan.origin.x - (to.x - from.x), y: pan.origin.y - (to.y - from.y))
        let origin = clip.constrainBoundsRect(proposed).origin
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func endPan() {
        guard pan != nil else { return }
        pan = nil
        refreshCursor()
    }

    override func rightMouseDown(with event: NSEvent) {
        // Held until it moves (a pan) or is released in place (the context menu, see `rightMouseUp`).
        rightDown = event
    }

    override func rightMouseDragged(with event: NSEvent) {
        if let down = rightDown {
            let start = down.locationInWindow, now = event.locationInWindow
            guard hypot(now.x - start.x, now.y - start.y) >= 3 else { return }
            rightDown = nil
            beginPan(at: start)
        }
        continuePan(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if let down = rightDown {
            // A right-click without a drag: the context menu, as the press would have opened it.
            rightDown = nil
            super.rightMouseDown(with: down)
        } else {
            endPan()
        }
    }

    // MARK: Pointer to page

    /// The pointer reading for `event`, in page points.
    private func sample(from event: NSEvent) -> InkSample {
        let local = convert(event.locationInWindow, from: nil)
        // Up to the right edge of the surface, which spans the page however wide the window shows it.
        let right = origin.x + max(bounds.width / scale, InkDocument.pageWidth)
        let location = CGPoint(x: min(max(origin.x + local.x / scale, 0), right),
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
        if effectiveTool == .hand {
            // Moving around only: no text editing or ink (choosing the Hand closed any open editor).
            window?.makeFirstResponder(self)
            beginPan(at: event.locationInWindow)
            return
        }
        let wasEditing = textEditor != nil
        window?.makeFirstResponder(self)
        endTextEditing()
        if effectiveTool == .text {
            // A click while typing just finishes the text; the next one places or picks text.
            guard !wasEditing else { return }
            let point = sample(from: event).location
            if let text = model.text(at: point) {
                textDrag = (text, point, model.texts, false)
            } else {
                beginTextEditing(nil, at: point)
            }
            return
        }
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
        if pan != nil {
            continuePan(event)
            return
        }
        if var drag = textDrag {
            let point = sample(from: event).location
            let dx = point.x - drag.start.x, dy = point.y - drag.start.y
            guard drag.moved || hypot(dx, dy) * scale >= 3 else { return }
            drag.moved = true
            textDrag = drag
            // Live, without undo; the drop makes it one "Move Text". Shown rewrapped if it moved right.
            model.textsChanged(drag.before.map { text in
                guard text.id == drag.text.id else { return text }
                return InkText.moved(text, to: CGPoint(x: drag.text.x + dx, y: drag.text.y + dy))
            })
            return
        }
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
        if pan != nil {
            endPan()
            return
        }
        if let drag = textDrag {
            textDrag = nil
            if drag.moved {
                let point = sample(from: event).location
                let target = CGPoint(x: drag.text.x + point.x - drag.start.x,
                                     y: InkText.lineAligned(drag.text.y + point.y - drag.start.y + InkText.lineHeight / 2))
                model.textsChanged(drag.before)
                model.moveText(drag.text.id, to: target)
            } else {
                beginTextEditing(drag.text, at: drag.start)
            }
            return
        }
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

    // MARK: Typed text

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = sample(from: event).location
        guard textEditor == nil, let text = model.text(at: point) else { return super.menu(for: event) }
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit Text", action: #selector(editTextFromMenu(_:)), keyEquivalent: "")
        edit.representedObject = text.id
        edit.target = self
        let delete = NSMenuItem(title: "Delete Text", action: #selector(deleteTextFromMenu(_:)), keyEquivalent: "")
        delete.representedObject = text.id
        delete.target = self
        menu.items = [edit, delete]
        return menu
    }

    @objc private func editTextFromMenu(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let text = model.texts.first(where: { $0.id == id }) else { return }
        beginTextEditing(text, at: text.origin)
    }

    @objc private func deleteTextFromMenu(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        model.removeText(id)
    }

    /// Opens an editor on `text`, or on new text at page point `point`.
    func beginTextEditing(_ text: InkText?, at point: CGPoint) {
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

        let editor = NSTextView(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.wantsLayer = true
        editor.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        editor.layer?.borderWidth = 1
        editor.layer?.cornerRadius = 3
        editor.setAccessibilityIdentifier("ink-text-editor")
        editor.setAccessibilityLabel("Text on the page")
        editor.string = editing.text
        editor.delegate = self
        textEditor = editor
        editorUndo.removeAllActions()
        addSubview(editor)
        layoutTextEditor()
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    /// Closes the editor, making what was typed one undoable change (emptied text is removed), unless
    /// `commit` is false.
    func endTextEditing(commit: Bool = true) {
        guard let editor = textEditor, var text = editingText else { return }
        textEditor = nil
        editingText = nil
        text.text = editor.string
        editor.delegate = nil
        if window?.firstResponder === editor { window?.makeFirstResponder(self) }
        editor.removeFromSuperview()
        model.updateTextDraft(nil)
        model.textEditorBottom = nil
        model.editingTextID = nil
        model.isAddingText = false
        guard commit else { return }
        if model.texts.contains(where: { $0.id == text.id }) {
            model.updateText(text.id, to: text.text)
        } else {
            model.addText(text.text, at: text.origin, id: text.id)
        }
    }

    /// Keeps the editor's layout in page points so zooming preserves its glyphs and line breaks.
    private func layoutTextEditor() {
        guard let editor = textEditor, let text = editingText else { return }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = InkText.lineHeight
        style.maximumLineHeight = InkText.lineHeight
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: InkText.fontSize),
            .paragraphStyle: style,
            .foregroundColor: NSColor.textColor,
        ]
        if editor.typingAttributes[.font] as? NSFont != attributes[.font] as? NSFont {
            editor.typingAttributes = attributes
            editor.defaultParagraphStyle = style
            if let storage = editor.textStorage {
                storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            }
        }
        let size = InkTextLayout.size(editor.string, width: CGFloat(text.width))
        editor.textContainer?.containerSize = CGSize(width: size.width, height: .greatestFiniteMagnitude)
        editor.frame = CGRect(x: (CGFloat(text.x) - origin.x) * scale, y: (CGFloat(text.y) - origin.y) * scale,
                              width: size.width * scale, height: size.height * scale)
        editor.bounds = CGRect(origin: .zero, size: size)
        // The page grows to fit it. Told after this update, since this runs while SwiftUI lays the page out.
        let bottom = CGFloat(text.y) + size.height
        if model.textEditorBottom != bottom {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.textEditor === editor, self.model.textEditorBottom != bottom else { return }
                self.model.textEditorBottom = bottom
                // Once the page has grown, keep the line being typed in view (at the end of the page too).
                DispatchQueue.main.async { [weak editor] in
                    guard let editor else { return }
                    editor.scrollRangeToVisible(editor.selectedRange())
                }
            }
        }
    }

    /// The note was reloaded while text is being typed: the open editor takes the text as the reload
    /// left it (another device may have reworded or moved it), right away, so closing or saving can't
    /// put back the old wording. Nil means it was deleted elsewhere: the editor closes, adding nothing.
    func textDraftReloaded(_ draft: InkText?) {
        guard let editor = textEditor, editingText != nil else { return }
        guard let draft else {
            endTextEditing(commit: false)
            return
        }
        editingText = draft
        if editor.string != draft.text {
            editor.string = draft.text
            if let storage = editor.textStorage {
                storage.setAttributes(editor.typingAttributes, range: NSRange(location: 0, length: storage.length))
            }
            // Its typing steps were for the old wording.
            editorUndo.removeAllActions()
        }
        layoutTextEditor()
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = textEditor, var text = editingText else { return }
        text.text = editor.string
        editingText = text
        model.updateTextDraft(text)
        layoutTextEditor()
    }

    func textDidEndEditing(_ notification: Notification) {
        // Focus moved elsewhere (another view or window): the text is done.
        endTextEditing()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            endTextEditing()
            return true
        }
        return false
    }

    func undoManager(for view: NSTextView) -> UndoManager? { editorUndo }

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
    /// Whether Add Text is offered (handwritten notes; not PDFs).
    var allowsText = true

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
            ForEach(InkSurfaceTool.allCases.filter { allowsText || $0 != .text }) { tool in
                Button { model.surfaceTool = tool } label: {
                    Label(tool.label, systemImage: tool.symbol)
                        .symbolVariant(model.surfaceTool == tool ? .fill : .none)
                }
                .tint(model.surfaceTool == tool ? .accentColor : nil)
                .help(tool.detail)
                .accessibilityIdentifier(tool == .text ? "ink-add-text" : "ink-tool-\(tool.rawValue)")
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
