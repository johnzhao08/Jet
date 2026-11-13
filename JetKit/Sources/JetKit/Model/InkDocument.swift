import Foundation
import CoreGraphics
import PencilKit

public enum PaperStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case blank, lined, grid

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

/// On-disk format of a handwritten note (`*.ink`): single-line JSON wrapping a PencilKit drawing.
/// The page is a fixed 1024pt-wide column that grows downwards, so strokes line up on every device.
public struct InkDocument: Codable, Equatable, Sendable {
    public static let pageWidth: CGFloat = 1024
    public static let lineSpacing: CGFloat = 32

    public var version = 1
    public var paper: PaperStyle = .lined
    public var drawing = Data()

    public init(paper: PaperStyle = .lined, drawing: Data = Data()) {
        self.paper = paper
        self.drawing = drawing
    }

    public static func decode(_ data: Data) -> InkDocument? {
        if data.isEmpty { return InkDocument() }
        return try? JSONDecoder().decode(InkDocument.self, from: data)
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    public var pkDrawing: PKDrawing {
        (try? PKDrawing(data: drawing)) ?? PKDrawing()
    }
}

/// Three-way merge of two edits of the same handwritten note, stroke by stroke:
/// strokes added on either device are kept, strokes erased on either device stay erased.
public enum InkMerge {
    static func key(_ stroke: PKStroke) -> String {
        let path = stroke.path
        let created = Int((path.creationDate.timeIntervalSinceReferenceDate * 1000).rounded())
        var first = CGPoint.zero
        if path.count > 0 { first = path[0].location }
        let t = stroke.transform
        return "\(created)|\(path.count)|\(Int(first.x * 10))|\(Int(first.y * 10))|\(Int(t.tx * 10))|\(Int(t.ty * 10))"
    }

    public static func merge(base: Data?, ours: Data, theirs: Data) -> Data? {
        guard let ourDoc = InkDocument.decode(ours), let theirDoc = InkDocument.decode(theirs) else { return nil }
        let baseStrokes = base.flatMap(InkDocument.decode)?.pkDrawing.strokes ?? []
        let ourStrokes = ourDoc.pkDrawing.strokes
        let theirStrokes = theirDoc.pkDrawing.strokes

        let baseKeys = Set(baseStrokes.map(key))
        let ourKeys = Set(ourStrokes.map(key))
        let theirKeys = Set(theirStrokes.map(key))

        // Ours, minus what the other device erased; plus what the other device added.
        var merged = ourStrokes.filter { stroke in
            let k = key(stroke)
            return !(baseKeys.contains(k) && !theirKeys.contains(k))
        }
        merged += theirStrokes.filter { stroke in
            let k = key(stroke)
            return !ourKeys.contains(k) && !baseKeys.contains(k)
        }

        var result = ourDoc
        result.drawing = PKDrawing(strokes: merged).dataRepresentation()
        return result.encoded()
    }
}
