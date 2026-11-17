import Foundation
import PencilKit
import AppKit
import ImageIO
import UniformTypeIdentifiers
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

print("14. Opening and importing files from elsewhere")
do {
    let vault = work.appendingPathComponent("drops")
    try fm.createDirectory(at: vault.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
    try "# Inside".write(to: vault.appendingPathComponent("Inbox/Inside.md"), atomically: true, encoding: .utf8)
    let outside = work.appendingPathComponent("outside")
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    func sparse(_ name: String, megabytes: Int) throws -> URL {
        let url = outside.appendingPathComponent(name)
        fm.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(megabytes) * 1_000_000)
        try handle.close()
        return url
    }
    let small = outside.appendingPathComponent("Small.md")
    try "hi".write(to: small, atomically: true, encoding: .utf8)
    let large = try sparse("Slides.pdf", megabytes: 60)
    let huge = try sparse("Video.mov", megabytes: 120)

    try MainActor.assumeIsolated {
        let app = AppModel()
        let ref = VaultRef(name: "drops", location: vault.path)
        app.vaults = [ref]
        app.open(ref)
        guard let session = app.session else { throw CocoaError(.fileNoSuchFile) }

        app.receive([vault.appendingPathComponent("Inbox/Inside.md")])
        expect(session.selection == "Inbox/Inside.md" && !session.exists("Inside.md"), "a file already in the vault opens in place, not copied")

        app.receive([small], into: "Inbox")
        expect(session.exists("Inbox/Small.md") && session.importReview == nil, "a small file from outside is imported straight away")

        app.receive([large, huge], into: "Inbox")
        expect(session.importReview?.large.count == 1 && session.importReview?.tooLarge.count == 1 && !session.exists("Inbox/Slides.pdf"),
               "50-100 MB files wait for confirmation; files over 100 MB are held back")
        session.resolveImport(includeLarge: true)
        expect(session.exists("Inbox/Slides.pdf") && !session.exists("Inbox/Video.mov"), "confirming imports the large file but never the one over 100 MB")

        app.receive([huge])
        session.resolveImport(includeLarge: true)
        expect(!session.exists("Video.mov"), "a file over 100 MB on its own is refused too")
        expect(app.locate(vault.appendingPathComponent(".git/config")) == nil, "hidden files in a vault aren't opened as notes")
    }
} catch {
    failures += 1
    print("  FAIL  threw: \(error.localizedDescription)")
}

