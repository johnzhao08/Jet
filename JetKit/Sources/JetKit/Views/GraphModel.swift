import Foundation
import SwiftUI

// The graph's logic without any view: which notes to show (filter and depth), which colour group each
// belongs to, and the force simulation that lays them out. Everything here is plain values so it can be
// checked without a window, and the simulation can run on a background actor.

// MARK: Filter

/// What the graph's filter field means: space-separated terms that must all match.
///
///     plain       title or path contains the word
///     "a phrase"  the same, for text with spaces
///     #tag        has the tag, or one nested under it (`#project` also finds `#project/jet`)
///     tag:x       same as #x
///     path:x      the path contains x
///     file:x      the title contains x
///     -term       the note must not match term
struct GraphQuery: Equatable, Sendable {
    private struct Term: Equatable, Sendable {
        enum Kind: Sendable { case text, tag, path, file }
        var kind: Kind
        var value: String
        var negated: Bool
    }

    private var terms: [Term] = []

    init(_ text: String = "") {
        terms = Self.tokens(in: text).compactMap(Self.term(from:))
    }

    var isEmpty: Bool { terms.isEmpty }

    func matches(path: String, tags: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let lowerPath = path.lowercased()
        let title = GraphNaming.title(of: path).lowercased()
        let lowerTags = tags.map { $0.lowercased() }
        return terms.allSatisfy { term in
            let hit: Bool
            switch term.kind {
            case .text: hit = title.contains(term.value) || lowerPath.contains(term.value)
            case .path: hit = lowerPath.contains(term.value)
            case .file: hit = title.contains(term.value)
            case .tag: hit = lowerTags.contains { $0 == term.value || $0.hasPrefix(term.value + "/") }
            }
            return hit != term.negated
        }
    }

    /// Splits on whitespace, keeping `"quoted text"` (and `-"quoted"`, `path:"a b"`) together.
    private static func tokens(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func term(from token: String) -> Term? {
        var body = token
        guard body != "-" else { return nil }
        var negated = false
        if body.hasPrefix("-"), body.count > 1 { negated = true; body.removeFirst() }
        var kind = Term.Kind.text
        let lower = body.lowercased()
        for (prefix, prefixKind) in [("tag:", Term.Kind.tag), ("path:", .path), ("file:", .file)] where lower.hasPrefix(prefix) {
            kind = prefixKind
            body = String(body.dropFirst(prefix.count))
            break
        }
        if kind == .text, body.hasPrefix("#") {
            kind = .tag
            body = String(body.drop { $0 == "#" })
        }
        if kind == .tag { body = String(body.drop { $0 == "#" }) }
        body = body.lowercased()
        return body.isEmpty ? nil : Term(kind: kind, value: body, negated: negated)
    }
}

enum GraphNaming {
    static func title(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

// MARK: Colour groups

/// The colours a group can use. A fixed palette keeps saved groups readable in light and dark mode.
enum GraphColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, teal, blue, purple, pink, gray
    var id: Self { self }

    var name: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}

/// Notes matching `query` are drawn in `color`. The first matching group in the list wins.
struct GraphGroup: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var query: String
    var color: GraphColor

    /// A colour that no group is using yet, for the next one added.
    static func nextColor(after groups: [GraphGroup]) -> GraphColor {
        let used = Set(groups.map(\.color))
        return GraphColor.allCases.first { !used.contains($0) } ?? GraphColor.allCases[groups.count % GraphColor.allCases.count]
    }

    /// For each path, the index of the first group it belongs to. Groups with an empty query match nothing.
    static func assignments(paths: [String], tags: [String: [String]], groups: [GraphGroup]) -> [Int?] {
        let queries = groups.map { GraphQuery($0.query) }
        return paths.map { path in
            queries.firstIndex { !$0.isEmpty && $0.matches(path: path, tags: tags[path] ?? []) }
        }
    }

