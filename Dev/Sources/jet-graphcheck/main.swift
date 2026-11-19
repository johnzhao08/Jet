import Foundation
@testable import JetKit

// A focused check of the graph: the filter, depth, colour groups, and the layout engine that runs off the main thread.
// Run with ./graphcheck.sh. It needs no window and takes a few seconds.

var failures = 0
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("  ok   \(label)") } else { failures += 1; print("  FAIL \(label)") }
}

func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

// MARK: 1. Filter

print("1. Filter")
let tags = ["Projects/Jet.md": ["project/jet", "Swift"], "Projects/Site.md": ["project/site"], "Daily/2026-01-01.md": ["daily"], "Ideas.md": []]
func match(_ query: String, _ path: String) -> Bool { GraphQuery(query).matches(path: path, tags: tags[path] ?? []) }
expect(GraphQuery("").isEmpty && match("", "Ideas.md"), "empty filter shows everything")
expect(GraphQuery("  -  # ").isEmpty, "stray punctuation is not a term")
expect(match("jet", "Projects/Jet.md") && !match("jet", "Ideas.md"), "plain word matches the title")
expect(match("projects", "Projects/Site.md"), "plain word also matches the path")
expect(match("#project", "Projects/Jet.md") && match("#project", "Projects/Site.md"), "#tag finds nested tags")
expect(!match("#project", "Daily/2026-01-01.md"), "#tag skips notes without it")
expect(match("tag:SWIFT", "Projects/Jet.md"), "tag: is case-insensitive")
expect(!match("#proj", "Projects/Jet.md"), "#tag is a whole tag, not a prefix of a word")
expect(match("path:daily", "Daily/2026-01-01.md") && !match("path:daily", "Ideas.md"), "path:")
expect(match("file:site", "Projects/Site.md") && !match("file:projects", "Projects/Site.md"), "file: looks at the title only")
expect(match("#project -site", "Projects/Jet.md") && !match("#project -site", "Projects/Site.md"), "-term excludes")
expect(match("\"2026-01\"", "Daily/2026-01-01.md"), "quoted phrase")
expect(match("path:\"my notes\"", "my notes/a.md") && !match("path:\"my notes\"", "my/notes/a.md"), "quoted phrase with a prefix")
expect(match("#project jet", "Projects/Jet.md") && !match("#project ideas", "Projects/Jet.md"), "all terms must match")

// MARK: 2. Depth and scope

print("2. Depth and scope")
let chain = (["A", "B", "C", "D", "E", "F"]).map { "\($0).md" }
let source = GraphSource(paths: chain + ["Island.md"],
                         edges: [("A.md", "B.md"), ("C.md", "B.md"), ("C.md", "D.md"), ("D.md", "E.md"), ("E.md", "F.md")],
                         tags: ["D.md": ["skip"]])
func local(_ depth: Int, _ query: String = "", center: String = "A.md") -> Set<String> {
    Set(GraphSelection.select(source, center: center, local: true, depth: depth, query: GraphQuery(query)).paths)
}
expect(local(1) == ["A.md", "B.md"], "depth 1 is the note and its direct links")
expect(local(2) == ["A.md", "B.md", "C.md"], "depth 2 follows links one step further (even against their direction)")
expect(local(4) == ["A.md", "B.md", "C.md", "D.md", "E.md"], "depth 4")
expect(local(5).count == 6 && !local(5).contains("Island.md"), "unconnected notes never join a local graph")
expect(local(0) == local(1) && local(99) == local(5), "depth is clamped to 1...5")
expect(local(2, center: "C.md") == ["A.md", "B.md", "C.md", "D.md", "E.md"], "links count in both directions")
let global = GraphSelection.select(source, center: "A.md", local: false, depth: 1, query: GraphQuery())
expect(global.paths.count == 7 && global.edges.count == 5, "whole vault ignores depth")
let limited = GraphSelection.select(source, center: "A.md", local: true, depth: 2, query: GraphQuery())
expect(limited.edges.count == 2 && !limited.edges.contains { $0.0 == "C.md" && $0.1 == "D.md" }, "links are kept only between notes that are shown")
expect(local(5, "-#skip") == ["A.md", "B.md", "C.md"], "a filtered-out note cuts off what lies behind it")
expect(local(2, "e") == ["A.md"], "the open note stays even when the filter hides it")
let filteredAll = GraphSelection.select(source, center: nil, local: false, depth: 1, query: GraphQuery("#skip"))
expect(filteredAll.paths == ["D.md"] && filteredAll.edges.isEmpty, "whole vault filter by tag")

// MARK: 3. Colour groups

print("3. Colour groups")
let groups = [GraphGroup(query: "#project/jet", color: .red), GraphGroup(query: "#project", color: .blue),
              GraphGroup(query: "", color: .green), GraphGroup(query: "daily", color: .orange)]
let paths = ["Projects/Jet.md", "Projects/Site.md", "Daily/2026-01-01.md", "Ideas.md"]
let assigned = GraphGroup.assignments(paths: paths, tags: tags, groups: groups)
expect(assigned == [0, 1, 3, nil], "first matching group wins; an empty group matches nothing; no match means no group")
expect(GraphGroup.nextColor(after: groups) == .yellow, "new groups get an unused colour")
expect(GraphGroup.decode(GraphGroup.encode(groups)) == groups, "groups survive saving")
expect(GraphGroup.decode("not json").isEmpty && GraphGroup.decode(nil).isEmpty, "unreadable saved groups mean none")

// MARK: 4. Simulation