print("15. Moving files between folders")
do {
    let vault = work.appendingPathComponent("moves")
    for folder in ["Daily", "Course/Week 1"] {
        try fm.createDirectory(at: vault.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    try "# Welcome".write(to: vault.appendingPathComponent("Welcome.md"), atomically: true, encoding: .utf8)
    try "# Other".write(to: vault.appendingPathComponent("Daily/Welcome.md"), atomically: true, encoding: .utf8)
    try Data("%PDF".utf8).write(to: vault.appendingPathComponent("Slides.pdf"))
    try Data("{}".utf8).write(to: vault.appendingPathComponent(".Slides.pdf.ink"))
    try "notes".write(to: vault.appendingPathComponent("Course/Week 1/Notes.md"), atomically: true, encoding: .utf8)
    MainActor.assumeIsolated {
        let session = VaultSession(ref: VaultRef(name: "moves", location: vault.path))
        session.selection = "Welcome.md"
        let moved = session.move("Welcome.md", into: "Daily")
        expect(moved == "Daily/Welcome 2.md" && session.selection == moved && !session.exists("Welcome.md"),
               "moving a note into a folder keeps it open and doesn't overwrite a same-named note")
        expect(session.move("Slides.pdf", into: "Course") == "Course/Slides.pdf" && session.exists("Course/.Slides.pdf.ink"),
               "a moved PDF takes its annotations along")
        session.selection = "Course/Week 1/Notes.md"
        expect(session.move("Course/Week 1", into: "") == "Week 1" && session.selection == "Week 1/Notes.md",
               "moving a folder moves what's inside, and the open note follows")
        expect(session.move("Course", into: "Course") == nil && session.exists("Course"), "a folder can't move into itself")
        expect(session.move("Daily/Welcome 2.md", into: "Daily") == nil, "dropping on its own folder does nothing")
        expect(session.move("Daily/Welcome 2.md", into: "") == "Welcome 2.md"
               && !session.exists("Daily/Welcome 2.md"), "a nested note moves to the top level without leaving a copy")
    }
} catch {
    failures += 1
    print("  FAIL  threw: \(error.localizedDescription)")
}

print("16. What a drop is, and what Jet refuses to import")
do {
    let file = work.appendingPathComponent("Dropped note.md")
    try "# Dropped".write(to: file, atomically: true, encoding: .utf8)
    let finder = NSItemProvider(contentsOf: file)!
    let row = VaultItem(path: "Welcome.md").itemProvider
    expect(FileDrop.classify([row]) == .vaultItems, "a dragged sidebar row is a move, never an import")
    expect(FileDrop.operation(for: [row], into: "Daily") == .move, "a folder drop proposes a move")
    expect(FileDrop.operation(for: [row], into: "") == .move, "the top-level target proposes a move")
    expect(FileDrop.operation(for: [row], into: nil) == .forbidden, "the window import target refuses internal drags")
    expect(FileDrop.operation(for: [finder], into: "") == .copy, "external file drops still propose copying")
    expect(FileDrop.operation(for: [row, finder], into: "Daily") == .move, "internal drag types take priority over file representations")
    expect(FileDrop.classify([finder]) == .files, "a Finder file is a file")
    expect(FileDrop.classify([NSItemProvider(object: "just text" as NSString)]) == .nothing, "dragged text isn't a file")
    let semaphore = DispatchSemaphore(value: 0)
    var paths: [String] = []
    var urls: [URL] = []
    Task.detached {
        paths = await FileDrop.vaultPaths(in: [row])
        urls = await FileDrop.fileURLs(in: [finder])
        semaphore.signal()
    }
    semaphore.wait()
    expect(paths == ["Welcome.md"], "a dragged row decodes to its path")
    expect(urls.map(\.standardizedFileURL.path) == [file.standardizedFileURL.path], "a Finder drop gives the original file")

    // A browser image drag, as its pasteboard types (checked on every mouse move, without loading anything).
    let browserImage = ["public.url", "dyn.agu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu", "public.utf8-plain-text",
                        "public.html", "com.apple.pasteboard.promised-file-url", "com.apple.pasteboard.promised-file-content-type"]
    expect(FileDrop.classify(types: browserImage) == .files, "a browser image drag is a file")
    expect(FileDrop.classify(types: ["public.jpeg", "public.url"]) == .files, "image data next to its web address is a file")
    expect(FileDrop.classify(types: ["public.utf8-plain-text", "dyn.agu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu",
                                     "public.url", "public.html"]) == .nothing, "a dragged link or text, legacy types included, isn't a file")
    expect(FileDrop.classify(types: ["com.johnzhao.jet.vault-item", "public.file-url"]) == .vaultItems, "rows still win by type")
    expect(FileDrop.operation(for: FileDrop.classify(types: browserImage), into: nil) == .copy, "the window accepts a browser image")

    // A picture dropped on a handwritten page or a PDF page: centred where it lands, kept on that page.
    let page = CGRect(x: 0, y: 0, width: InkDocument.pageWidth, height: .infinity)
    let dropped = InkNoteModel.pictureFrame(pixelSize: CGSize(width: 400, height: 300), at: CGPoint(x: 300, y: 900), within: page)
    expect(dropped == CGRect(x: 200, y: 825, width: 200, height: 150), "a dropped picture is centred on the drop at half its pixel size")
    let huge = InkNoteModel.pictureFrame(pixelSize: CGSize(width: 8000, height: 6000), at: CGPoint(x: 5, y: 5), within: page)
    expect(huge.width <= 560 && huge.minX >= 16 && huge.minY >= 16, "a big photo is scaled down and kept inside the page")
    let pdfPage = CGRect(x: 0, y: 1000, width: InkDocument.pageWidth, height: 1000)
    let low = InkNoteModel.pictureFrame(pixelSize: CGSize(width: 400, height: 400), at: CGPoint(x: 300, y: 1990), within: pdfPage)
    expect(low.maxY <= pdfPage.maxY - 16, "a picture dropped at a PDF page's bottom edge stays on that page")

    // An image file opens as one page to put pictures on, shaped like the image; the file isn't touched.
    let photo = work.appendingPathComponent("Photo.png")
    let tiny = CGContext(data: nil, width: 300, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    tiny.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    tiny.fill(CGRect(x: 0, y: 0, width: 300, height: 150))
    let photoDest = CGImageDestinationCreateWithURL(photo as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(photoDest, tiny.makeImage()!, nil)
    CGImageDestinationFinalize(photoDest)
    let photoBytes = try Data(contentsOf: photo)
    let photoPage = PDFPages(imageAt: photo)
    expect(photoPage?.count == 1 && abs((photoPage?.frames[0].height ?? 0) - InkDocument.pageWidth / 2) < 1,
           "an image file opens as one page with the image's shape")
    expect(PDFPages(imageAt: work.appendingPathComponent("Dropped note.md")) == nil, "a file that isn't an image doesn't")
    expect((try? Data(contentsOf: photo)) == photoBytes, "opening an image as a page leaves the file as it was")
    expect(VaultSession.annotationsPath(for: "Pics/Photo.png") == "Pics/.Photo.png.ink", "its pictures live in a hidden sidecar")

    // What a Markdown note takes in: pictures only. Other files fall through to the window's import.
    expect(FileDrop.carriesImage(types: browserImage, fileURLs: []), "a note takes a browser image")
    expect(FileDrop.carriesImage(types: ["public.png"], fileURLs: []), "a note takes image data")
    expect(FileDrop.carriesImage(types: ["public.file-url"], fileURLs: [URL(fileURLWithPath: "/tmp/Photo.HEIC")]),
           "a note takes an image file from Finder")
    expect(!FileDrop.carriesImage(types: ["public.file-url"], fileURLs: [URL(fileURLWithPath: "/tmp/notes.pdf")]),
           "a PDF from Finder isn't put in the note")
    expect(!FileDrop.carriesImage(types: ["public.utf8-plain-text", "public.url"], fileURLs: []), "nor is a link")
    expect(!FileDrop.carriesImage(types: ["com.johnzhao.jet.vault-item", "public.png"], fileURLs: []),
           "nor a sidebar row")

    // Dropped: the image is read out of the provider, not its web address.
    let jpeg = work.appendingPathComponent("web-image-source")
    try Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]).write(to: jpeg)
    let web = NSItemProvider()
    web.registerObject(URL(string: "https://example.com/images/cat")! as NSURL, visibility: .all)
    web.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { done in
        done(jpeg, false, nil)
        return nil
    }
    web.suggestedName = "cat"
    var webURLs: [URL] = []
    Task.detached {
        webURLs = await FileDrop.fileURLs(in: [web])
        semaphore.signal()
    }
    semaphore.wait()
    expect(webURLs.count == 1 && webURLs.first?.lastPathComponent == "cat.jpeg"
           && (try? Data(contentsOf: webURLs[0])) == (try? Data(contentsOf: jpeg)),
           "a dropped web image arrives as a .jpeg file with its bytes")

    let vault = work.appendingPathComponent("guarded")
    let outside = work.appendingPathComponent("guarded-outside")
    try fm.createDirectory(at: vault, withIntermediateDirectories: true)
    let app = outside.appendingPathComponent("Tool.app")
    try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try "x".write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
    let locked = outside.appendingPathComponent("Private")
    try fm.createDirectory(at: locked, withIntermediateDirectories: true)
    try "secret".write(to: locked.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    chmod(locked.path, 0o000)
    let many = outside.appendingPathComponent("Dump")
    try fm.createDirectory(at: many, withIntermediateDirectories: true)
    for index in 0...1000 { fm.createFile(atPath: many.appendingPathComponent("\(index).txt").path, contents: Data("x".utf8)) }
    // A folder like ~/Downloads, which forbids deleting itself.
    let protected = outside.appendingPathComponent("Protected")
    try fm.createDirectory(at: protected, withIntermediateDirectories: true)
    try "keep".write(to: protected.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
    let acl = Process()
    acl.executableURL = URL(fileURLWithPath: "/bin/chmod")
    acl.arguments = ["+a", "everyone deny delete", protected.path]
    try acl.run(); acl.waitUntilExit()

    MainActor.assumeIsolated {
        let session = VaultSession(ref: VaultRef(name: "guarded", location: vault.path))
        session.requestImport([app, locked, many, work, protected])
        let refused = Set(session.importReview?.refused.map(\.url.lastPathComponent) ?? [])
        expect(refused == ["Tool.app", "Private", "Dump", work.lastPathComponent],
               "apps, unreadable folders, folders of 1000+ files and folders holding the vault are refused")
        session.resolveImport(includeLarge: false)
        expect(session.exists("Protected/note.md") && !session.exists("Tool.app") && !session.exists("Private"),
               "an ordinary folder still comes in, the refused ones don't")
        let attributes = Process()
        attributes.executableURL = URL(fileURLWithPath: "/bin/ls")
        attributes.arguments = ["-led", session.url(for: "Protected").path]
        let pipe = Pipe()
        attributes.standardOutput = pipe
        try? attributes.run(); attributes.waitUntilExit()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        expect(!listing.contains("deny delete"), "imported copies don't keep the original's access rules")
        session.delete("Protected")
        expect(!session.exists("Protected"), "deleting works")

        // A copy made by an older Jet, with the rule still on it, can still be deleted.
        try? fm.createDirectory(at: session.url(for: "Downloads"), withIntermediateDirectories: true)
        let stuck = Process()
        stuck.executableURL = URL(fileURLWithPath: "/bin/chmod")
        stuck.arguments = ["+a", "everyone deny delete", session.url(for: "Downloads").path]
        try? stuck.run(); stuck.waitUntilExit()
        session.refreshTree()
        session.delete("Downloads")
        expect(!session.exists("Downloads"), "a folder that forbids deleting can still be deleted from Jet")
    }
    chmod(locked.path, 0o755)
    let cleanup = Process()
    cleanup.executableURL = URL(fileURLWithPath: "/bin/chmod")
    cleanup.arguments = ["-N", protected.path]
    try? cleanup.run(); cleanup.waitUntilExit()
} catch {
    failures += 1
    print("  FAIL  threw: \(error.localizedDescription)")
}

print("17. Sorting, manual order and Clean Up")
do {
    let vault = work.appendingPathComponent("order")
    try fm.createDirectory(at: vault.appendingPathComponent("Course"), withIntermediateDirectories: true)
    for (name, age) in [("b.md", 30.0), ("a.md", 10.0), ("c.ink", 20.0), ("Course/x.md", 5.0), ("Course/y.md", 1.0)] {
        let url = vault.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age * 60)], ofItemAtPath: url.path)
    }
    MainActor.assumeIsolated {
        let session = VaultSession(ref: VaultRef(name: "order", location: vault.path))
        func top() -> [String] { MainActor.assumeIsolated { session.tree.map(\.fileName) } }
        session.sortMode = .name
        expect(top() == ["Course", "a.md", "b.md", "c.ink"], "by name: folders first, then names")
        session.sortMode = .modified
        expect(top() == ["Course", "a.md", "c.ink", "b.md"], "by date: newest first")
        session.sortMode = .kind
        expect(top() == ["Course", "c.ink", "a.md", "b.md"], "by kind: grouped by type")

        session.sortMode = .name
        session.place("c.ink", before: "a.md")
        expect(session.sortMode == .manual && top() == ["Course", "c.ink", "a.md", "b.md"],
               "dragging between rows switches to manual order, starting from what was shown")
        session.place("Course", before: nil)
        expect(top() == ["c.ink", "a.md", "b.md", "Course"], "in manual order folders can go anywhere")
        session.nudge("b.md", by: -1)
        expect(top() == ["c.ink", "b.md", "a.md", "Course"], "Move Up swaps with the row above")
        session.nudge("c.ink", by: 1)
        expect(top() == ["b.md", "c.ink", "a.md", "Course"], "Move Down swaps with the row below")

        session.move("a.md", into: "Course", before: "Course/x.md")
        expect(session.children(of: "Course").map(\.fileName) == ["a.md", "x.md", "y.md"] && top() == ["b.md", "c.ink", "Course"],
               "moving into a folder between rows places it there and leaves the old folder's order intact")
        session.move("Course/y.md", into: "", before: "c.ink")
        expect(top() == ["b.md", "y.md", "c.ink", "Course"], "dragging out of a folder puts it at that spot on the top level")
        session.rename("b.md", to: "Bee")
        expect(top() == ["Bee.md", "y.md", "c.ink", "Course"], "renaming keeps an item's place")
        session.createNote(kind: .markdown, in: "", named: "New")
        expect(top().last == "New.md", "new notes go after the arranged ones")
        session.delete("y.md")
        expect(top() == ["Bee.md", "c.ink", "Course", "New.md"], "deleting removes it from the order")

        let reopened = VaultSession(ref: VaultRef(name: "order", location: vault.path))
        reopened.sortMode = .manual
        expect(reopened.tree.map(\.fileName) == top(), "manual order is saved in the vault and comes back")
        expect(!reopened.tree.contains { $0.fileName == ".jet" }, "the order file is hidden from the sidebar")

        session.cleanUp(by: .name)
        expect(session.sortMode == .manual && top() == ["Course", "Bee.md", "c.ink", "New.md"]
               && session.children(of: "Course").map(\.fileName) == ["a.md", "x.md"], "Clean Up By Name tidies every folder")
    }
} catch {
    failures += 1
    print("  FAIL  threw: \(error.localizedDescription)")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
