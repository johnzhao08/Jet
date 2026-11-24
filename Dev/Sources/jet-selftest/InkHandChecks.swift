import Foundation
import AppKit
import PencilKit
@testable import JetKit

// Moving around a handwritten page on the Mac without writing on it: a drag with the right mouse button
// (whatever tool is chosen) or with the Hand tool. Real NSEvents go through a real NSWindow to a real
// NSScrollView holding the real InkSurfaceView, the way the app's page is built, so nothing depends on the
// screen, the pointer or another process (synthesized global right-button events don't reliably arrive).
// Uses `expect`, `failures` from main.swift.

private final class FlippedPage: NSView {
    override var isFlipped: Bool { true }
}

private enum MouseButton {
    case left, right

    var down: NSEvent.EventType { self == .left ? .leftMouseDown : .rightMouseDown }
    var dragged: NSEvent.EventType { self == .left ? .leftMouseDragged : .rightMouseDragged }
    var up: NSEvent.EventType { self == .left ? .leftMouseUp : .rightMouseUp }
}

@MainActor
private final class PanRig {
    let viewport: CGSize
    let window: NSWindow
    let scroll: NSScrollView
    let surface: InkSurfaceView
    let model: InkNoteModel
    private var clock: TimeInterval = 1000
    private var eventNumber = 0

    /// A page of `page` points shown through a `viewport` window, scrolled to `start`, with `tool` chosen.
    init(url: URL, page: CGSize, viewport: CGSize, start: CGPoint, tool: InkSurfaceTool) {
        _ = NSApplication.shared
        self.viewport = viewport
        model = InkNoteModel(url: url)
        model.surfaceTool = tool
        surface = InkSurfaceView(model: model)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: viewport), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scroll = NSScrollView(frame: NSRect(origin: .zero, size: viewport))
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        let document = FlippedPage(frame: NSRect(origin: .zero, size: page))
        surface.frame = document.bounds
        surface.autoresizingMask = [.width, .height]
        document.addSubview(surface)
        scroll.documentView = document
        window.contentView = scroll
        // Mouse events are only routed in a window the window server knows (and so numbers); keep it off screen.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        select(tool)
        scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: start)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    deinit { MainActor.assumeIsolated { window.close() } }

    /// Chooses `tool` as the toolbar does: in the model, which the page hands to the surface on its next update.
    func select(_ tool: InkSurfaceTool) {
        model.surfaceTool = tool
        surface.configure(scale: 1, origin: .zero, tool: tool, swatch: .black, thickness: .medium,
                          dark: false, generation: model.generation)
    }

    /// Where the page is scrolled to (the clip view's bounds origin).
    var offset: CGPoint { scroll.contentView.bounds.origin }

    /// The most the page can scroll to on each axis.
    var farthest: CGPoint {
        let page = scroll.documentView?.frame.size ?? .zero
        return CGPoint(x: max(0, page.width - viewport.width), y: max(0, page.height - viewport.height))
    }

    /// A point `x` right and `y` down from the window's top-left corner, in the window's own coordinates.
    func windowPoint(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: viewport.height - y) }

    func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        eventNumber += 1
        clock += 0.01
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: clock,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
                                             clickCount: 1, pressure: [.leftMouseUp, .rightMouseUp].contains(type) ? 0 : 1)
        else { fatalError("could not make a mouse event") }
        return event
    }

    /// Presses `button` at `from` (window coordinates), moves through `via` in order, and lets go at the last point.
    func drag(_ button: MouseButton, from: NSPoint, via points: [NSPoint]) {
        window.sendEvent(event(button.down, at: from))
        for point in points { window.sendEvent(event(button.dragged, at: point)) }
        window.sendEvent(event(button.up, at: points.last ?? from))
    }

    /// A straight drag by (`dx`, `dy`) screen points (`dy` positive is down), in `steps` moves.
    func drag(_ button: MouseButton, from: NSPoint, dx: CGFloat, dy: CGFloat, steps: Int = 8) {
        drag(button, from: from, via: (1...steps).map { step in
            let t = CGFloat(step) / CGFloat(steps)
            return NSPoint(x: from.x + dx * t, y: from.y - dy * t)
        })
    }

    /// Nothing was written or typed: the page is as it was.
    var untouched: Bool {
        model.drawing.strokes.isEmpty && model.texts.isEmpty && !surface.subviews.contains { $0 is NSTextView }
    }
}

