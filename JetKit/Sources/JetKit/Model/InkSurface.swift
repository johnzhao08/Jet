import Foundation
import CoreGraphics
import PencilKit
#if os(macOS)
import AppKit
typealias InkPlatformColor = NSColor
#else
import UIKit
typealias InkPlatformColor = UIColor
#endif

// The pieces of writing with a mouse, a trackpad or a drawing tablet on the Mac. Everything here is
// plain PencilKit and Core Graphics, so the strokes it makes are the same `PKStroke`s the iPad writes
// and the same file format carries them. The view that feeds it events is `InkCanvas_macOS.swift`.

/// What the pointer does on the page when it is pressed and dragged.
public enum InkSurfaceTool: String, CaseIterable, Identifiable, Sendable {
    case pen, highlighter, eraser
    /// Add Text: click the page to type there, click typed text to edit it, drag it to move it.
    case text

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .text: "Add Text"
        }
    }

    public var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .text: "character.textbox"
        }
    }

    public var detail: String {
        switch self {
        case .pen: "Write with ink that follows pen pressure"
        case .highlighter: "See-through marker for highlighting"
        case .eraser: "Wipe across a stroke to remove it"
        case .text: "Click the page to type there; click typed text to edit it, or drag it to move it"
        }
    }

    /// Whether the tool puts ink on the page (so a colour and thickness apply).
    public var inks: Bool { self == .pen || self == .highlighter }
}

/// A named ink colour, kept as plain numbers so the choice means the same on every platform.
public enum InkSwatch: String, CaseIterable, Identifiable, Sendable {
    case black, blue, red, green, orange, purple, yellow, pink

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }

    public var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .black: (0, 0, 0)
        case .blue: (0, 0.478, 1)
        case .red: (1, 0.231, 0.188)
        case .green: (0.204, 0.78, 0.349)
        case .orange: (1, 0.584, 0)
        case .purple: (0.686, 0.322, 0.871)
        case .yellow: (1, 0.8, 0)
        case .pink: (1, 0.176, 0.333)
        }
    }

    /// The colours offered for a tool, the first being what it starts with.
    public static func choices(for tool: InkSurfaceTool) -> [InkSwatch] {
        switch tool {
        case .pen: [.black, .blue, .red, .green, .orange, .purple]
        case .highlighter: [.yellow, .green, .pink, .blue, .orange]
        case .eraser, .text: []
        }
    }

    var platformColor: InkPlatformColor {
        #if os(macOS)
        InkPlatformColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        #else
        InkPlatformColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        #endif
    }
}

public enum InkThickness: String, CaseIterable, Identifiable, Sendable {
    case thin, medium, thick

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }

    /// The stroke width in page points for a tool, within what PencilKit allows for its ink.
    public func width(for tool: InkSurfaceTool) -> CGFloat {
        let wanted: CGFloat
        switch (tool, self) {
        case (.highlighter, .thin): wanted = 12
        case (.highlighter, .medium): wanted = 20
        case (.highlighter, .thick): wanted = 30
        case (_, .thin): wanted = 2.5
        case (_, .medium): wanted = 4.5
        case (_, .thick): wanted = 8
        }
        let type: PKInkingTool.InkType = tool == .highlighter ? .marker : .pen
        return min(max(wanted, type.validWidthRange.lowerBound), type.validWidthRange.upperBound)
    }
}

/// One reading of the pointer while writing, in page points.
public struct InkSample: Equatable, Sendable {
    public var location: CGPoint
    /// When it was read (seconds on any steady clock; only differences matter).
    public var time: TimeInterval
    /// Pen pressure from 0 to 1, or nil when the device cannot tell (a mouse).
    public var force: CGFloat?
    public var azimuth: CGFloat
    public var altitude: CGFloat

    public init(location: CGPoint, time: TimeInterval, force: CGFloat? = nil,
                azimuth: CGFloat = 0, altitude: CGFloat = .pi / 2) {
        self.location = location
        self.time = time
        self.force = force
        self.azimuth = azimuth
        self.altitude = altitude
    }
}

