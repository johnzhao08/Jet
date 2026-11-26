import XCTest
#if os(macOS)
import AppKit
import CoreGraphics
#endif

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
    func testOpeningMarkdownFromFinderReusesTheVaultWindow() throws {
        tapRow("Root.md")
        XCTAssertEqual(app.windows.count, 1, app.debugDescription)
        let window = app.windows.firstMatch
        let originalFrame = window.frame
        let edit = window.buttons["Edit"]
        if edit.exists { edit.click() }
        let root = window.textViews.matching(NSPredicate(format: "value CONTAINS %@", "# Root")).firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 5), app.debugDescription)

        let note = FileManager.default.temporaryDirectory.appendingPathComponent("Finder-\(UUID()).md")
        try "# Opened from Finder".write(to: note, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: note) }
        // Launch Services can route to an installed copy with the same bundle ID.
        let target = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Jet.app")
        let bundleID = try XCTUnwrap(Bundle(url: target)?.bundleIdentifier)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        try XCTSkipUnless(running.count == 1 && running.first?.bundleURL?.standardizedFileURL.path == target.standardizedFileURL.path,
                          "The test build must be the only running Jet with this bundle ID")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false
        let delivered = expectation(description: "Launch Services opened the Markdown file")
        NSWorkspace.shared.open([note], withApplicationAt: target, configuration: configuration) { _, error in
            XCTAssertNil(error)
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 10)

        let opened = window.textViews.matching(NSPredicate(format: "value CONTAINS %@", "# Opened from Finder")).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.windows.count, 1, app.debugDescription)
        XCTAssertEqual(window.frame, originalFrame)
    }

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

    func testMouseStrokePersistsInHandwrittenNote() throws {
        app.typeKey("k", modifierFlags: .command)
        let command = app.textFields["command-search"]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.typeText("handwritten")
        command.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(row("Untitled.ink").waitForExistence(timeout: 5))
        assertStrokePersists(in: "Untitled.ink")
    }

    func testMouseAnnotationPersistsOnPDF() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Page.pdf")
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = try XCTUnwrap(CGContext(file as CFURL, mediaBox: &page, nil))
        pdf.beginPDFPage(nil)
        pdf.endPDFPage()
        pdf.closePDF()
        app.open(file)
        XCTAssertTrue(row("Page.pdf").waitForExistence(timeout: 8), app.debugDescription)
        assertStrokePersists(in: "Page.pdf")
    }

    private func assertStrokePersists(in path: String) {
        let surface = app.descendants(matching: .any).matching(identifier: "ink-surface").firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        XCTAssertEqual(surface.value as? String, "0 strokes")
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.64, dy: 0.5))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.76, dy: 0.55))
        start.click(forDuration: 0.2, thenDragTo: end)
        let written = expectation(for: NSPredicate(format: "value == %@", "1 stroke"), evaluatedWith: surface)
        wait(for: [written], timeout: 8)
        tapRow("Root.md")
        tapRow(path)
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        XCTAssertEqual(surface.value as? String, "1 stroke")
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
