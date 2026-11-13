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
        // Needed when launched as a bare executable (`swift run JetDev`) rather than an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
