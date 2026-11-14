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
    /// Pictures placed on the page, under the ink. Left out of the file when there are none, so notes
    /// without pictures stay byte-for-byte what they were.
    public var images: [InkImage]?

    public init(paper: PaperStyle = .lined, drawing: Data = Data(), images: [InkImage] = []) {
        self.paper = paper
        self.drawing = drawing
        self.images = images.isEmpty ? nil : images
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

    /// Everything on the page: ink and pictures.
    public var contentBounds: CGRect {
        (images ?? []).reduce(pkDrawing.bounds) { $0.union($1.frame) }
    }
}

/// A picture on a handwritten page: an image file in the vault, placed at a frame in page points.
public struct InkImage: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// Vault-relative path of the image file (usually in `Attachments/`).
    public var path: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(id: String = UUID().uuidString, path: String, frame: CGRect) {
        self.id = id
        self.path = path
        x = Double(frame.minX)
        y = Double(frame.minY)
        width = Double(frame.width)
        height = Double(frame.height)
    }

    public var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = Double(newValue.minX)
            y = Double(newValue.minY)
            width = Double(newValue.width)
            height = Double(newValue.height)
        }
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
        let images = mergeImages(base: base.flatMap(InkDocument.decode)?.images ?? [],
                                 ours: ourDoc.images ?? [], theirs: theirDoc.images ?? [])
        result.images = images.isEmpty ? nil : images
        return result.encoded()
    }

    /// Pictures merge like strokes, by id: added on either side kept, removed on either side gone.
    /// A picture moved on both devices keeps this device's position; moved on one, takes that one.
    static func mergeImages(base: [InkImage], ours: [InkImage], theirs: [InkImage]) -> [InkImage] {
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let theirByID = Dictionary(theirs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ourIDs = Set(ours.map(\.id))
        var merged: [InkImage] = ours.compactMap { image in
            guard let original = baseByID[image.id] else { return image }   // added here
            guard let their = theirByID[image.id] else { return nil }        // removed there
            return image == original ? their : image                         // changed there only
        }
        merged += theirs.filter { !ourIDs.contains($0.id) && baseByID[$0.id] == nil }
        return merged
    }
}
