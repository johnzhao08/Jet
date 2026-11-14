import Foundation
import PencilKit
import AppKit
import ImageIO
import CoreText
import JetKit

// End-to-end check of the sync engine: two "devices" (clones) syncing through a local bare repo.

var failures = 0
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() {
        print("  ok    \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)")
    }
}

func shell(_ args: String...) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try! process.run()
    process.waitUntilExit()
}

func stroke(y: CGFloat, at date: Date) -> PKStroke {
    let points = (0..<8).map { i in
        PKStrokePoint(location: CGPoint(x: 40 + CGFloat(i) * 20, y: y), timeOffset: Double(i) * 0.01,
                      size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: 0)
    }
    return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: date))
}

func inkFile(_ strokes: [PKStroke]) -> Data {
    InkDocument(paper: .lined, drawing: PKDrawing(strokes: strokes).dataRepresentation()).encoded()
}

func strokeCount(_ url: URL) -> Int {
    InkDocument.decode((try? Data(contentsOf: url)) ?? Data())?.pkDrawing.strokes.count ?? -1
}

let fm = FileManager.default

// `--sample <dir>` writes a small demo vault instead of running the checks.
if let flag = CommandLine.arguments.firstIndex(of: "--sample"), CommandLine.arguments.count > flag + 1 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    try fm.createDirectory(at: dir.appendingPathComponent("Lectures"), withIntermediateDirectories: true)
    var strokes: [PKStroke] = []
    for row in 0..<4 {
        let points = (0..<120).map { i -> PKStrokePoint in
            let x = 60 + CGFloat(i) * 7.5
            let y = 80 + CGFloat(row) * 96 + sin(CGFloat(i) / (6 + CGFloat(row) * 3)) * 22
            return PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: Double(i) * 0.01,
                                 size: CGSize(width: 5, height: 5), opacity: 1, force: 1, azimuth: 0, altitude: 0)
        }
        let color: PKInkingTool.InkType = row == 3 ? .marker : .pen
        strokes.append(PKStroke(ink: PKInk(color, color: row == 1 ? .systemBlue : row == 3 ? .systemYellow : .black),
                                path: PKStrokePath(controlPoints: points, creationDate: Date())))
    }
    try inkFile(strokes).write(to: dir.appendingPathComponent("Lectures/Waves.ink"))
    try """
    # Physics

    Notes from the **waves** lecture. See also [[Reading list]].

    - [x] Copy the board sketch
    - [ ] Derive the dispersion relation
    - Superposition
      - constructive
      - destructive

    > Handwritten page embedded below.

    ![[Waves.ink]]

    ```
    v = f * lambda
    ```
    """.write(to: dir.appendingPathComponent("Physics.md"), atomically: true, encoding: .utf8)
    try "# Reading list\n\n1. Feynman vol. 1\n2. Back to [[Physics]]\n".write(
        to: dir.appendingPathComponent("Reading list.md"), atomically: true, encoding: .utf8)
    _ = try GitRepository.create(at: dir.path)
    print("Sample vault written to \(dir.path)")
    exit(0)
}
let work = fm.temporaryDirectory.appendingPathComponent("jet-selftest-\(UUID().uuidString)")
try fm.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }

let remote = work.appendingPathComponent("remote.git")
shell("init", "--bare", "--initial-branch=main", remote.path)

let ipad = work.appendingPathComponent("ipad")
let mac = work.appendingPathComponent("mac")
let author = GitAuthor(name: "Self Test", email: "selftest@jet.local")

func sync(_ dir: URL, _ device: String) throws -> SyncReport {
    try SyncEngine.sync(vaultPath: dir.path, credentials: nil, author: author, deviceName: device)
}
func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>" }

