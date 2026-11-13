import AppKit
import JetKit

// Debug aid: JET_SNAPSHOT=/path/to.png writes a picture of the app's own window a few seconds
// after launch, then quits. Lets the UI be checked from a script without screen-recording access.
if let snapshotPath = ProcessInfo.processInfo.environment["JET_SNAPSHOT"] {
    let delay = Double(ProcessInfo.processInfo.environment["JET_SNAPSHOT_DELAY"] ?? "") ?? 4
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
           let frameView = window.contentView?.superview ?? window.contentView,
           let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapshotPath))
        }
        NSApp.terminate(nil)
    }
}

JetApp.main()
