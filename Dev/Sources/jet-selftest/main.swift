import Foundation
import PencilKit
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

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