do {
    print("1. New vault on iPad, pushed to an empty remote")
    try fm.createDirectory(at: ipad, withIntermediateDirectories: true)
    let ipadRepo = try GitRepository.create(at: ipad.path)
    try ipadRepo.setRemoteURL(remote.path)
    try "# Hello\n".write(to: ipad.appendingPathComponent("Hello.md"), atomically: true, encoding: .utf8)
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let baseStroke = stroke(y: 50, at: t0)
    try inkFile([baseStroke]).write(to: ipad.appendingPathComponent("Sketch.ink"))
    var report = try sync(ipad, "iPad")
    expect(report.committed && report.pushed, "first sync commits and pushes")

    print("2. Mac clones the vault")
    _ = try GitRepository.clone(from: remote.path, to: mac.path, credentials: nil)
    expect(read(mac.appendingPathComponent("Hello.md")) == "# Hello\n", "clone has the note")
    expect(strokeCount(mac.appendingPathComponent("Sketch.ink")) == 1, "clone has the drawing")

    print("3. Mac edits, iPad pulls (fast-forward)")
    try "# Hello\nfrom mac\n".write(to: mac.appendingPathComponent("Hello.md"), atomically: true, encoding: .utf8)
    try fm.createDirectory(at: mac.appendingPathComponent("Folder"), withIntermediateDirectories: true)
    try "nested\n".write(to: mac.appendingPathComponent("Folder/Nested.md"), atomically: true, encoding: .utf8)
    report = try sync(mac, "Mac")
    expect(report.pushed, "mac pushes")
    report = try sync(ipad, "iPad")
    expect(report.workingTreeChanged && !report.pushed, "ipad fast-forwards without pushing")
    expect(read(ipad.appendingPathComponent("Hello.md")) == "# Hello\nfrom mac\n", "ipad sees the mac edit")
    expect(read(ipad.appendingPathComponent("Folder/Nested.md")) == "nested\n", "ipad sees the new folder")

    print("4. Both edit different notes (clean merge)")
    try "ipad only\n".write(to: ipad.appendingPathComponent("IpadNote.md"), atomically: true, encoding: .utf8)
    try "mac only\n".write(to: mac.appendingPathComponent("MacNote.md"), atomically: true, encoding: .utf8)
    _ = try sync(ipad, "iPad")
    report = try sync(mac, "Mac")
    expect(report.conflicts.isEmpty && report.pushed, "mac merges and pushes")
    _ = try sync(ipad, "iPad")
    expect(fm.fileExists(atPath: ipad.appendingPathComponent("MacNote.md").path), "ipad has the mac note")
    expect(fm.fileExists(atPath: mac.appendingPathComponent("IpadNote.md").path), "mac has the ipad note")

    print("5. Both edit the same text note (conflict keeps both)")
    try "# Hello\nipad version\n".write(to: ipad.appendingPathComponent("Hello.md"), atomically: true, encoding: .utf8)
    try "# Hello\nmac version\n".write(to: mac.appendingPathComponent("Hello.md"), atomically: true, encoding: .utf8)
    _ = try sync(ipad, "iPad")
    report = try sync(mac, "Mac")
    expect(report.conflicts == ["Hello.md"], "conflict is reported")
    expect(read(mac.appendingPathComponent("Hello.md")) == "# Hello\nmac version\n", "local version stays in place")
    let copies = try fm.contentsOfDirectory(atPath: mac.path).filter { $0.hasPrefix("Hello (conflict") }
    expect(copies.count == 1, "remote version saved as a conflict copy")
    if let copy = copies.first {
        expect(read(mac.appendingPathComponent(copy)) == "# Hello\nipad version\n", "conflict copy has the remote text")
    }
    _ = try sync(ipad, "iPad")
    expect(read(ipad.appendingPathComponent("Hello.md")) == "# Hello\nmac version\n", "ipad converges")

    print("6. Both draw on the same handwritten note (strokes merge)")
    let ipadStroke = stroke(y: 120, at: t0.addingTimeInterval(60))
    let macStroke = stroke(y: 200, at: t0.addingTimeInterval(90))
    try inkFile([baseStroke, ipadStroke]).write(to: ipad.appendingPathComponent("Sketch.ink"))
    try inkFile([macStroke]).write(to: mac.appendingPathComponent("Sketch.ink")) // mac also erased the base stroke
    _ = try sync(ipad, "iPad")
    report = try sync(mac, "Mac")
    expect(report.conflicts == ["Sketch.ink"], "ink conflict is reported")
    expect(strokeCount(mac.appendingPathComponent("Sketch.ink")) == 2, "merged: both new strokes kept, erased stroke gone")
    let inkCopies = try fm.contentsOfDirectory(atPath: mac.path).filter { $0.hasPrefix("Sketch (") }
    expect(inkCopies.isEmpty, "no conflict copy for ink")
    _ = try sync(ipad, "iPad")
    expect(strokeCount(ipad.appendingPathComponent("Sketch.ink")) == 2, "ipad converges on merged drawing")

    print("7. Deletions propagate")
    try fm.removeItem(at: mac.appendingPathComponent("MacNote.md"))
    _ = try sync(mac, "Mac")
    _ = try sync(ipad, "iPad")
    expect(!fm.fileExists(atPath: ipad.appendingPathComponent("MacNote.md").path), "deleted note is removed on ipad")

    print("8. Nothing to do")
    report = try sync(ipad, "iPad")
    expect(!report.committed && !report.pushed && !report.workingTreeChanged, "idle sync is a no-op")
} catch {
    failures += 1
    print("  FAIL  threw: \(error.localizedDescription)")
}

