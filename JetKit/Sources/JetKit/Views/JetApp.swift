import SwiftUI

/// The whole app. The executable targets just call `JetApp.main()`.
public struct JetApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(JetAppDelegate.self) private var appDelegate
    #endif
    @State private var model = AppModel()

    public init() {}

    public var body: some Scene {
        WindowGroup("Jet") {
            RootView()
                .environment(model)
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        #endif
    }
}

#if os(macOS)
final class JetAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Self.snapshotIfRequested()
    }

    /// Debug aid: `JET_SNAPSHOT=/path/to.png` writes a picture of the app's own window a few seconds
    /// after launch (`JET_SNAPSHOT_DELAY`, default 4), then quits. Lets the UI be checked from a script
    /// without screen-recording access.
    private static func snapshotIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["JET_SNAPSHOT"] else { return }
        let delay = Double(environment["JET_SNAPSHOT_DELAY"] ?? "") ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
               let frameView = window.contentView?.superview ?? window.contentView,
               let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let session = app.session {
            VaultView(session: session)
                .id(session.ref.id)
        } else {
            WelcomeView()
        }
    }
}

extension View {
    /// Text fields for URLs, usernames and tokens: no autocorrect or capitalisation.
    func literalInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    func inlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
