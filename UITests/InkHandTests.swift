import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The Hand tool, end to end on an isolated Debug vault (JET_UI_TEST_VAULT): with it, dragging pans the
/// page (handwritten note, PDF or picture) instead of putting ink on it. On the Mac a plain right-click
/// on typed text still opens its menu. On iPad a finger drag with the Hand tool scrolls without drawing.
///
/// The Mac's secondary-button drag (it pans whatever tool is chosen) is not driven from here: synthesized
/// global right-button events don't reliably reach the app, so `./selftest.sh` ("12g") sends real
/// NSEvents to a real NSWindow / NSScrollView / InkSurfaceView and checks both axes, the scroll limits,
/// that nothing is drawn and that the chosen tool is kept.
///
/// Identifiers these tests rely on (the implementation must provide them):
///  - "ink-tool-hand" / "ink-tool-pen": the toolbar buttons, on both platforms.
///  - Mac: the existing "ink-surface" (its frame moves as the page scrolls, its value counts strokes).
///  - iPad: "ink-page-canvas" gets an accessibility value of the form "N strokes, scroll y Y"
///    (Y: the canvas's content offset in points), so strokes and scrolling can be read without pixels.
///
/// Not covered: an iPad *pointer* (mouse or trackpad) drag. XCUITest on iOS cannot synthesize pointer
/// drags (only `hover()`), so that path has no UI harness here.
final class InkHandTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["JET_UI_TEST_VAULT"] = UUID().uuidString
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #else
        // Windows from earlier launches must not come back: every window shows the one open note, so
        // each would answer every query.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        #endif
        app.launch()
        #if os(macOS)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        pinnedWindow = app.windows.firstMatch
        #endif
    }

    override func tearDownWithError() throws {
        if let testRun, !testRun.hasSucceeded {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app.terminate()
    }

    // MARK: Helpers shared by both platforms

    private var pinnedWindow: XCUIElement?

    private var scope: XCUIElement {
        #if os(macOS)
        if let pinnedWindow { return pinnedWindow }
        #endif
        return app
    }

    private func element(_ identifier: String) -> XCUIElement {
        scope.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func row(_ path: String) -> XCUIElement { element("vault-row-" + path) }

    private var handTool: XCUIElement { element("ink-tool-hand") }

    private func value(of element: XCUIElement) -> String { (element.value as? String) ?? "" }

    private func activate(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func selectHand() {
        XCTAssertTrue(handTool.waitForExistence(timeout: 10), "The toolbar has a Hand tool\n" + app.debugDescription)
        activate(handTool)
    }

    /// Zooms the open page to 300%, so even an empty handwritten note has far more page than window.
    private func zoomToThreeHundredPercent() {
        let zoom = element("ink-zoom")
        XCTAssertTrue(zoom.waitForExistence(timeout: 10), app.debugDescription)
        #if os(macOS)
        // The menu is the app's, not the window's.
        let preset = app.menuItems["300%"].firstMatch
        #else
        let preset = app.buttons["300%"].firstMatch
        #endif
        // A menu that is still opening can swallow the click, so ask again if it did not show.
        for _ in 0..<3 where !(preset.exists && preset.isHittable) {
            activate(zoom)
            _ = preset.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(preset.exists && preset.isHittable, "The zoom menu offers 300%\n" + app.debugDescription)
        activate(preset)
    }

    // MARK: Mac

    #if os(macOS)
    private var surface: XCUIElement { element("ink-surface") }
    private var penTool: XCUIElement { element("ink-tool-pen") }
    private var addText: XCUIElement { element("ink-add-text") }

    private func openNewHandwrittenNote() {
        XCTAssertTrue(row("Root.md").waitForExistence(timeout: 15), app.debugDescription)
        app.typeKey("k", modifierFlags: .command)
        let command = scope.textFields["command-search"]
        XCTAssertTrue(command.waitForExistence(timeout: 5), app.debugDescription)
        command.typeText("handwritten")
        command.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(row("Untitled.ink").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(surface.waitForExistence(timeout: 5), app.debugDescription)
        zoomToThreeHundredPercent()
    }

    private func openFromOutside(_ file: URL, as name: String) {
        XCTAssertTrue(row("Root.md").waitForExistence(timeout: 15), app.debugDescription)
        app.open(file)
        let window = app.windows.matching(NSPredicate(format: "title == %@", name)).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), app.debugDescription)
        pinnedWindow = window
        XCTAssertTrue(row(name).waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(surface.waitForExistence(timeout: 10), app.debugDescription)
    }

    /// A three-page PDF, imported with "Open With", so there is page below the window.
    private func openPDF() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Pages.pdf")
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = try XCTUnwrap(CGContext(file as CFURL, mediaBox: &page, nil))
        for _ in 0..<3 {
            pdf.beginPDFPage(nil)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        openFromOutside(file, as: "Pages.pdf")
    }

    /// A tall PNG (it becomes one page four times as tall as it is wide).
    private func openImage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Tall.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 2400, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.9, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 2400))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        openFromOutside(file, as: "Tall.png")
    }

    /// A point on the part of the page that shows in the window (the page's own frame, cut to the window,
    /// so it is on the page however the page is zoomed or scrolled), `dx` and `dy` of the way across it.
    private func pagePoint(dx: CGFloat = 0.5, dy: CGFloat = 0.5) -> XCUICoordinate {
        let window = scope.frame
        let visible = surface.frame.intersection(window)
        XCTAssertFalse(visible.isNull || visible.isEmpty, "The page shows in the window: \(surface.frame) in \(window)")
        let origin = scope.coordinate(withNormalizedOffset: .zero)
        return origin.withOffset(CGVector(dx: visible.minX - window.minX + visible.width * dx,
                                          dy: visible.minY - window.minY + visible.height * dy))
    }

    private var pageOffsetY: CGFloat { surface.frame.minY }

    /// Waits for the page to stop moving or resizing (a zoom or a note opening animates).
    private func waitForSettledPage() {
        var last = surface.frame
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 0.3)
            let now = surface.frame
            if now == last { return }
            last = now
        }
    }

    /// The page is held by the pointer, so dragging up moves it up (the window shows what was below).
    private func assertPanned(from before: CGFloat, by atLeast: CGFloat = 40, _ message: String) {
        let moved = expectation(for: NSPredicate { _, _ in before - self.pageOffsetY >= atLeast }, evaluatedWith: nil)
        wait(for: [moved], timeout: 8)
        XCTAssertGreaterThanOrEqual(before - pageOffsetY, atLeast, message)
        XCTAssertEqual(value(of: surface), "0 strokes", "Panning writes nothing. " + message)
    }

    private func handDrag(on kind: String) {
        selectHand()
        waitForSettledPage()
        let before = pageOffsetY
        pagePoint(dy: 0.7).click(forDuration: 0.2, thenDragTo: pagePoint(dy: 0.4))
        assertPanned(from: before, "A Hand drag scrolls the \(kind) page")
    }

    func testHandToolPansHandwrittenNoteWithoutDrawing() {
        openNewHandwrittenNote()
        handDrag(on: "handwritten")
        // The Hand tool is just a tool: back on the pen, a drag writes again.
        app.activate()
        XCTAssertTrue(penTool.waitForExistence(timeout: 5), app.debugDescription)
        penTool.click()
        pagePoint(dx: 0.3, dy: 0.5).click(forDuration: 0.2, thenDragTo: pagePoint(dx: 0.6, dy: 0.55))
        let written = expectation(for: NSPredicate(format: "value == %@", "1 stroke"), evaluatedWith: surface)
        wait(for: [written], timeout: 8)
    }

    func testHandToolPansPDFWithoutDrawing() throws {
        try openPDF()
        handDrag(on: "PDF")
    }

    func testHandToolPansImageWithoutDrawing() throws {
        try openImage()
        handDrag(on: "image")
    }

    /// The right button's other job stays: a click on typed text (no drag) opens its Edit / Delete menu.
    /// (Panning with that button is checked on real AppKit events in `./selftest.sh`, "12g".)
    func testPlainRightClickStillOpensTheTextMenu() {
        openNewHandwrittenNote()
        waitForSettledPage()
        let spot = pagePoint(dx: 0.3, dy: 0.25)
        XCTAssertTrue(addText.waitForExistence(timeout: 5), app.debugDescription)
        addText.click()
        spot.click()
        let editor = element("ink-text-editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        editor.typeText("Typed on the page")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(value(of: surface), "0 strokes, 1 text box", app.debugDescription)
        XCTAssertTrue(penTool.exists, app.debugDescription)
        penTool.click()

        spot.withOffset(CGVector(dx: 14, dy: 0)).rightClick()
        let edit = app.menuItems["Edit Text"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "A right-click on text opens its menu\n" + app.debugDescription)
        XCTAssertTrue(app.menuItems["Delete Text"].firstMatch.exists, app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(value(of: surface), "0 strokes, 1 text box", "The menu changed nothing")
    }
    #else

    // MARK: iPad

    private var canvas: XCUIElement { app.scrollViews["ink-page-canvas"].firstMatch }

    private func openNewHandwrittenNote() {
        let create = app.buttons["New handwritten note"]
        XCTAssertTrue(create.waitForExistence(timeout: 15), app.debugDescription)
        create.tap()
        let confirm = app.alerts.buttons["Create"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), app.debugDescription)
        zoomToThreeHundredPercent()
    }

    /// The canvas's accessibility value, which says "N strokes, scroll y Y".
    private var canvasValue: String { value(of: canvas) }

    private var scrollY: CGFloat? {
        guard let range = canvasValue.range(of: #"scroll y (-?\d+)"#, options: .regularExpression),
              let number = Int(canvasValue[range].dropFirst("scroll y ".count)) else { return nil }
        return CGFloat(number)
    }

    func testHandToolFingerDragScrollsWithoutDrawing() throws {
        openNewHandwrittenNote()
        let start = try XCTUnwrap(scrollY, "The canvas reports its scroll position (value: “\(canvasValue)”)")
        XCTAssertTrue(canvasValue.hasPrefix("0 strokes"), canvasValue)

        selectHand()
        let from = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let to = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)

        let scrolled = expectation(for: NSPredicate { _, _ in (self.scrollY ?? start) - start >= 40 }, evaluatedWith: nil)
        wait(for: [scrolled], timeout: 8)
        XCTAssertGreaterThanOrEqual((scrollY ?? start) - start, 40, "A finger drag with the Hand tool scrolls the page: " + canvasValue)
        XCTAssertTrue(canvasValue.hasPrefix("0 strokes"), "…and draws nothing: " + canvasValue)
    }
    #endif
}
