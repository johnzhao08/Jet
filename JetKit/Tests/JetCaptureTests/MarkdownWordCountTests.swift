import XCTest
@testable import JetKit

final class MarkdownWordCountTests: XCTestCase {
    func testUnicodeWordsGraphemesAndWhitespace() {
        let count = MarkdownWordCount(source: "Cafe\u{301},世界!\u{00A0}👩🏽‍💻\tgo\r\n")
        XCTAssertEqual(count.total.words, 3)
        XCTAssertEqual(count.total.characters, 14)
        XCTAssertEqual(count.total.charactersExcludingSpaces, 11)
        XCTAssertNil(count.selection)
    }

    func testSelectionIsClippedToBody() {
        let source = "---\r\ntitle: Hidden\r\n---\r\n# One two"
        let count = MarkdownWordCount(source: source, selection: (source as NSString).range(of: "---\r\n# One"))
        XCTAssertEqual(count.total.words, 2)
        XCTAssertEqual(count.total.characters, 9)
        XCTAssertEqual(count.selection?.words, 1)
        XCTAssertEqual(count.selection?.characters, 5)
        XCTAssertEqual(count.selection?.charactersExcludingSpaces, 4)
    }

    func testMetadataOnlySelectionAndEmptyBody() {
        let count = MarkdownWordCount(source: "---\ntitle: Hidden\n---", selection: NSRange(location: 0, length: 3))
        XCTAssertEqual(count.total.words, 0)
        XCTAssertEqual(count.total.characters, 0)
        XCTAssertEqual(count.selection?.characters, 0)
    }
}
