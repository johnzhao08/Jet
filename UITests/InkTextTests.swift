import XCTest

/// Add Text on handwritten notes, end to end on an isolated Debug vault (JET_UI_TEST_VAULT):
/// choose Add Text, put text on the page, leave and reopen the note to find it saved, then edit it,
/// and delete it. On the Mac the click lands on the writing surface ("ink-surface", whose value
/// counts strokes and text boxes) and the editor is "ink-text-editor"; on iPad a tap does the same
/// after the toolbar's Add Text, with Done and Delete on the keyboard's accessory bar.
final class InkTextTests: XCTestCase {
    private var app: XCUIApplication!
    private let typed = "Typed on the page"
    private let reworded = "Reworded for the exam"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["JET_UI_TEST_VAULT"] = UUID().uuidString
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        app.launch()
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

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func row(_ path: String) -> XCUIElement { element("vault-row-" + path) }

    private var editor: XCUIElement { element("ink-text-editor") }

    private var addText: XCUIElement { element("ink-add-text") }

    private func value(of element: XCUIElement) -> String { (element.value as? String) ?? "" }

    private func waitGone(_ element: XCUIElement, _ message: String = "") {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, message + app.debugDescription)
    }

    private func waitForValue(_ element: XCUIElement, _ format: String, _ argument: String, _ message: String) {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argument), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 10), .completed,
                       "\(message) (value: \(value(of: element)))\n" + app.debugDescription)
    }

    /// Replaces everything in the open editor.
    private func retype(_ string: String) {
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(string)
    }

    // MARK: Mac

    #if os(macOS)
    private var surface: XCUIElement { element("ink-surface") }

    /// Where text goes on the page: right of the sidebar, clear of the pen stroke other tests draw.
    private var spot: XCUICoordinate {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.25))
    }

    /// A point inside that text's first line (its frame runs from the click to the page margin).
    private var insideText: XCUICoordinate { spot.withOffset(CGVector(dx: 14, dy: 0)) }

    private func openNewHandwrittenNote() {
        XCTAssertTrue(row("Root.md").waitForExistence(timeout: 15), app.debugDescription)
        app.typeKey("k", modifierFlags: .command)
        let command = app.textFields["command-search"]
        XCTAssertTrue(command.waitForExistence(timeout: 5), app.debugDescription)
        command.typeText("handwritten")
        command.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(row("Untitled.ink").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(surface.waitForExistence(timeout: 5), app.debugDescription)
    }

    /// Leaves the note and comes back, as the sidebar does.
    private func reopen() {
        row("Root.md").click()
        XCTAssertTrue(row("Untitled.ink").waitForExistence(timeout: 5))
        row("Untitled.ink").click()
        XCTAssertTrue(surface.waitForExistence(timeout: 5), app.debugDescription)
    }

    private func commit() {
        app.typeKey(.escape, modifierFlags: [])
        waitGone(editor, "The editor closes on Escape. ")
    }

    private func place(_ string: String) {
        XCTAssertTrue(addText.waitForExistence(timeout: 5), "The toolbar has Add Text\n" + app.debugDescription)
        addText.click()
        spot.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Clicking the page opens a text editor\n" + app.debugDescription)
        editor.typeText(string)
        commit()
    }

    private func rightClickText(_ item: String, at point: XCUICoordinate? = nil) {
        (point ?? insideText).rightClick()
        let entry = app.menuItems[item].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "No “\(item)” on a text's menu\n" + app.debugDescription)
        entry.click()
    }

    func testTypedTextIsSavedEditedAndDeleted() {
        openNewHandwrittenNote()
        XCTAssertEqual(value(of: surface), "0 strokes", "A new page has nothing on it")

        place(typed)
        waitForValue(surface, "value CONTAINS %@", "1 text box", "The page counts the text it was given")

        reopen()
        XCTAssertTrue(value(of: surface).contains("1 text box"), "The text is still there after reopening: " + value(of: surface))
        rightClickText("Edit Text")
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(value(of: editor), typed, "Reopened text is what was typed")

        retype(reworded)
        commit()
        reopen()
        rightClickText("Edit Text")
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(value(of: editor), reworded, "The edit is saved")
        commit()
        XCTAssertTrue(value(of: surface).contains("1 text box"), "Editing doesn't add another text: " + value(of: surface))

        rightClickText("Delete Text")
        waitForValue(surface, "NOT (value CONTAINS %@)", "text box", "Deleting removes the text")
        reopen()
        XCTAssertFalse(value(of: surface).contains("text box"), "The deleted text stays deleted: " + value(of: surface))
    }

    func testEmptyingTextRemovesIt() {
        openNewHandwrittenNote()
        place(typed)
        waitForValue(surface, "value CONTAINS %@", "1 text box", "The text was added")
        insideText.rightClick()
        app.menuItems["Edit Text"].firstMatch.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        editor.typeKey("a", modifierFlags: .command)
        editor.typeKey(.delete, modifierFlags: [])
        commit()
        waitForValue(surface, "NOT (value CONTAINS %@)", "text box", "Clearing a text deletes it")
        reopen()
        XCTAssertFalse(value(of: surface).contains("text box"), "Cleared text isn't kept: " + value(of: surface))
    }

    func testTextAndInkLiveTogetherOnAPage() {
        openNewHandwrittenNote()
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.64, dy: 0.6))
            .click(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.76, dy: 0.65)))
        waitForValue(surface, "value CONTAINS %@", "1 stroke", "The mouse stroke is written")
        place(typed)
        waitForValue(surface, "value CONTAINS %@", "1 text box", "The text is added beside the ink")
        reopen()
        let summary = value(of: surface)
        XCTAssertTrue(summary.contains("1 stroke") && summary.contains("1 text box"), "Ink and text both come back: " + summary)
    }

    func testBlankTextIsNotKept() {
        openNewHandwrittenNote()
        place("   ")
        XCTAssertFalse(value(of: surface).contains("text box"), "Blank text isn't added: " + value(of: surface))
        reopen()
        XCTAssertEqual(value(of: surface), "0 strokes")
    }

    /// Whether right-clicking at `point` offers the text's menu (it does only on typed words).
    private func textMenuOffered(at point: XCUICoordinate) -> Bool {
        point.rightClick()
        let offered = app.menuItems["Edit Text"].firstMatch.waitForExistence(timeout: 2)
        if offered || app.menus.firstMatch.exists { app.typeKey(.escape, modifierFlags: []) }
        return offered
    }

    /// The empty end of the line the text is on: inside the box it wraps in, past its words.
    private var emptyPartOfLine: XCUICoordinate { spot.withOffset(CGVector(dx: 260, dy: 0)) }

    func testEmptyPartOfTheTextsLineIsNotTheText() {
        openNewHandwrittenNote()
        place("Hi there")
        waitForValue(surface, "value CONTAINS %@", "1 text box", "The text was added")
        XCTAssertFalse(textMenuOffered(at: emptyPartOfLine), "Clicking past the end of a short line isn't clicking its text")
        XCTAssertTrue(textMenuOffered(at: insideText), "Clicking the words still is")
        XCTAssertTrue(value(of: surface).contains("1 text box"), "Nothing changed: " + value(of: surface))
    }

    func testTextCanBeDraggedRight() {
        openNewHandwrittenNote()
        place(typed)
        waitForValue(surface, "value CONTAINS %@", "1 text box", "The text was added")
        let shift: CGFloat = 220
        insideText.click(forDuration: 0.2, thenDragTo: insideText.withOffset(CGVector(dx: shift, dy: 0)))
        XCTAssertFalse(textMenuOffered(at: insideText), "The words are no longer where they were")
        XCTAssertTrue(textMenuOffered(at: insideText.withOffset(CGVector(dx: shift, dy: 0))), "The text followed the drag to the right")
        XCTAssertTrue(value(of: surface).contains("1 text box"), "Moving doesn't add or remove text: " + value(of: surface))

        reopen()
        XCTAssertTrue(textMenuOffered(at: insideText.withOffset(CGVector(dx: shift, dy: 0))), "The new place is saved")
        rightClickText("Edit Text", at: insideText.withOffset(CGVector(dx: shift, dy: 0)))
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(value(of: editor), typed, "Moving keeps the words")
        commit()
    }

    // MARK: iPad
    #else
    private func showSidebar() {
        let button = app.buttons["Show Sidebar"]
        if button.waitForExistence(timeout: 3) { button.tap() }
    }

    /// Where text goes on the page: a point in the window, taken while the page is laid out as it is
    /// right after the note opens.
    private var spot: XCUICoordinate {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.25))
    }

    private var canvas: XCUIElement { app.scrollViews["ink-page-canvas"].firstMatch }
    private var textPoint: CGPoint?

    private var insideText: XCUICoordinate {
        guard let point = textPoint else {
            XCTFail("Text was never placed")
            return spot
        }
        let width = canvas.frame.width
        return canvas.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x * width, dy: point.y * width))
    }

    private func openNewHandwrittenNote() {
        let create = app.buttons["New handwritten note"]
        XCTAssertTrue(create.waitForExistence(timeout: 15), app.debugDescription)
        create.tap()
        let confirm = app.alerts.buttons["Create"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()
        XCTAssertTrue(addText.waitForExistence(timeout: 10), "A handwritten note has Add Text in its toolbar\n" + app.debugDescription)
    }

    /// Leaves the note and comes back through the sidebar.
    private func reopen() {
        showSidebar()
        XCTAssertTrue(row("Root.md").waitForExistence(timeout: 5), app.debugDescription)
        row("Root.md").tap()
        showSidebar()
        XCTAssertTrue(row("Untitled.ink").waitForExistence(timeout: 5), app.debugDescription)
        row("Untitled.ink").tap()
        XCTAssertTrue(addText.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
    }

    private func done() {
        let button = app.buttons["Done"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "The keyboard bar has Done\n" + app.debugDescription)
        button.tap()
        waitGone(editor, "Done closes the editor. ")
    }

    private func place(_ string: String) {
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let page = canvas.frame
        addText.tap()
        spot.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Tapping the page opens a text editor\n" + app.debugDescription)
        let frame = editor.frame
        // Both page axes scale with the width of the note column.
        textPoint = CGPoint(x: (frame.minX + 12 - page.minX) / page.width,
                            y: (frame.minY + 8 - page.minY) / page.width)
        // The editor is as wide as the text's box, so its right end is empty once the words are short.
        emptyPoint = CGPoint(x: (frame.maxX - 40 - page.minX) / page.width,
                             y: (frame.minY + 8 - page.minY) / page.width)
        editor.typeText(string)
        done()
    }

    /// Taps where the text was typed and returns what the editor shows (nil when nothing opened).
    private func openText() -> String? {
        insideText.tap()
        return editor.waitForExistence(timeout: 5) ? value(of: editor) : nil
    }

    /// Taps `point` with the regular tool and reports whether an editor opened.
    private func tapOpensEditor(at point: XCUICoordinate) -> Bool {
        point.tap()
        return editor.waitForExistence(timeout: 3)
    }

    /// A point on the text's line, near the right end of the box it wraps in: past its words.
    private var emptyPartOfLine: XCUICoordinate {
        guard let point = emptyPoint else {
            XCTFail("Text was never placed")
            return spot
        }
        let width = canvas.frame.width
        return canvas.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x * width, dy: point.y * width))
    }
    private var emptyPoint: CGPoint?

    func testTypedTextIsSavedEditedAndDeleted() {
        openNewHandwrittenNote()
        place(typed)

        reopen()
        XCTAssertEqual(openText(), typed, "Tapping the saved text after reopening edits what was typed")
        retype(reworded)
        done()

        reopen()
        XCTAssertEqual(openText(), reworded, "The edit is saved")
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "The keyboard bar has Delete\n" + app.debugDescription)
        delete.tap()
        waitGone(editor, "Delete closes the editor. ")

        reopen()
        // With the regular tool a tap opens an editor only on typed text, so after deleting there is none.
        XCTAssertFalse(tapOpensEditor(at: insideText), "Tapping where the deleted text was opens nothing\n" + app.debugDescription)
        XCTAssertTrue(canvas.exists && addText.exists, "The note is still open and usable after that tap")
    }

    func testBlankTextIsNotKept() {
        openNewHandwrittenNote()
        place("   ")
        reopen()
        XCTAssertFalse(tapOpensEditor(at: insideText), "Tapping where blank text was typed opens nothing\n" + app.debugDescription)
        XCTAssertTrue(canvas.exists && addText.exists, "The note is still open and usable after that tap")
    }

    func testEmptyPartOfTheTextsLineIsNotTheText() {
        openNewHandwrittenNote()
        place("Hi there")
        reopen()
        XCTAssertFalse(tapOpensEditor(at: emptyPartOfLine), "Tapping past the end of a short line doesn't edit its text\n" + app.debugDescription)
        XCTAssertEqual(openText(), "Hi there", "Tapping the words still does")
        done()
    }

    func testTextCanBeDraggedRight() {
        openNewHandwrittenNote()
        place(typed)
        reopen()
        let shift: CGFloat = 150
        insideText.press(forDuration: 0.8, thenDragTo: insideText.withOffset(CGVector(dx: shift, dy: 0)))
        XCTAssertFalse(tapOpensEditor(at: insideText), "The words are no longer where they were\n" + app.debugDescription)
        let moved = insideText.withOffset(CGVector(dx: shift, dy: 0))
        XCTAssertTrue(tapOpensEditor(at: moved), "The text followed the drag to the right\n" + app.debugDescription)
        XCTAssertEqual(value(of: editor), typed, "Moving keeps the words")
        done()

        reopen()
        XCTAssertTrue(tapOpensEditor(at: moved), "The new place is saved\n" + app.debugDescription)
        XCTAssertEqual(value(of: editor), typed)
        done()
    }
    #endif
}