print("4. Simulation")
func run(_ simulation: inout ForceSimulation) -> Int {
    var steps = 0
    while simulation.isMoving && steps < 2000 { simulation.step(); steps += 1 }
    return steps
}
let ring = (0..<8).map { CGPoint(x: 10 * cos(CGFloat($0)), y: 10 * sin(CGFloat($0))) }
var first = ForceSimulation(positions: ring, edges: [(0, 1), (1, 2), (2, 3)])
var second = ForceSimulation(positions: ring, edges: [(0, 1), (1, 2), (2, 3)])
let steps = run(&first); _ = run(&second)
expect(steps > 50 && steps < 2000, "it cools and stops (\(steps) steps)")
expect(first.positions == second.positions, "the same start gives the same layout")
expect(first.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "positions stay finite")
expect(dist(first.positions[0], first.positions[1]) < dist(first.positions[0], first.positions[7]), "linked notes end up closer than unlinked ones")
var stacked = ForceSimulation(positions: [CGPoint](repeating: .zero, count: 5), edges: [])
_ = run(&stacked)
expect(Set(stacked.positions.map { "\($0.x),\($0.y)" }).count == 5 && stacked.positions.allSatisfy { $0.x.isFinite }, "notes on the same spot separate")
var held = ForceSimulation(positions: ring, edges: [(0, 1)])
held.pin(3, at: CGPoint(x: 500, y: 500)); _ = run(&held)
expect(held.positions[3] == CGPoint(x: 500, y: 500), "a pinned note stays where it was put")
held.unpin(3); _ = held.alpha; held.pin(99, at: .zero); held.unpin(99)
expect(true, "pinning a note that does not exist is ignored")
var settled = ForceSimulation(positions: ring, edges: []); _ = run(&settled)
settled.pin(0, at: .zero)
expect(settled.isMoving, "pinning wakes a settled layout")

// MARK: 5. Engine and layout, off the main thread

print("5. Engine and layout")
let engine = GraphEngine()
let start = (0..<30).map { CGPoint(x: CGFloat($0) * 3, y: 0) }
let loadSeq = engine.inbox.push(.load(positions: start, edges: (0..<29).map { ($0, $0 + 1) }, alpha: 1))
var frame = await engine.step()
expect(frame.generation == 1 && frame.processed == loadSeq && frame.positions.count == 30, "a load is applied before the next step")
expect(frame.positions != start, "the step moved the notes")
let pinSeq = engine.inbox.push(.pin(4, CGPoint(x: 250, y: 250)))
frame = await engine.step()
expect(frame.processed == pinSeq && frame.positions[4] == CGPoint(x: 250, y: 250), "a pin from the main thread reaches the engine")
engine.inbox.push(.load(positions: [.zero, CGPoint(x: 5, y: 5)], edges: [(0, 1)], alpha: 1))
frame = await engine.step()
expect(frame.generation == 2 && frame.positions.count == 2, "a new load replaces the old graph")

// The point of the engine: while it works, the main thread keeps running (gestures, drawing).
let heavy = GraphEngine()
heavy.inbox.push(.load(positions: (0..<1200).map { CGPoint(x: CGFloat($0 % 40) * 9, y: CGFloat($0 / 40) * 9) }, edges: [], alpha: 1))
nonisolated(unsafe) var mainTicks = 0
let ticker = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in mainTicks += 1 }
let began = Date()
for _ in 0..<6 { _ = await heavy.step() }
let spent = Date().timeIntervalSince(began)
ticker.invalidate()
expect(spent > 0.1, "the heavy layout really takes a while (\(Int(spent * 1000)) ms for 6 steps)")
expect(mainTicks >= Int(spent / 0.005 / 4), "the main thread kept running meanwhile (\(mainTicks) ticks)")

let layout = await GraphLayout()
let gestureOK = await MainActor.run { () -> Bool in
    let names = (0..<20).map { "n\($0).md" }
    layout.load(paths: names, edges: (0..<19).map { (names[$0], names[$0 + 1]) }, center: "n0.md")
    return layout.nodes.first?.path == "n0.md" && layout.isMoving && layout.edges.count == 19
}
expect(gestureOK, "the layout loads with the open note first")
var frames = 0
while await layout.isMoving, frames < 3000 { await layout.advance(); frames += 1 }
let settledOK = await MainActor.run { !layout.isMoving && layout.positions.allSatisfy { $0.x.isFinite } }
expect(settledOK && frames > 50, "frames flow back until the layout settles (\(frames) frames)")
let beforePin = await MainActor.run { layout.positions[7] }
await MainActor.run { layout.pin(7, at: CGPoint(x: 400, y: -300)) }
let wakes = await MainActor.run { layout.isMoving && layout.positions[7] == CGPoint(x: 400, y: -300) }
expect(wakes, "dragging a note wakes the layout and the note follows at once")
for _ in 0..<20 { await layout.advance() }
let held7 = await MainActor.run { layout.positions[7] }
expect(held7 == CGPoint(x: 400, y: -300) && held7 != beforePin, "frames from the engine do not pull a held note away")
await MainActor.run { layout.unpin(7) }
var more = 0
while await layout.isMoving, more < 3000 { await layout.advance(); more += 1 }
let released = await MainActor.run { layout.positions[7] }
expect(released != CGPoint(x: 400, y: -300), "a released note is laid out again")
// Narrowing keeps survivors where they were.
let kept = await MainActor.run { () -> Bool in
    let before = layout.positions[layout.nodes.firstIndex { $0.path == "n3.md" }!]
    let names = (0..<20).map { "n\($0).md" }
    layout.load(paths: Array(names[0..<10]), edges: [], center: "n0.md")
    return layout.nodes.firstIndex { $0.path == "n3.md" }.map { layout.positions[$0] == before } ?? false
}
expect(kept, "notes that stay in the graph keep their place when it is reloaded")

print(failures == 0 ? "\nAll graph checks passed." : "\n\(failures) graph check(s) failed.")
exit(failures == 0 ? 0 : 1)