if CommandLine.arguments.contains("--https") {
    print("9. HTTPS transport (anonymous clone of a public repository)")
    do {
        let dest = work.appendingPathComponent("https-clone")
        _ = try GitRepository.clone(from: "https://github.com/octocat/Hello-World.git", to: dest.path, credentials: nil)
        expect(fm.fileExists(atPath: dest.appendingPathComponent("README").path), "clone over HTTPS works")
    } catch {
        failures += 1
        print("  FAIL  threw: \(error.localizedDescription)")
    }
}

print("10. Links, tags and properties")
do {
    let note = """
    ---
    tags: [project, jet/ideas]
    aliases:
      - Jet app
    status: "draft"
    ---
    # Plan #heading-tag
    Ship the [[Graph View]] and see [[Folder/Daily Notes.md#Today|today]]. #project #2026 #reading/books
    `#code-tag` stays code, and so does a [[Graph View]] mention. Email me at a#b.
    ```
    #fenced
    ```
    """
    let front = NoteSyntax.frontmatter(in: note)
    expect(front.lineCount == 6, "frontmatter spans its --- block")
    expect(front.properties.first { $0.key == "aliases" }?.values == ["Jet app"], "list property parsed")
    expect(front.properties.first { $0.key == "status" }?.values == ["draft"], "quoted value unquoted")
    let tags = NoteSyntax.tags(in: note, properties: front.properties)
    expect(tags == ["project", "jet/ideas", "heading-tag", "reading/books"], "tags from properties and text, no code/numbers/dupes (got \(tags))")
    expect(NoteSyntax.linkTargets(in: note) == ["Graph View", "Daily Notes", "Graph View"], "link targets drop folders, extensions and headings")

    let mentions = "Graph view is neat. The [[Graph View]] link and `Graph View` code don't count; Graph Viewer is another word."
    expect(NoteSyntax.unlinkedMentionRanges(of: "Graph View", in: mentions).count == 1, "unlinked mention: whole words outside links/code")
    expect(NoteSyntax.linkingFirstMention(of: "Graph View", in: mentions)?.hasPrefix("[[Graph view]] is neat") == true,
           "linking a mention keeps its wording")

    let vault = work.appendingPathComponent("links")
    try fm.createDirectory(at: vault, withIntermediateDirectories: true)
    try note.write(to: vault.appendingPathComponent("Plan.md"), atomically: true, encoding: .utf8)
    try "Back to the [[Jet app]].".write(to: vault.appendingPathComponent("Graph View.md"), atomically: true, encoding: .utf8)
    let index = LinkIndex.build(root: vault, markdown: ["Plan.md", "Graph View.md"],
                                titles: ["plan": "Plan.md", "graph view": "Graph View.md"])
    expect(index.outgoing["Plan.md"] == ["Graph View.md"], "outgoing links resolve to existing notes only")
    expect(index.backlinks["Plan.md"] == ["Graph View.md"], "a link to an alias counts as a backlink")
    expect(index.tags["jet/ideas"] == ["Plan.md"], "tag index")
} catch {
    failures += 1
    print("  FAIL  threw: \(error.localizedDescription)")
}

