#if os(iOS)
import UIKit

/// What sits on the page under the ink: pictures (and a PDF's pages). It lives inside the canvas's
/// scroll view, in page points, scaled with the zoom, so it scrolls and zooms exactly with the ink.
final class PageContentView: UIView {
    private let root: URL
    private var imageViews: [String: UIImageView] = [:]
    private var loadedPaths: [String: String] = [:]

    init(root: URL) {
        self.root = root
        super.init(frame: .zero)
        layer.anchorPoint = .zero
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Sizes the layer to the page (in page points) and scales it to the canvas's zoom.
    func layout(pageSize: CGSize, zoom: CGFloat) {
        bounds = CGRect(origin: .zero, size: pageSize)
        layer.position = .zero
        transform = CGAffineTransform(scaleX: zoom, y: zoom)
    }

    func setImages(_ images: [InkImage]) {
        let ids = Set(images.map(\.id))
        for (id, view) in imageViews where !ids.contains(id) {
            view.removeFromSuperview()
            imageViews[id] = nil
            loadedPaths[id] = nil
        }
        for image in images {
            let view = imageViews[image.id] ?? makeImageView(for: image.id)
            view.frame = image.frame
            bringSubviewToFront(view)
            if loadedPaths[image.id] != image.path {
                loadedPaths[image.id] = image.path
                load(image.path, into: view)
            }
        }
    }

    func frame(ofImage id: String) -> CGRect? { imageViews[id]?.frame }

    /// Moves one picture without rebuilding the rest, for live dragging.
    func setFrame(_ frame: CGRect, ofImage id: String) {
        imageViews[id]?.frame = frame
    }

    private func makeImageView(for id: String) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.backgroundColor = .secondarySystemFill
        view.tintColor = .tertiaryLabel
        addSubview(view)
        imageViews[id] = view
        return view
    }

    private func load(_ path: String, into view: UIImageView) {
        let url = root.appendingPathComponent(path)
        DispatchQueue.global(qos: .userInitiated).async {
            let image = ImageFiles.cgImage(at: url, maxPixels: 2400)
            DispatchQueue.main.async {
                if let image {
                    view.image = UIImage(cgImage: image)
                    view.backgroundColor = .clear
                    view.contentMode = .scaleAspectFill
                } else {
                    // The file is gone (or not synced yet): a placeholder keeps the picture's place.
                    view.image = UIImage(systemName: "photo")
                    view.contentMode = .center
                    view.backgroundColor = .secondarySystemFill
                }
            }
        }
    }
}

/// The selected picture's outline, resize handle and Delete/Done buttons, over the canvas.
/// Only its own parts take touches; everywhere else falls through to the page.
final class ImageSelectionOverlay: UIView {
    let box = UIView()
    let handle = UIView()
    let toolbar = UIStackView()
    var onDelete: () -> Void = {}
    var onDone: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        box.layer.borderColor = UIColor.tintColor.cgColor
        box.layer.borderWidth = 2
        box.backgroundColor = UIColor.tintColor.withAlphaComponent(0.06)
        addSubview(box)

        handle.backgroundColor = .tintColor
        handle.layer.cornerRadius = 11
        handle.layer.borderColor = UIColor.white.cgColor
        handle.layer.borderWidth = 2
        addSubview(handle)

        toolbar.axis = .horizontal
        toolbar.spacing = 2
        toolbar.backgroundColor = .secondarySystemBackground
        toolbar.layer.cornerRadius = 10
        toolbar.layer.shadowColor = UIColor.black.cgColor
        toolbar.layer.shadowOpacity = 0.15
        toolbar.layer.shadowRadius = 6
        toolbar.layer.shadowOffset = CGSize(width: 0, height: 2)
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
        toolbar.addArrangedSubview(button("Delete", systemImage: "trash", color: .systemRed) { [weak self] in self?.onDelete() })
        toolbar.addArrangedSubview(button("Done", systemImage: "checkmark", color: .tintColor) { [weak self] in self?.onDone() })
        addSubview(toolbar)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func button(_ title: String, systemImage: String, color: UIColor, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemImage)
        configuration.title = title
        configuration.imagePadding = 5
        configuration.baseForegroundColor = color
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    }

    /// Places the outline at `rect` (view points).
    func show(_ rect: CGRect) {
        isHidden = false
        box.frame = rect
        handle.frame = CGRect(x: rect.maxX - 11, y: rect.maxY - 11, width: 22, height: 22)
        let size = toolbar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        var y = rect.minY - size.height - 10
        if y < safeAreaInsets.top + 4 { y = min(rect.maxY + 14, bounds.height - size.height - 8) }
        let x = min(max(rect.midX - size.width / 2, 8), bounds.width - size.width - 8)
        toolbar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    func hide() { isHidden = true }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden else { return nil }
        if handle.frame.insetBy(dx: -12, dy: -12).contains(point) { return handle }
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
#endif