    static func encode(_ groups: [GraphGroup]) -> String {
        (try? JSONEncoder().encode(groups)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// Saved groups, or none if the text is missing or unreadable.
    static func decode(_ text: String?) -> [GraphGroup] {
        guard let data = text?.data(using: .utf8), let groups = try? JSONDecoder().decode([GraphGroup].self, from: data) else { return [] }
        return groups
    }
}

// MARK: Which notes

/// The vault as the graph sees it, copied so it can be filtered without touching the session.
struct GraphSource: Sendable {
    var paths: [String]
    var edges: [(String, String)]
    var tags: [String: [String]] = [:]
}

enum GraphSelection {
    static let depthRange = 1...5

    /// The notes and links to draw.
    ///
    /// The filter applies to the whole vault first. In a local graph, the open note (which always stays, so the
    /// graph has something to hang from) then pulls in everything within `depth` links of it, in either direction,
    /// walking only through notes that passed the filter.
    static func select(_ source: GraphSource, center: String?, local: Bool, depth: Int, query: GraphQuery)
        -> (paths: [String], edges: [(String, String)]) {
        var keep = Set(source.paths.filter { query.matches(path: $0, tags: source.tags[$0] ?? []) })
        if local, let center, source.paths.contains(center) { keep.insert(center) }
        var edges = source.edges.filter { keep.contains($0.0) && keep.contains($0.1) }

        if local, let center {
            var neighbors: [String: [String]] = [:]
            for (a, b) in edges { neighbors[a, default: []].append(b); neighbors[b, default: []].append(a) }
            var reached: Set<String> = keep.contains(center) ? [center] : []
            var frontier = Array(reached)
            for _ in 0..<min(max(depth, depthRange.lowerBound), depthRange.upperBound) {
                var next: [String] = []
                for path in frontier {
                    for other in neighbors[path] ?? [] where reached.insert(other).inserted { next.append(other) }
                }
                frontier = next
            }
            keep = reached
            edges = edges.filter { keep.contains($0.0) && keep.contains($0.1) }
        }
        return (source.paths.filter(keep.contains), edges)
    }
}

// MARK: Simulation

/// A force-directed layout: linked notes pull together, all notes push apart, and a weak pull keeps
/// unlinked notes from drifting off. It cools over a few seconds and then stops.
struct ForceSimulation: Sendable {
    var positions: [CGPoint] = []
    var velocities: [CGVector] = []
    var pinned: [Bool] = []
    var edges: [(Int, Int)] = []
    var alpha: CGFloat = 1

    var isMoving: Bool { alpha > 0.01 && !positions.isEmpty }

    init() {}

    init(positions: [CGPoint], edges: [(Int, Int)], alpha: CGFloat = 1) {
        self.positions = positions
        self.edges = edges
        self.alpha = alpha
        velocities = [CGVector](repeating: .zero, count: positions.count)
        pinned = [Bool](repeating: false, count: positions.count)
    }

    mutating func step() {
        let count = positions.count
        guard count > 0 else { return }
        var force = [CGVector](repeating: .zero, count: count)

        // Every pair repels (n² is fine for a personal vault of a few hundred notes, and this runs off the main thread).
        for i in 0..<count {
            for j in (i + 1)..<count {
                var dx = positions[i].x - positions[j].x
                var dy = positions[i].y - positions[j].y
                // Notes on the exact same spot need some direction to separate in; derive one from their indexes.
                if dx == 0 && dy == 0 { dx = CGFloat(i % 5) - 2 + 0.5; dy = CGFloat(j % 5) - 2 + 0.5 }
                let distanceSquared = max(dx * dx + dy * dy, 25)
                let push = 700 / distanceSquared
                force[i].dx += dx * push; force[i].dy += dy * push
                force[j].dx -= dx * push; force[j].dy -= dy * push
            }
        }
        // Links act as springs.
        for (a, b) in edges {
            let dx = positions[b].x - positions[a].x
            let dy = positions[b].y - positions[a].y
            let distance = max(hypot(dx, dy), 0.01)
            let pull = (distance - 60) * 0.05 / distance
            force[a].dx += dx * pull; force[a].dy += dy * pull
            force[b].dx -= dx * pull; force[b].dy -= dy * pull
        }
        for i in 0..<count where !pinned[i] {
            force[i].dx -= positions[i].x * 0.04
            force[i].dy -= positions[i].y * 0.04
            velocities[i].dx = (velocities[i].dx + force[i].dx * alpha) * 0.6
            velocities[i].dy = (velocities[i].dy + force[i].dy * alpha) * 0.6
            positions[i].x += velocities[i].dx
            positions[i].y += velocities[i].dy
        }
        alpha *= 0.985
    }

    mutating func pin(_ index: Int, at point: CGPoint) {
        guard positions.indices.contains(index) else { return }
        pinned[index] = true
        positions[index] = point
        velocities[index] = .zero
        alpha = max(alpha, 0.3)
    }

    mutating func unpin(_ index: Int) {
        guard pinned.indices.contains(index) else { return }
        pinned[index] = false
    }
}

/// Changes the view makes to the running simulation. They queue up and are applied in order before the next step.
enum GraphCommand: Sendable {
    case load(positions: [CGPoint], edges: [(Int, Int)], alpha: CGFloat)
    case pin(Int, CGPoint)
    case unpin(Int)
}

/// A thread-safe queue between the main thread and the engine. Pushing never waits for a simulation step,
/// so a drag gesture stays responsive however long the layout takes to compute.
final class GraphInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [(Int, GraphCommand)] = []
    private var sent = 0

    /// Queues a command and returns its sequence number.
    @discardableResult
    func push(_ command: GraphCommand) -> Int {
        lock.lock(); defer { lock.unlock() }
        sent += 1
        commands.append((sent, command))
        return sent
    }

    func drain() -> [(Int, GraphCommand)] {
        lock.lock(); defer { lock.unlock() }
        defer { commands.removeAll() }
        return commands
    }
}

/// One step's result: where every node is, and how far the view's commands have been applied.
struct GraphFrame: Sendable {
    var generation: Int
    var positions: [CGPoint]
    var alpha: CGFloat
    /// The last command from the inbox that this frame includes.
    var processed: Int
}

/// Owns the simulation and steps it away from the main thread. Only `step` touches the simulation, and an actor
/// runs one call at a time, so there is no shared mutable state to lock.
actor GraphEngine {
    nonisolated let inbox = GraphInbox()
    private var simulation = ForceSimulation()
    private var generation = 0
    private var processed = 0

    /// Applies queued commands, advances the layout one tick if it is still settling, and reports the result.
    func step() -> GraphFrame {
        for (sequence, command) in inbox.drain() {
            processed = sequence
            switch command {
            case let .load(positions, edges, alpha):
                generation += 1
                simulation = ForceSimulation(positions: positions, edges: edges, alpha: alpha)
            case let .pin(index, point): simulation.pin(index, at: point)
            case let .unpin(index): simulation.unpin(index)
            }
        }
        if simulation.isMoving { simulation.step() }
        return GraphFrame(generation: generation, positions: simulation.positions, alpha: simulation.alpha, processed: processed)
    }
}