print("11. AI helper (jet-mcp tools)")
do {
    let vault = work.appendingPathComponent("mcp")
    try fm.createDirectory(at: vault.appendingPathComponent("Ink"), withIntermediateDirectories: true)
    try "# Plan\nSee [[Ideas]]. #project".write(to: vault.appendingPathComponent("Plan.md"), atomically: true, encoding: .utf8)
    try inkFile([stroke(y: 60, at: Date())]).write(to: vault.appendingPathComponent("Ink/Sketch.ink"))
    let server = MCPServer(vault: vault)
    func call(_ name: String, _ arguments: [String: Any]) -> (error: Bool, text: String, images: Int) {
        let reply = server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                   "params": ["name": name, "arguments": arguments]])
        let result = reply?["result"] as? [String: Any] ?? [:]
        let content = result["content"] as? [[String: Any]] ?? []
        return (result["isError"] as? Bool ?? true,
                content.compactMap { $0["text"] as? String }.joined(separator: "\n"),
                content.filter { $0["type"] as? String == "image" }.count)
    }
    let initialize = server.handle(["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
    expect((initialize?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18", "initialize echoes a supported protocol version")
    expect(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil, "notifications get no reply")
    expect(call("list_notes", [:]).text.contains("Ink/Sketch.ink  (handwritten)"), "list_notes marks handwritten notes")
    let ink = call("read_note", ["path": "Sketch"])
    expect(!ink.error && ink.images == 1, "read_note returns a handwritten note as an image, found by title")
    expect(!call("create_note", ["path": "Ideas", "content": "First idea"]).error, "create_note adds .md")
    expect(call("create_note", ["path": "Ideas.md", "content": "again"]).error, "create_note refuses to overwrite")
    expect(!call("edit_note", ["path": "Ideas", "old_text": "First", "new_text": "Best"]).error
           && (try? String(contentsOf: vault.appendingPathComponent("Ideas.md"), encoding: .utf8)) == "Best idea",
           "edit_note replaces exact text")
    expect(call("edit_note", ["path": "Sketch", "old_text": "a", "new_text": "b"]).error, "handwritten notes can't be edited")
    expect(call("note_links", ["path": "Plan"]).text.contains("Ideas.md"), "note_links resolves links")
    expect(call("search_notes", ["query": "#project"]).text.contains("Plan.md"), "search_notes finds tags")
    expect(call("read_note", ["path": "../outside"]).error && call("read_note", ["path": ".git/config"]).error,
           "paths outside the vault or in hidden folders are refused")
} catch {
    failures += 1
    print("  FAIL  threw: \(error.localizedDescription)")
}

print("12. Pictures on handwritten pages")
do {
    let plain = inkFile([stroke(y: 60, at: Date(timeIntervalSince1970: 1))])
    expect(!String(decoding: plain, as: UTF8.self).contains("images"), "notes without pictures don't gain an images key")
    let photo = InkImage(id: "p1", path: "Attachments/a.png", frame: CGRect(x: 10, y: 20, width: 300, height: 200))
    let withPhoto = InkDocument(paper: .lined, drawing: Data(), images: [photo]).encoded()
    expect(InkDocument.decode(withPhoto)?.images == [photo], "pictures round-trip")
    expect(InkDocument.decode(withPhoto)?.contentBounds == photo.frame, "content bounds include pictures")

    func doc(_ images: [InkImage]) -> Data { InkDocument(paper: .lined, drawing: Data(), images: images).encoded() }
    var moved = photo
    moved.frame = photo.frame.offsetBy(dx: 0, dy: 500)
    let other = InkImage(id: "p2", path: "Attachments/b.png", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    let merged = InkMerge.merge(base: doc([photo]), ours: doc([photo, other]), theirs: doc([moved])).flatMap(InkDocument.decode)
    expect(merged?.images?.map(\.id) == ["p1", "p2"], "merge keeps a picture added on this device")
    expect(merged?.images?.first?.frame == moved.frame, "merge takes the other device's move")
    let removed = InkMerge.merge(base: doc([photo]), ours: doc([photo]), theirs: doc([])).flatMap(InkDocument.decode)
    expect(removed?.images == nil, "merge drops a picture deleted on the other device")

    // A 3000x1000 opaque bitmap becomes a 2560-wide JPEG; a small PNG stays a PNG, untouched.
    func png(width: Int, height: Int, alpha: Bool) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        return rep.representation(using: .png, properties: [:])!
    }
    let big = ImageFiles.prepareForVault(png(width: 3000, height: 1000, alpha: false), type: .png)
    let bigSize = big.flatMap { CGImageSourceCreateWithData($0.data as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    expect(big?.ext == "jpg" && bigSize?.width == 2560, "large photos are scaled to 2560 px and stored as JPEG")
    let small = png(width: 200, height: 100, alpha: true)
    expect(ImageFiles.prepareForVault(small, type: .png).map { $0.ext == "png" && $0.data == small } == true,
           "small PNGs are kept as they are")
    expect(ImageFiles.prepareForVault(Data("not an image".utf8), type: nil) == nil, "non-images are refused")

    // The AI helper sees pictures on the page.
    let vault = work.appendingPathComponent("pictures")
    try fm.createDirectory(at: vault.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
    try png(width: 200, height: 100, alpha: false).write(to: vault.appendingPathComponent("Attachments/a.png"))
    try withPhoto.write(to: vault.appendingPathComponent("Photo.ink"))
    let reply = MCPServer(vault: vault).handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                 "params": ["name": "read_note", "arguments": ["path": "Photo"]]])
    let content = ((reply?["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
    expect(content.contains { $0["type"] as? String == "image" }, "read_note renders a page that only has a picture")
} catch {
    failures += 1
    print("  FAIL  threw: \(error.localizedDescription)")
}

print("13. PDFs and other files")
do {
    // A two-page PDF with text; the second page is landscape and rotated 90°, so it shows portrait.
    func makePDF(at url: URL) {
        let context = CGContext(url as CFURL, mediaBox: nil, nil)!
        var letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        context.beginPage(mediaBox: &letter)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Lecture 4: Entropy",
                                                    attributes: [.font: NSFont.systemFont(ofSize: 24)]))
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPage()
        var landscape = CGRect(x: 0, y: 0, width: 792, height: 612)
        context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &landscape, length: MemoryLayout<CGRect>.size),
                              "Rotate": 90] as CFDictionary)
        context.endPDFPage()
        context.closePDF()
    }
    let vault = work.appendingPathComponent("files")
    try fm.createDirectory(at: vault.appendingPathComponent("Course"), withIntermediateDirectories: true)
    let pdfURL = vault.appendingPathComponent("Course/Lecture.pdf")
    makePDF(at: pdfURL)
    guard let pages = PDFPages(url: pdfURL) else { throw CocoaError(.fileReadCorruptFile) }
    expect(pages.count == 2, "PDF pages are laid out")
    expect(abs(pages.frames[0].height - 1024 * 792 / 612) < 0.5 && pages.frames[0].minY == PDFPages.gap,
           "pages are scaled to the page width, below a gap")
    expect(pages.frames[1].minY > pages.frames[0].maxY, "pages are stacked")
    expect(VaultSession.annotationsPath(for: "Course/Lecture.pdf") == "Course/.Lecture.pdf.ink"
           && VaultSession.annotationsPath(for: "A.pdf") == ".A.pdf.ink", "annotations live in a hidden file beside the PDF")

    // Ink on page 1 shows up in the annotated export and in what the AI helper sees.
    let ink = InkDocument(paper: .blank, drawing: PKDrawing(strokes: [stroke(y: 300, at: Date())]).dataRepresentation())
    try ink.encoded().write(to: vault.appendingPathComponent("Course/.Lecture.pdf.ink"))
    let exported = pages.annotatedPDF(drawing: ink.pkDrawing, images: [], root: vault)
    let reread = exported.flatMap { CGDataProvider(data: $0 as CFData) }.flatMap(CGPDFDocument.init)
    expect(reread?.numberOfPages == 2, "the annotated PDF keeps every page")
    let rendered = pages.render(0, drawing: ink.pkDrawing, images: [], root: vault, scale: 1)
    expect(rendered?.width == 1024, "a page renders at page width")

    let reply = MCPServer(vault: vault).handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                 "params": ["name": "read_note", "arguments": ["path": "Course/Lecture.pdf"]]])
    let content = ((reply?["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
    let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    expect(text.contains("Entropy") && text.contains("has handwritten annotations"), "read_note gives a PDF's text and notes its annotations")
    expect(content.filter { $0["type"] as? String == "image" }.count == 2, "read_note shows each PDF page as an image")
    let list = MCPServer(vault: vault).handle(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                                "params": ["name": "list_notes", "arguments": [:]]])
    let listed = (((list?["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
    expect(listed.contains("Course/Lecture.pdf  (PDF)") && !listed.contains(".Lecture"), "list_notes marks PDFs and hides annotation files")

    expect(FileKind(path: "a/b.PDF") == .pdf && FileKind(path: "x.json") == .text && FileKind(path: "y.docx") == .other
           && FileKind(path: "z.HEIC") == .image, "file kinds by extension")

    // Importing copies under a free name; renaming and deleting a PDF take its annotations along.
    try MainActor.assumeIsolated {
        let session = VaultSession(ref: VaultRef(name: "files", location: vault.path))
        let outside = work.appendingPathComponent("Lecture.pdf")
        try fm.copyItem(at: pdfURL, to: outside)
        let imported = session.importFiles([outside], into: "Course")
        expect(imported == ["Course/Lecture 2.pdf"] && session.selection == "Course/Lecture 2.pdf", "import keeps the name, made unique, and opens it")
        session.rename("Course/Lecture.pdf", to: "Thermo")
        expect(session.exists("Course/Thermo.pdf") && session.exists("Course/.Thermo.pdf.ink") && !session.exists("Course/.Lecture.pdf.ink"),
               "renaming a PDF moves its annotations")
        session.delete("Course/Thermo.pdf")
        expect(!session.exists("Course/.Thermo.pdf.ink"), "deleting a PDF deletes its annotations")
    }
} catch {
    failures += 1
    print("  FAIL  threw: \(error.localizedDescription)")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
