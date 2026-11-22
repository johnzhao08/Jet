import SwiftUI

/// The magnifying glass in a handwritten note's or PDF's toolbar: zoom in and out, fit the page's width,
/// or pick a zoom. Shows the zoom it is at. ⌘+, ⌘− and ⌘0 work from the keyboard (on iPad too).
struct InkZoomMenu: View {
    let model: InkNoteModel

    private static let presets: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    private var percent: String { "\(Int((model.currentZoom * 100).rounded()))%" }

    var body: some View {
        Menu {
            Button { model.zoomIn() } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!model.canZoomIn)
            Button { model.zoomOut() } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!model.canZoomOut)
            Button { model.zoomToFit() } label: { Label("Fit Page Width", systemImage: "arrow.left.and.right") }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            ForEach(Self.presets, id: \.self) { zoom in
                Button {
                    model.setZoom(zoom)
                } label: {
                    if abs(model.currentZoom - zoom) < 0.005 {
                        Label("\(Int(zoom * 100))%", systemImage: "checkmark")
                    } else {
                        Text("\(Int(zoom * 100))%")
                    }
                }
            }
        } label: {
            Label("Zoom (\(percent))", systemImage: "magnifyingglass")
        }
        .help("Zoom: \(percent)")
        .accessibilityIdentifier("ink-zoom")
    }
}
