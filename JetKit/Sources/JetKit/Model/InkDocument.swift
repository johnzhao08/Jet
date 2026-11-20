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
    /// Typed text on the page, over the pictures and under the ink. Left out of the file when there is
    /// none, like `images`, so notes without typed text keep their exact format.
    public var texts: [InkText]?

    public init(paper: PaperStyle = .lined, drawing: Data = Data(), images: [InkImage] = [], texts: [InkText] = []) {
        self.paper = paper
        self.drawing = drawing
        self.images = images.isEmpty ? nil : images
        self.texts = texts.isEmpty ? nil : texts
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

    /// Everything on the page: ink, pictures and typed text.
    public var contentBounds: CGRect {
        let withImages = (images ?? []).reduce(pkDrawing.bounds) { $0.union($1.frame) }
        return (texts ?? []).reduce(withImages) { $0.union($1.frame) }
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
        let texts = mergeTexts(base: base.flatMap(InkDocument.decode)?.texts ?? [],
                               ours: ourDoc.texts ?? [], theirs: theirDoc.texts ?? [])
        result.texts = texts.isEmpty ? nil : texts
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

    /// Typed text merges by id, never losing what someone wrote:
    /// - added on either device: kept;
    /// - removed on one device: removed, unless its wording was changed on the other, then that edit stays;
    /// - changed on one device: takes that change;
    /// - changed on both: wording and placement merge separately, this device winning where both changed
    ///   the same thing. If both reworded it differently, the other wording is kept too, as a copy just
    ///   below (id `<id>-conflict`, or `<id>-conflict-2`… when earlier copies exist), so neither is lost.
    static func mergeTexts(base: [InkText], ours: [InkText], theirs: [InkText]) -> [InkText] {
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let theirByID = Dictionary(theirs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ourIDs = Set(ours.map(\.id))
        // Every id either side has, so a new conflict copy never replaces an earlier one.
        var taken = Set(base.map(\.id)).union(ourIDs).union(theirByID.keys)
        var merged: [InkText] = []
        for text in ours {
            guard let original = baseByID[text.id] else {                       // added here
                merged.append(text)
                continue
            }
            guard let their = theirByID[text.id] else {                         // removed there
                if text.text != original.text { merged.append(text) }
                continue
            }
            var result = text
            if text.text == original.text { result.text = their.text }
            if text.x == original.x, text.y == original.y, text.width == original.width {
                result.x = their.x
                result.y = their.y
                result.width = their.width
            }
            merged.append(result)
            if text.text != original.text, their.text != original.text, their.text != text.text {
                var copy = their
                copy.id = conflictID(for: text.id, taken: taken)
                taken.insert(copy.id)
                copy.y = Double(result.frame.maxY + InkText.lineHeight)
                merged.append(copy)
            }
        }
        for their in theirs where !ourIDs.contains(their.id) {
            if let original = baseByID[their.id] {                              // removed here
                if their.text != original.text { merged.append(their) }        // ...but reworded there
            } else {
                merged.append(their)                                            // added there
            }
        }
        var seen = Set<String>()
        return merged.filter { seen.insert($0.id).inserted }
    }

    /// The id for a conflict copy of `id`: `<id>-conflict`, or `<id>-conflict-2`, `-3`… when that is
    /// taken. It depends only on the ids involved, so both devices merging the same edits agree.
    static func conflictID(for id: String, taken: Set<String>) -> String {
        let first = id + "-conflict"
        guard taken.contains(first) else { return first }
        var number = 2
        while taken.contains("\(first)-\(number)") { number += 1 }
        return "\(first)-\(number)"
    }
}
