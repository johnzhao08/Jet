import PencilKit
import XCTest
@testable import JetKit
#if os(macOS)
import AppKit
#endif

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

    func testPDFRasterRoundsUpInsteadOfSquashingThePage() throws {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 100, height: 73)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        let pages = try XCTUnwrap(PDFPages(document: document))
        let raster = try XCTUnwrap(pages.render(0, drawing: PKDrawing(), images: [],
                                               root: FileManager.default.temporaryDirectory, scale: 102 / InkDocument.pageWidth))
        XCTAssertEqual(raster.width, 102)
        XCTAssertEqual(raster.height, 75, "The scaled page is 74.46 pixels tall and needs a partial row")
    }

    #if os(macOS)
    func testMacTextEditorKeepsItsLayoutWhenZooming() throws {
        let surface = InkSurfaceView(model: model())
        let text = InkText(text: "Zoom keeps the editor's line breaks.", origin: CGPoint(x: 40, y: 32), width: 160)
        surface.beginTextEditing(text, at: text.origin)
        defer { surface.endTextEditing(commit: false) }
        let editor = try XCTUnwrap(surface.subviews.compactMap { $0 as? NSTextView }.first)
        let originalSize = editor.bounds.size

        surface.configure(scale: 0.5, origin: .zero, tool: .text, swatch: .black,
                          thickness: .medium, dark: false, generation: 0)

        XCTAssertEqual(editor.bounds.size, originalSize)
        XCTAssertEqual(editor.textContainer?.containerSize.width, originalSize.width)
        XCTAssertEqual(editor.frame.width, originalSize.width * 0.5)
        XCTAssertEqual(editor.frame.height, originalSize.height * 0.5)
        XCTAssertEqual((editor.typingAttributes[.font] as? NSFont)?.pointSize, InkText.fontSize)
    }
    #endif
}
