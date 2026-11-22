import CoreGraphics

/// Page zoom for a handwritten note or PDF: what the magnifier menu, pinching and the views share.
extension InkNoteModel {
    /// The zooms a page can be shown at, in view points per page point (1 is 100%).
    public static let zoomLimits: ClosedRange<CGFloat> = 0.25...5
    /// The stops Zoom In and Zoom Out move between.
    static let zoomSteps: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]

    /// The zoom to show the page at in a view whose page-fills-the-width zoom is `fit`.
    public func zoom(fitting fit: CGFloat) -> CGFloat {
        guard zoom > 0 else { return fit }
        return zoomFitsWidth ? min(zoom, fit) : zoom
    }

    /// The zoom the page is shown at right now.
    public var currentZoom: CGFloat { zoom(fitting: fitZoom) }

    /// Told by the view when it lays the page out at a new width. The first time, the page fits it.
    public func viewFits(_ fit: CGFloat) {
        guard fit > 0, abs(fit - fitZoom) > 0.0001 else { return }
        fitZoom = fit
        if zoom <= 0 { zoom = fit }
    }

    /// Shows the page at `value` (clamped to `zoomLimits`), from a pinch or the magnifier menu.
    public func setZoom(_ value: CGFloat) {
        let value = min(max(value, Self.zoomLimits.lowerBound), Self.zoomLimits.upperBound)
        zoomFitsWidth = fitZoom <= 0 || value <= fitZoom + 0.001
        if abs(value - zoom) > 0.0001 { zoom = value }
    }

    public var canZoomIn: Bool { currentZoom < Self.zoomLimits.upperBound - 0.001 }
    public var canZoomOut: Bool { currentZoom > Self.zoomLimits.lowerBound + 0.001 }

    public func zoomIn() {
        let current = currentZoom
        setZoom(Self.zoomSteps.first { $0 > current * 1.01 } ?? Self.zoomLimits.upperBound)
    }

    public func zoomOut() {
        let current = currentZoom
        setZoom(Self.zoomSteps.last { $0 < current / 1.01 } ?? Self.zoomLimits.lowerBound)
    }

    /// Fits the page's width to the view.
    public func zoomToFit() {
        guard fitZoom > 0 else { return }
        setZoom(fitZoom)
    }
}