func checkInkHand(work: URL) {
    print("12g. A right-button drag, or the Hand tool, moves the page around without writing")
    do {
        let url = work.appendingPathComponent("Hand.ink")
        try InkDocument().encoded().write(to: url)
        MainActor.assumeIsolated {
            let page = CGSize(width: 1000, height: 1200), viewport = CGSize(width: 400, height: 300)
            let centre = CGPoint(x: 200, y: 150)

            // Right button, with each tool chosen: both axes at once, the page held by the pointer.
            for tool in InkSurfaceTool.allCases {
                let rig = PanRig(url: url, page: page, viewport: viewport, start: CGPoint(x: 100, y: 100), tool: tool)
                let from = rig.windowPoint(centre.x, centre.y)
                let held = rig.surface.convert(from, from: nil)
                rig.drag(.right, from: from, dx: -60, dy: -80)
                expect(rig.offset == CGPoint(x: 160, y: 180),
                       "right drag left and up with \(tool.label) scrolls the page right and down, both axes (at \(rig.offset))")
                expect(rig.surface.convert(rig.windowPoint(centre.x - 60, centre.y - 80), from: nil) == held,
                       "…and the page point that was under the pointer is still under it (\(tool.label))")
                expect(rig.untouched && rig.surface.accessibilityValue() as? String == "0 strokes",
                       "…and nothing is written or typed (\(tool.label))")
                expect(rig.model.surfaceTool == tool, "…and the chosen tool is still \(tool.label) (it is \(rig.model.surfaceTool.label))")

                rig.drag(.right, from: from, dx: 90, dy: 50)
                expect(rig.offset == CGPoint(x: 70, y: 130), "the opposite drag brings the page back, both axes (\(tool.label), at \(rig.offset))")
                expect(rig.untouched && rig.model.surfaceTool == tool, "…and still nothing written, same tool (\(tool.label))")
            }

            // The page's edges stop it, on each axis separately, and coming back from past an edge is exact.
            do {
                let rig = PanRig(url: url, page: page, viewport: viewport, start: CGPoint(x: 100, y: 100), tool: .pen)
                let from = rig.windowPoint(centre.x, centre.y)
                rig.drag(.right, from: from, dx: -5000, dy: -5000)
                expect(rig.offset == rig.farthest, "dragging far past the bottom right stops at the page's corner (at \(rig.offset))")
                rig.drag(.right, from: from, dx: 5000, dy: 5000)
                expect(rig.offset == .zero, "dragging far past the top left stops at the page's corner (at \(rig.offset))")
                rig.drag(.right, from: from, dx: -5000, dy: 0)
                expect(rig.offset == CGPoint(x: rig.farthest.x, y: 0), "past the right edge only moves sideways (at \(rig.offset))")
                rig.drag(.right, from: from, dx: 0, dy: -5000)
                expect(rig.offset == rig.farthest, "past the bottom edge only moves down (at \(rig.offset))")
                expect(rig.untouched && rig.model.surfaceTool == .pen, "…with nothing written and the pen still chosen")

                // One drag that overshoots an edge and comes back is held by the pointer again, with no drift.
                let rest = PanRig(url: url, page: page, viewport: viewport, start: CGPoint(x: 100, y: 100), tool: .pen)
                rest.drag(.right, from: from, via: [rest.windowPoint(centre.x - 3000, centre.y - 3000),
                                                    rest.windowPoint(centre.x - 60, centre.y - 80)])
                expect(rest.offset == CGPoint(x: 160, y: 180), "overshooting an edge then coming back lands where the pointer is (at \(rest.offset))")
            }

            // A page narrower than the window only moves the way it is longer.
            do {
                let rig = PanRig(url: url, page: CGSize(width: 300, height: 1200), viewport: viewport,
                                 start: CGPoint(x: 0, y: 100), tool: .pen)
                let side = rig.offset.x
                rig.drag(.right, from: rig.windowPoint(200, 150), dx: -80, dy: -120)
                expect(rig.offset.x == side && rig.offset.y == 220, "a page that fits sideways only scrolls down (at \(rig.offset), was x \(side))")
                expect(rig.untouched, "…and nothing is written")
            }

            // Too small a movement is a click, not a pan.
            do {
                let rig = PanRig(url: url, page: page, viewport: viewport, start: CGPoint(x: 100, y: 100), tool: .pen)
                let from = rig.windowPoint(centre.x, centre.y)
                rig.drag(.right, from: from, dx: 0, dy: 0, steps: 1)
                rig.drag(.right, from: from, dx: 2, dy: 1, steps: 2)
                expect(rig.offset == CGPoint(x: 100, y: 100), "a right-click in place, or a 2-point wobble, moves nothing (at \(rig.offset))")
                expect(rig.untouched && rig.model.surfaceTool == .pen, "…and writes nothing")
            }

            // The Hand tool does the same with the ordinary button, and is itself the tool afterwards.
            do {
                let rig = PanRig(url: url, page: page, viewport: viewport, start: CGPoint(x: 100, y: 100), tool: .hand)
                let from = rig.windowPoint(centre.x, centre.y)
                let held = rig.surface.convert(from, from: nil)
                rig.drag(.left, from: from, dx: -60, dy: -80)
                expect(rig.offset == CGPoint(x: 160, y: 180), "a Hand drag moves the page on both axes (at \(rig.offset))")
                expect(rig.surface.convert(rig.windowPoint(centre.x - 60, centre.y - 80), from: nil) == held,
                       "…holding the page point that was under the pointer")
                expect(rig.untouched && rig.surface.accessibilityValue() as? String == "0 strokes", "…and writes nothing")
                rig.drag(.left, from: from, dx: -5000, dy: -5000)
                expect(rig.offset == rig.farthest, "…stopping at the page's edge (at \(rig.offset))")
                expect(rig.model.surfaceTool == .hand, "…and the Hand is still the tool")
            }

            // Typed text moves with the page, and right-clicking it still offers its menu after panning.
            do {
                let rig = PanRig(url: url, page: page, viewport: viewport, start: CGPoint(x: 0, y: 0), tool: .pen)
                rig.model.addText("Typed on the page", at: CGPoint(x: 120, y: 200), id: "typed")
                let text = rig.model.texts.first?.frame ?? .zero
                let inside = CGPoint(x: text.minX + 20, y: text.minY + 8)
                @MainActor func menuTitles() -> [String] {
                    let at = rig.surface.convert(inside, to: nil)
                    return rig.surface.menu(for: rig.event(.rightMouseDown, at: at))?.items.map(\.title) ?? []
                }
                expect(menuTitles() == ["Edit Text", "Delete Text"], "a right-click on typed text offers its menu (\(menuTitles()))")
                rig.drag(.right, from: rig.windowPoint(300, 250), dx: -70, dy: -90)
                expect(rig.offset == CGPoint(x: 70, y: 90), "text page panned (at \(rig.offset))")
                expect(menuTitles() == ["Edit Text", "Delete Text"], "…and the text's menu is still where the text now is (\(menuTitles()))")
                expect(rig.model.texts.count == 1 && rig.model.texts.first?.text == "Typed on the page" && rig.model.drawing.strokes.isEmpty,
                       "…and the text and page are untouched")
            }
        }
    } catch {
        failures += 1
        print("  FAIL  threw: \(error.localizedDescription)")
    }
}