/// Turns the readings of one press-drag-release into a PencilKit stroke.
public enum InkStrokeBuilder {
    /// Readings closer together than this (page points) add nothing but jitter.
    public static let minimumSpacing: CGFloat = 0.75

    /// How much wider or narrower than its nominal width a pen stroke is at a pressure: light pressure
    /// gives 0.4, no pressure information 1, full pressure 1.6.
    public static func widthFactor(force: CGFloat?) -> CGFloat {
        guard let force else { return 1 }
        return 0.4 + 1.2 * min(max(force, 0), 1)
    }

    /// The stroke for `samples`, or nil when there is nothing to draw (no readings, or the eraser).
    /// A single reading (a click) makes a dot.
    public static func stroke(from samples: [InkSample], tool: InkSurfaceTool, swatch: InkSwatch,
                              thickness: InkThickness, date: Date = Date()) -> PKStroke? {
        guard tool.inks, let first = samples.first, let last = samples.last else { return nil }

        var kept = [first]
        for sample in samples.dropFirst() {
            let previous = kept[kept.count - 1].location
            if hypot(sample.location.x - previous.x, sample.location.y - previous.y) >= minimumSpacing {
                kept.append(sample)
            }
        }
        // The stroke ends where the pointer was released, even when that was a hair from the last point.
        if kept.count > 1, kept[kept.count - 1].location != last.location {
            kept[kept.count - 1] = last
        } else if kept.count == 1 {
            var dot = last
            dot.location.x += 0.01
            dot.time = max(dot.time, first.time) + 0.01
            kept.append(dot)
        }

        let base = thickness.width(for: tool)
        let pressureSensitive = tool == .pen
        var smoothed: CGFloat?
        var offset: TimeInterval = 0
        let points: [PKStrokePoint] = kept.enumerated().map { index, sample in
            // Pressure is averaged with what came before so the width changes smoothly.
            if let force = sample.force {
                smoothed = smoothed.map { $0 * 0.6 + force * 0.4 } ?? force
            }
            let width = pressureSensitive ? base * widthFactor(force: sample.force == nil ? nil : smoothed) : base
            offset = index == 0 ? 0 : max(sample.time - first.time, offset + 0.001)
            return PKStrokePoint(location: sample.location, timeOffset: offset, size: CGSize(width: width, height: width),
                                 opacity: 1, force: smoothed ?? 1, azimuth: sample.azimuth, altitude: sample.altitude)
        }
        let ink = PKInk(tool == .highlighter ? .marker : .pen, color: swatch.platformColor)
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: date))
    }
}

/// Removes whole strokes the pointer touches, the way the iPad's stroke eraser does.
public enum InkEraser {
    /// The eraser's radius on screen, in view points.
    public static let screenRadius: CGFloat = 9

    /// `drawing` without the strokes touched by an eraser of `radius` dragged from `start` to `end`
    /// (page points), or nil when it touches nothing.
    public static func erasing(in drawing: PKDrawing, from start: CGPoint, to end: CGPoint, radius: CGFloat) -> PKDrawing? {
        let length = hypot(end.x - start.x, end.y - start.y)
        let steps = max(1, Int((length / max(radius / 2, 0.5)).rounded(.up)))
        let probes = (0...steps).map { index -> CGPoint in
            let t = CGFloat(index) / CGFloat(steps)
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
        var kept: [PKStroke] = []
        var removedAny = false
        for stroke in drawing.strokes {
            if touches(stroke, probes: probes, radius: radius) {
                removedAny = true
            } else {
                kept.append(stroke)
            }
        }
        return removedAny ? PKDrawing(strokes: kept) : nil
    }

    private static func touches(_ stroke: PKStroke, probes: [CGPoint], radius: CGFloat) -> Bool {
        let reach = stroke.renderBounds.insetBy(dx: -radius, dy: -radius)
        let near = probes.filter { reach.contains($0) }
        guard !near.isEmpty else { return false }
        for point in stroke.path.interpolatedPoints(by: .distance(2)) {
            let location = point.location.applying(stroke.transform)
            let limit = radius + max(point.size.width, point.size.height) / 2
            for probe in near where hypot(probe.x - location.x, probe.y - location.y) <= limit {
                return true
            }
        }
        return false
    }
}
