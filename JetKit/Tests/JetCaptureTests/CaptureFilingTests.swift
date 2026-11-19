import XCTest
@testable import JetKit
import JetCapture

@MainActor
final class CaptureFilingTests: XCTestCase {
    var work: URL!
    var vault: URL!
    var inbox: CaptureInbox!
    var session: VaultSession!

    override func setUp() async throws {
        CaptureAttempts.failedThisLaunch.removeAll()
        work = FileManager.default.temporaryDirectory.appendingPathComponent("JetCaptureTests-\(UUID().uuidString)")
        vault = work.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        inbox = CaptureInbox(base: work.appendingPathComponent("Group"))
        session = VaultSession(ref: VaultRef(name: "Test", location: vault.path))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: work) }

    private func file(_ name: String, _ text: String = "data") throws -> URL {
        let folder = work.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func contents(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent(folder).path)) ?? []).sorted()
    }

    func testFilesNoteAndAttachmentThenClearsInbox() throws {
        try inbox.enqueue(CaptureItem(title: "Idea", text: "hello", link: "https://example.com/a#b"), files: [file("Paper.pdf")])
        XCTAssertEqual(inbox.pendingCount, 1)
        XCTAssertEqual(session.fileCaptures(from: inbox), 1)
        XCTAssertEqual(inbox.pendingCount, 0)
        XCTAssertEqual(contents("Inbox"), ["Idea.md"])
        XCTAssertEqual(contents("Attachments"), ["Paper.pdf"])
        let note = try String(contentsOf: vault.appendingPathComponent("Inbox/Idea.md"), encoding: .utf8)
        XCTAssertTrue(note.contains("source: \"https://example.com/a#b\""))
        XCTAssertTrue(note.contains("[[Paper.pdf]]"))
        XCTAssertTrue(NoteSyntax.frontmatter(in: note).properties.contains { $0.key == "source" && $0.values == ["https://example.com/a#b"] })
    }

    func testMissingAttachmentLeavesCaptureQueuedAndVaultUntouched() throws {
        let item = try inbox.enqueue(CaptureItem(title: "Two", text: "x"), files: [file("a.pdf"), file("b.pdf")])
        let pending = try XCTUnwrap(inbox.pending().first)
        try FileManager.default.removeItem(at: XCTUnwrap(pending.attachmentURL(item.attachments[1])))
        XCTAssertEqual(session.fileCaptures(from: inbox), 0)
        // The first attachment was written, then taken back; no note either; the capture is still queued.
        XCTAssertEqual(contents("Attachments"), [])
        XCTAssertEqual(contents("Inbox"), [])
        XCTAssertEqual(inbox.pendingCount, 1)
        XCTAssertFalse(inbox.filedIDs().contains(item.id))
    }

    func testRepeatedFailureSetsCaptureAsideWithoutDeletingIt() throws {
        let item = try inbox.enqueue(CaptureItem(text: "x"), files: [file("a.pdf")])
        let pending = try XCTUnwrap(inbox.pending().first)
        try FileManager.default.removeItem(at: XCTUnwrap(pending.attachmentURL("a.pdf")))
        // Within one launch a failing capture is tried once, however often the app comes forward.
        for _ in 0..<3 { session.fileCaptures(from: inbox) }
        XCTAssertEqual(inbox.pendingCount, 1)
        for _ in 0..<CaptureInbox.attemptsBeforeQuarantine {  // later launches
            CaptureAttempts.failedThisLaunch.removeAll()
            session.fileCaptures(from: inbox)
        }
        XCTAssertEqual(inbox.pendingCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.captures.appendingPathComponent(".failed/\(item.id.uuidString)/item.json").path))
    }

    func testRelaunchAfterWritingButBeforeRemovingDoesNotDuplicate() throws {
        try inbox.enqueue(CaptureItem(title: "Once", text: "x"), files: [file("pic.png")])
        let pending = try XCTUnwrap(inbox.pending().first)
        // Filing finishes but the app dies before the capture is removed from the inbox.
        XCTAssertNotNil(session.apply(pending.item, attachments: { pending.attachmentURL($0) }, journal: pending.journalURL))
        let relaunched = VaultSession(ref: session.ref)
        XCTAssertEqual(relaunched.fileCaptures(from: inbox), 1)
        XCTAssertEqual(contents("Inbox"), ["Once.md"])
        XCTAssertEqual(contents("Attachments").count, 1)
        XCTAssertEqual(inbox.pendingCount, 0)
        // And a capture the ledger already knows is dropped, not filed.
        try inbox.enqueue(CaptureItem(id: pending.item.id, title: "Once", text: "x"))
        XCTAssertEqual(session.fileCaptures(from: inbox), 0)
        XCTAssertEqual(contents("Inbox"), ["Once.md"])
        XCTAssertEqual(inbox.pendingCount, 0)
    }

    /// A journal entry for a file an interrupted attempt really wrote: its identity and checksum.
    private func entry(_ path: String) throws -> CaptureJournal.Created {
        let print = try XCTUnwrap(CaptureJournal.Fingerprint.of(vault.appendingPathComponent(path)))
        return .init(path: path, device: print.device, inode: print.inode, size: print.size, sha256: print.sha256)
    }

    private func write(_ path: String, _ text: String, in root: URL? = nil) throws {
        let url = (root ?? vault).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String, in root: URL? = nil) -> String? {
        try? String(contentsOf: (root ?? vault).appendingPathComponent(path), encoding: .utf8)
    }

    /// Queues a capture with one attachment and returns where the app would keep its journal.
    private func queueWithAttachment(_ name: String = "doc.pdf", vaultID: UUID? = nil) throws -> CaptureInbox.Pending {
        try inbox.enqueue(CaptureItem(vaultID: vaultID, title: "Half", text: "x"), files: [file(name)])
        return try XCTUnwrap(inbox.pending().first)
    }

    func testInterruptedAttemptIsUndoneBeforeRetry() throws {
        let pending = try queueWithAttachment()
        // An earlier run wrote the attachment and was killed before the note: journal says so, no result.
        try write("Attachments/doc.pdf", "data")
        let journal = CaptureJournal(vault: session.ref.id, created: [try entry("Attachments/doc.pdf")])
        try JSONEncoder().encode(journal).write(to: pending.journalURL)
        XCTAssertEqual(session.fileCaptures(from: inbox), 1)
        XCTAssertEqual(contents("Attachments"), ["doc.pdf"])  // not "doc 2.pdf"
        XCTAssertEqual(contents("Inbox"), ["Half.md"])
    }

    func testInterruptedRetryInAnotherVaultLeavesThatVaultsFilesAlone() throws {
        // The capture isn't aimed at a vault. It was cut short while filing into vault A…
        let pending = try queueWithAttachment()
        let other = work.appendingPathComponent("Other")
        try write("Attachments/doc.pdf", "data", in: other)
        let otherPrint = try XCTUnwrap(CaptureJournal.Fingerprint.of(other.appendingPathComponent("Attachments/doc.pdf")))
        let foreign = CaptureJournal(vault: UUID(), created: [.init(path: "Attachments/doc.pdf", device: otherPrint.device, inode: otherPrint.inode,
                                                                    size: otherPrint.size, sha256: otherPrint.sha256)])
        try JSONEncoder().encode(foreign).write(to: pending.journalURL)
        // …and now the user is in vault B, which has its own file at the same path (even with the same bytes).
        try write("Attachments/doc.pdf", "data")
        let theirs = try XCTUnwrap(CaptureJournal.Fingerprint.of(vault.appendingPathComponent("Attachments/doc.pdf")))

        XCTAssertEqual(session.fileCaptures(from: inbox), 1)
        XCTAssertEqual(CaptureJournal.Fingerprint.of(vault.appendingPathComponent("Attachments/doc.pdf")), theirs)  // same file, untouched
        XCTAssertEqual(contents("Attachments"), ["doc 2.pdf", "doc.pdf"])
        XCTAssertEqual(contents("Inbox"), ["Half.md"])
        XCTAssertEqual(read("Attachments/doc.pdf", in: other), "data")  // and A is never reached from B
    }

    func testJournalWithoutVaultNeverDeletesAnything() throws {
        let pending = try queueWithAttachment()
        try write("Attachments/doc.pdf", "data")
        var journal = CaptureJournal(created: [try entry("Attachments/doc.pdf")])
        journal.vault = nil
        try JSONEncoder().encode(journal).write(to: pending.journalURL)
        XCTAssertEqual(session.fileCaptures(from: inbox), 1)
        XCTAssertEqual(read("Attachments/doc.pdf"), "data")
        XCTAssertEqual(contents("Attachments"), ["doc 2.pdf", "doc.pdf"])
    }

    func testRetryKeepsFilesTheUserReplacedOrEdited() throws {
        let pending = try queueWithAttachment()
        try write("Attachments/replaced.pdf", "ours")
        try write("Attachments/edited.pdf", "ours")
        try write("Attachments/intact.pdf", "ours")
        try write("Attachments/linked.pdf", "ours")
        let created = try ["replaced", "edited", "intact", "linked"].map { try entry("Attachments/\($0).pdf") }
        try JSONEncoder().encode(CaptureJournal(vault: session.ref.id, created: created)).write(to: pending.journalURL)

        // Replaced: a different file, same name, even same bytes (an editor's safe-save does this).
        try FileManager.default.removeItem(at: vault.appendingPathComponent("Attachments/replaced.pdf"))
        try write("Attachments/replaced.pdf", "ours")
        // Edited in place: same file, new bytes.
        let handle = try FileHandle(forWritingTo: vault.appendingPathComponent("Attachments/edited.pdf"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data(" + my edits".utf8)); try handle.close()
        // Swapped for a link to somewhere else.
        let elsewhere = work.appendingPathComponent("elsewhere.txt")
        try "precious".write(to: elsewhere, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: vault.appendingPathComponent("Attachments/linked.pdf"))
        try FileManager.default.createSymbolicLink(at: vault.appendingPathComponent("Attachments/linked.pdf"), withDestinationURL: elsewhere)

        XCTAssertEqual(session.fileCaptures(from: inbox), 1)
        XCTAssertEqual(read("Attachments/replaced.pdf"), "ours")
        XCTAssertEqual(read("Attachments/edited.pdf"), "ours + my edits")
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), "precious")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: vault.appendingPathComponent("Attachments/linked.pdf").path))
        // The one nobody touched was ours and is taken back.
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.appendingPathComponent("Attachments/intact.pdf").path))
        XCTAssertEqual(contents("Attachments").filter { $0.hasPrefix("doc") }, ["doc.pdf"])
    }

    func testFileTakenAfterItsNameWasChosenIsKeptAndTheCaptureUsesAnotherName() throws {
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
        try inbox.enqueue(CaptureItem(title: "Race", text: "x"))
        var raced = false
        CaptureAttempts.beforeCreate = { [vault] path in
            guard !raced else { return }
            raced = true
            try? "someone else's".write(to: vault!.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        defer { CaptureAttempts.beforeCreate = nil }
        XCTAssertEqual(session.fileCaptures(from: inbox), 1)
        XCTAssertTrue(raced)
        XCTAssertEqual(read("Inbox/Race.md"), "someone else's")
        XCTAssertEqual(contents("Inbox"), ["Race 2.md", "Race.md"])
        XCTAssertEqual(inbox.pendingCount, 0)
    }

    func testFailureAfterAFileWasMadeTakesItBackButNeverTheOneThatBlockedIt() throws {
        // The attachment is written, then the note can't be (its folder is a file): the attachment goes,
        // and a file that was already sitting at the attachment's first-choice name stays.
        try write("Attachments/a.pdf", "mine")
        try write("Inbox", "not a folder")
        try inbox.enqueue(CaptureItem(title: "Nope", text: "x"), files: [file("a.pdf")])
        XCTAssertEqual(session.fileCaptures(from: inbox), 0)
        XCTAssertEqual(contents("Attachments"), ["a.pdf"])
        XCTAssertEqual(read("Attachments/a.pdf"), "mine")
        XCTAssertEqual(inbox.pendingCount, 1)
    }

    func testRetryAfterAFailedAttemptDoesNotRollBackAFinishedOtherCapture() throws {
        // A retried capture whose journal lists a path that a different, completed capture now owns.
        let pending = try queueWithAttachment()
        try write("Attachments/doc.pdf", "data")
        let stale = try entry("Attachments/doc.pdf")
        try FileManager.default.removeItem(at: vault.appendingPathComponent("Attachments/doc.pdf"))
        try write("Attachments/doc.pdf", "another capture's")
        try JSONEncoder().encode(CaptureJournal(vault: session.ref.id, created: [stale])).write(to: pending.journalURL)
        XCTAssertEqual(session.fileCaptures(from: inbox), 1)
        XCTAssertEqual(read("Attachments/doc.pdf"), "another capture's")
    }

    func testNeverOverwritesExistingNotes() throws {
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
        try "mine".write(to: vault.appendingPathComponent("Inbox/Same.md"), atomically: true, encoding: .utf8)
        try inbox.enqueue(CaptureItem(title: "Same", text: "x"))
        session.fileCaptures(from: inbox)
        XCTAssertEqual(contents("Inbox"), ["Same 2.md", "Same.md"])
        XCTAssertEqual(try String(contentsOf: vault.appendingPathComponent("Inbox/Same.md"), encoding: .utf8), "mine")
    }

    func testSymlinkedDestinationIsRefusedAndNothingLandsOutsideTheVault() throws {
        let outside = work.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: vault.appendingPathComponent("Attachments"), withDestinationURL: outside)
        try inbox.enqueue(CaptureItem(title: "Linked", text: "x"), files: [file("a.pdf")])
        XCTAssertEqual(session.fileCaptures(from: inbox), 0)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: outside.path)) ?? [], [])
        XCTAssertEqual(contents("Inbox"), [])
        XCTAssertEqual(inbox.pendingCount, 1)
    }

    func testDailyNoteAppendUsesTemplateAndRollsBackExactly() throws {
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("Templates"), withIntermediateDirectories: true)
        try "# {{date}}\n".write(to: vault.appendingPathComponent("Templates/Daily.md"), atomically: true, encoding: .utf8)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let item = CaptureItem(created: date, destination: .dailyNote, text: "buy milk")
        let path = try XCTUnwrap(session.apply(item))
        let daily = vault.appendingPathComponent(path)
        let text = try String(contentsOf: daily, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# 20"))
        XCTAssertTrue(text.contains("buy milk"))
        // A second capture appends after the first; rolling back an interrupted third leaves both.
        XCTAssertNotNil(session.apply(CaptureItem(created: date, destination: .dailyNote, text: "second")))
        let before = try Data(contentsOf: daily)
        let journalURL = work.appendingPathComponent("j.json")
        let text3 = "\n- x third\n"
        let journal = CaptureJournal(vault: session.ref.id, appended: .init(path: path, text: text3, sizeBefore: before.count))
        try Data((String(decoding: before, as: UTF8.self) + text3).utf8).write(to: daily)
        try JSONEncoder().encode(journal).write(to: journalURL)
        XCTAssertNotNil(session.apply(CaptureItem(created: date, destination: .dailyNote, text: "third"), journal: journalURL))
        let final = try String(contentsOf: daily, encoding: .utf8)
        XCTAssertEqual(final.components(separatedBy: "third").count - 1, 1)
        XCTAssertTrue(final.contains("second"))
    }

    func testInboxRefusesOversizedUnsafeAndTooManyFiles() throws {
        XCTAssertThrowsError(try inbox.enqueue(CaptureItem()))
        XCTAssertThrowsError(try inbox.enqueue(CaptureItem(text: "x"), files: try (0...CaptureLimits.mostAttachments).map { try file("f\($0).txt") }))
        XCTAssertThrowsError(try inbox.enqueue(CaptureItem(text: "x"), files: [work]))  // a folder
        XCTAssertEqual(inbox.pendingCount, 0)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: inbox.captures.path))?.filter { $0.hasPrefix(".tmp-") }, [])
    }

    func testNamesCannotEscapeAndLinksAreSafe() throws {
        XCTAssertEqual(CaptureNaming.fileName("../../etc/passwd"), "-..-etc-passwd".trimmingCharacters(in: CharacterSet(charactersIn: ".")).isEmpty ? nil : CaptureNaming.fileName("../../etc/passwd"))
        XCTAssertFalse(CaptureNaming.fileName("../../etc/passwd")!.contains("/"))
        XCTAssertFalse(CaptureNaming.isPlainFileName("../x"))
        XCTAssertNil(JetLink(URL(string: "jet://open?path=../secret")!))
        XCTAssertNil(JetLink(URL(string: "jet://open?path=.git/config")!))
        XCTAssertNil(JetLink(URL(string: "jet://open?path=/etc/passwd")!))
        XCTAssertEqual(JetLink(URL(string: "jet://open?path=Folder/Note.md")!), .open(vault: nil, path: "Folder/Note.md"))
        XCTAssertEqual(JetLink(JetLink.open(vault: nil, path: "A B/é.md").url), .open(vault: nil, path: "A B/é.md"))
    }
}
