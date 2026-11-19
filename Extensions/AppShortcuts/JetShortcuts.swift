import AppIntents

/// The Shortcuts and Siri phrases Jet offers without any setup. App target only.
struct JetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: QuickCaptureIntent(), phrases: [
            "Quick capture in \(.applicationName)",
            "Capture a note in \(.applicationName)",
        ], shortTitle: "Quick Capture", systemImageName: "square.and.pencil")
        AppShortcut(intent: AddToJetIntent(), phrases: [
            "Add to \(.applicationName)",
            "Save to \(.applicationName)",
        ], shortTitle: "Add to Jet", systemImageName: "tray.and.arrow.down")
        AppShortcut(intent: OpenTodaysNoteIntent(), phrases: [
            "Open today's note in \(.applicationName)",
        ], shortTitle: "Today's Note", systemImageName: "calendar")
        AppShortcut(intent: NewHandwrittenNoteIntent(), phrases: [
            "New handwritten note in \(.applicationName)",
        ], shortTitle: "Handwritten Note", systemImageName: "applepencil.tip")
    }
}
