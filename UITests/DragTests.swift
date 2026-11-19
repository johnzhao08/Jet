import XCTest

/// Sidebar behaviour against an isolated Debug-only vault (JET_UI_TEST_VAULT):
/// Another.md, Folder/Nested.md, Root.md. On the Mac rows drag like Finder's list view; on iPad
/// rows don't drag, and the row menu's Move to / Move Up / Move Down do the job.
final class DragTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["JET_UI_TEST_VAULT"] = UUID().uuidString
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        launch()
        XCTAssertTrue(row("Root.md").waitForExistence(timeout: 15), app.debugDescription)
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

    private func launch() {
        app.launch()
        #if os(iOS)
        let sidebar = app.buttons["Show Sidebar"]
        if sidebar.waitForExistence(timeout: 10) { sidebar.tap() }
        #endif
    }

    private func row(_ path: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "vault-row-" + path).firstMatch
    }

    private func tapRow(_ path: String) {
        XCTAssertTrue(row(path).waitForExistence(timeout: 5))
        #if os(macOS)
        row(path).click()
        #else
        row(path).tap()
        #endif
    }

    private func waitGone(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, app.debugDescription)
    }

    private func isAbove(_ a: String, _ b: String) -> Bool {
        row(a).frame.minY < row(b).frame.minY
    }

    func testClickingAFolderOpensItAndShowsWhereYouAre() {
        XCTAssertFalse(row("Folder/Nested.md").exists)
        tapRow("Folder")
        XCTAssertTrue(row("Folder/Nested.md").waitForExistence(timeout: 5), "A click opens the folder")
        XCTAssertGreaterThanOrEqual(row("Folder/Nested.md").frame.minX - row("Root.md").frame.minX, 0)
        let location = app.descendants(matching: .any).matching(identifier: "current-folder").firstMatch
        XCTAssertTrue(location.buttons["Folder"].waitForExistence(timeout: 5), "The location bar names the current folder")
        tapRow("Folder")
        waitGone(row("Folder/Nested.md"))
    }

    #if os(macOS)
    func testCommandPaletteOpensWeeklyNote() {
        app.typeKey("k", modifierFlags: .command)
        let command = app.textFields["command-search"]
        XCTAssertTrue(command.waitForExistence(timeout: 5), app.debugDescription)
        command.typeText("week")
        command.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(row("Weekly").waitForExistence(timeout: 5), app.debugDescription)
    }

    func testGraphFiltersVisibleNotes() {
        app.typeKey("k", modifierFlags: .command)
        let command = app.textFields["command-search"]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.typeText("graph")
        command.typeKey(.return, modifierFlags: [])
        let filters = app.buttons["Filters and groups"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        filters.click()
        let query = app.textFields["graph-filter"]
        query.click()
        query.typeText("path:missing")
        XCTAssertTrue(app.staticTexts["No matching notes"].waitForExistence(timeout: 5))
    }

    private func drag(_ path: String, toRow target: String, at fraction: CGFloat) {
        let source = row(path), destination = row(target)
        XCTAssertTrue(source.waitForExistence(timeout: 5) && destination.waitForExistence(timeout: 5))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.6,
                   thenDragTo: destination.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fraction)),
                   withVelocity: .slow, thenHoldForDuration: 0.8)
    }

    func testDragIntoAFolder() {
        drag("Root.md", toRow: "Folder", at: 0.5)
        waitGone(row("Root.md"))
        tapRow("Folder")
        XCTAssertTrue(row("Folder/Root.md").waitForExistence(timeout: 5))
        app.terminate()
        launch()
        // The folder stays open (and selected) across launches; open it only if it isn't.
        if !row("Folder/Root.md").waitForExistence(timeout: 5) { tapRow("Folder") }
        XCTAssertTrue(row("Folder/Root.md").waitForExistence(timeout: 10), "The move survives a relaunch")
        XCTAssertFalse(row("Root.md").exists)
    }

    func testDragBetweenRowsReorders() {
        XCTAssertTrue(isAbove("Another.md", "Root.md"))
        drag("Root.md", toRow: "Another.md", at: 0.1)
        let reordered = expectation(for: NSPredicate { _, _ in self.isAbove("Root.md", "Another.md") }, evaluatedWith: nil)
        wait(for: [reordered], timeout: 10)
        app.terminate()
        launch()
        XCTAssertTrue(row("Root.md").waitForExistence(timeout: 10))
        XCTAssertTrue(isAbove("Root.md", "Another.md"), "Manual order survives a relaunch")
    }

    func testDragOutOfAFolderToTheTopLevel() {
        tapRow("Folder")
        XCTAssertTrue(row("Folder/Nested.md").waitForExistence(timeout: 5))
        let end = app.descendants(matching: .any).matching(identifier: "vault-end-drop").firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        row("Folder/Nested.md").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.6, thenDragTo: end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)),
                   withVelocity: .slow, thenHoldForDuration: 0.8)
        XCTAssertTrue(row("Nested.md").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(row("Folder/Nested.md").exists)
    }
    #else
    func testQuickCaptureLinkFilesANote() {
        app.open(URL(string: "jet://capture")!)
        let title = app.textFields["Title (optional)"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        title.tap()
        title.typeText("Capture check")
        let body = app.textViews.firstMatch
        body.tap()
        body.typeText("From the quick capture sheet")
        app.buttons["Save"].tap()
        waitGone(title)
        if !row("Inbox").exists, app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
        if !row("Inbox/Capture check.md").exists { tapRow("Inbox") }
        XCTAssertTrue(row("Inbox/Capture check.md").waitForExistence(timeout: 5), app.debugDescription)
    }

    private func menuAction(_ path: String, _ items: [String]) {
        XCTAssertTrue(row(path).waitForExistence(timeout: 5))
        row(path).press(forDuration: 1.2)
        for item in items {
            let button = app.buttons[item].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), "No “\(item)” in the menu\n" + app.debugDescription)
            button.tap()
        }
    }

    func testMoveToFromTheRowMenu() {
        menuAction("Root.md", ["Move to", "Folder"])
        waitGone(row("Root.md"))
        tapRow("Folder")
        XCTAssertTrue(row("Folder/Root.md").waitForExistence(timeout: 5))
    }

    func testMoveUpFromTheRowMenu() {
        XCTAssertTrue(isAbove("Another.md", "Root.md"))
        menuAction("Root.md", ["Move Up"])
        let reordered = expectation(for: NSPredicate { _, _ in self.isAbove("Root.md", "Another.md") }, evaluatedWith: nil)
        wait(for: [reordered], timeout: 10)
    }

    func testRowsDoNotDragOnIPad() {
        row("Root.md").press(forDuration: 0.5, thenDragTo: row("Folder"), withVelocity: .slow, thenHoldForDuration: 1)
        // Dismiss whatever the long press opened, then check nothing moved.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        XCTAssertTrue(row("Root.md").waitForExistence(timeout: 5), "Dragging a row on iPad doesn't move it")
    }
    #endif
}
