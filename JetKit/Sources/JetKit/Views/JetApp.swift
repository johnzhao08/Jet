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
                .jetCapture(model)
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandMenu("Navigate") {
                Button("Command palette…") { model.session?.showCommandPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(model.session == nil)
                Button("Back") { model.session?.navigate(back: true) }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(model.session?.backPaths.isEmpty != false)
                Button("Forward") { model.session?.navigate(back: false) }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(model.session?.forwardPaths.isEmpty != false)
            }
        }
        #endif
    }
}

#if os(macOS)
final class JetAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Screenshot runs stay in the background so they never take keyboard focus from the user.
        if ProcessInfo.processInfo.environment["JET_SNAPSHOT"] == nil {
            NSApp.activate(ignoringOtherApps: true)
        }
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
            // A sheet is its own window; capture it instead of the window it covers.
            let main = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil })
            if let window = main?.attachedSheet ?? main,
               let frameView = window.contentView?.superview ?? window.contentView,
               let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            exit(0)  // terminate(_:) waits on open sheets
        }
    }

    /// Files opened with Jet from Finder or dropped on its Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { OpenRequests.shared.deliver(urls) }
        if ProcessInfo.processInfo.environment["JET_SNAPSHOT"] == nil { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let session = app.session {
                VaultView(session: session)
                    .id(session.ref.id)
                    .task { app.importPending() }
            } else {
                WelcomeView()
            }
        }
        #if os(iOS)
        .onOpenURL { url in app.receive(url) }
        #else
        .onAppear { OpenRequests.shared.handler = { urls in app.receive(urls) } }
        #endif
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
