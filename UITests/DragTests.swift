import XCTest

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
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        sidebar.tap()
        #endif
    }

    private func row(_ path: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "vault-row-" + path).firstMatch
    }

    private func drag(_ source: XCUIElement, to target: XCUIElement) {
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        #if os(macOS)
        source.click(forDuration: 0.5, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 1)
        #else
        source.press(forDuration: 0.5, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 1)
        #endif
    }

    private func expandFolder() {
        #if os(macOS)
        row("Folder").coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
        #else
        app.buttons["Expand folder"].firstMatch.tap()
        #endif
    }

    func testMoveIntoFolder() {
        drag(row("Root.md"), to: row("Folder"))
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row("Root.md"))
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 10), .completed)
        expandFolder()
        XCTAssertTrue(row("Folder/Root.md").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(row("Root.md").exists, "Moving must remove the source")
        app.terminate()
        launch()
        expandFolder()
        XCTAssertTrue(row("Folder/Root.md").exists, "The move must survive relaunch")
        XCTAssertFalse(row("Root.md").exists)
    }

    func testMoveToTopLevel() {
        expandFolder()
        drag(row("Folder/Nested.md"), to: app.staticTexts["vault-root-drop"])
        XCTAssertTrue(row("Nested.md").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(row("Folder/Nested.md").exists)
        app.terminate()
        launch()
        XCTAssertTrue(row("Nested.md").waitForExistence(timeout: 10))
        expandFolder()
        XCTAssertFalse(row("Folder/Nested.md").exists)
    }
}
