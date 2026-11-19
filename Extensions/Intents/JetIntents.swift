import AppIntents
import JetCapture

// Intents for Shortcuts, Siri, the Action Button and Control Center. This file is compiled into both the
// app and the widget extension (a Control Center button needs the intent in its own process).
//
// None of them touch a vault: they leave a capture in the shared inbox, or ask the app to open, and
// the app does the writing.

enum CaptureDestinationOption: String, AppEnum {
    case inbox
    case dailyNote

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Save To")
    static let caseDisplayRepresentations: [CaptureDestinationOption: DisplayRepresentation] = [
        .inbox: "New Note in Inbox",
        .dailyNote: "Today's Note",
    ]

    var destination: CaptureItem.Destination { self == .dailyNote ? .dailyNote : .inbox }
}

/// "Add to Jet": text and/or files into the vault, without opening the app.
struct AddToJetIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Jet"
    static let description = IntentDescription("Saves text or files to your Jet vault as a new note in Inbox, or as an entry in today's note.")

    @Parameter(title: "Text", requestValueDialog: "What do you want to save?")
    var text: String?

    @Parameter(title: "Title")
    var title: String?

    @Parameter(title: "Files", supportedContentTypes: [.item])
    var files: [IntentFile]

    @Parameter(title: "Save To", default: .inbox)
    var destination: CaptureDestinationOption

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to Jet \(\.$destination)") {
            \.$title
            \.$files
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let inbox = CaptureInbox.shared else { throw CaptureInbox.Failure.unavailable }
        // Files come as a temporary file or as bytes; either way they're copied out here so the inbox can copy them in.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("JetIntent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Each file goes in its own folder so it keeps its readable name when the inbox copies it.
        var urls: [URL] = []
        for (index, file) in files.enumerated() {
            let folder = scratch.appendingPathComponent("\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(CaptureNaming.fileName(file.filename) ?? "File \(index + 1)")
            if let source = file.fileURL { try FileManager.default.copyItem(at: source, to: url) } else { try file.data.write(to: url) }
            urls.append(url)
        }

        let item = CaptureItem(destination: destination.destination, title: title ?? "", text: text ?? "", origin: "Shortcuts")
        try inbox.enqueue(item, files: urls)
        let place = destination == .dailyNote ? "today's note" : "Inbox"
        return .result(dialog: "Saved to \(place) in Jet.")
    }
}

// Opens Jet to a place: one intent each, so each is its own Shortcuts action and Control Center button.
// The app picks the request up (a file in the App Group, or a notification if it's already running).

struct QuickCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Capture"
    static let description = IntentDescription("Opens Jet's quick capture sheet.")
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult { PendingAction.request(.capture); return .result() }
}

struct OpenTodaysNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Today's Note"
    static let description = IntentDescription("Opens today's daily note in Jet.")
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult { PendingAction.request(.daily); return .result() }
}

struct NewHandwrittenNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Handwritten Note"
    static let description = IntentDescription("Starts a new handwritten note in Jet.")
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult { PendingAction.request(.newInk); return .result() }
}

struct NewTextNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Text Note"
    static let description = IntentDescription("Starts a new Markdown note in Jet.")
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult { PendingAction.request(.newNote); return .result() }
}
