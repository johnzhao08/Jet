import XCTest
@testable import JetKit

@MainActor
final class InkZoomTests: XCTestCase {
    private func model() -> InkNoteModel {
        InkNoteModel(url: FileManager.default.temporaryDirectory.appendingPathComponent("zoom-\(UUID().uuidString).ink"))
    }

    func testClosingTheSidebarKeepsTheZoom() {
        let ink = model()
        ink.viewFits(0.7)                     // opened with the sidebar showing
        XCTAssertEqual(ink.currentZoom, 0.7, accuracy: 0.0001)
        ink.viewFits(1.0)                     // sidebar closed: wider view, same zoom, more page
        XCTAssertEqual(ink.currentZoom, 0.7, accuracy: 0.0001)
        ink.viewFits(0.5)                     // narrower than ever: zooms out so the page still fits
        XCTAssertEqual(ink.currentZoom, 0.5, accuracy: 0.0001)
        ink.viewFits(0.7)
        XCTAssertEqual(ink.currentZoom, 0.7, accuracy: 0.0001)
    }

    func testZoomingInPastTheWidthStaysWhenTheViewNarrows() {
        let ink = model()
        ink.viewFits(1.0)
        ink.setZoom(2)
        ink.viewFits(0.7)
        XCTAssertEqual(ink.currentZoom, 2, accuracy: 0.0001)
    }

    func testStepsAndLimits() {
        let ink = model()
        ink.viewFits(1.0)
        ink.zoomIn()
        XCTAssertEqual(ink.currentZoom, 1.1, accuracy: 0.0001)
        ink.zoomOut(); ink.zoomOut()
        XCTAssertEqual(ink.currentZoom, 0.9, accuracy: 0.0001)
        ink.setZoom(0.01)
        XCTAssertEqual(ink.currentZoom, InkNoteModel.zoomLimits.lowerBound, accuracy: 0.0001)
        XCTAssertFalse(ink.canZoomOut)
        ink.zoomToFit()
        XCTAssertEqual(ink.currentZoom, 1.0, accuracy: 0.0001)
    }
}
