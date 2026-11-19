import SwiftUI
import JetCapture

/// Everything the app does for the share extension, widgets and Shortcuts, behind one modifier:
/// `RootView().jetCapture(app)`. On the Mac it does nothing.
///
/// - files waiting captures into the open vault (when the app opens, comes forward, or a vault opens)
/// - handles `jet://` links and actions left by intents (quick capture sheet, today's note, new note)
/// - tells the extensions which vaults exist and which notes are recent
extension View {
    @ViewBuilder
    public func jetCapture(_ app: AppModel) -> some View {
        #if os(iOS)
        modifier(CaptureSupport(app: app))
        #else
        self
        #endif
    }
}

extension AppModel {
    /// Files captures waiting in the shared inbox into the open vault, and refreshes what widgets show.
    @discardableResult
    public func fileCaptures() -> Int {
        guard let inbox = CaptureInbox.shared else { return 0 }
        let count = session?.fileCaptures(from: inbox) ?? 0
        publishCaptureState()
        return count
    }

    /// Tells the extensions the vault list and recent notes (titles only).
    public func publishCaptureState() {
        guard let inbox = CaptureInbox.shared else { return }
        VaultDirectory(vaults: vaults.map { .init(id: $0.id, name: $0.name) }, current: session?.ref.id).save(to: inbox)
        guard let session else {
            WidgetSnapshot().save(to: inbox)
            return
        }
        let recents = session.allNotes
            .filter { !$0.path.hasPrefix(VaultSession.attachmentsFolder + "/") }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            .prefix(6)
            .map { WidgetSnapshot.Note(path: $0.path, title: $0.title, isInk: $0.fileExtension == "ink") }
        WidgetSnapshot(vaultID: session.ref.id, vaultName: session.ref.name, recents: Array(recents)).save(to: inbox)
    }

    /// Runs an action from a widget, control or Shortcut. Returns true if it needs the capture sheet.
    func perform(_ action: JetAction) -> Bool {
        guard let session else { return false }
        switch action {
        case .capture: return true
        case .daily: session.openDailyNote()
        case .newNote: session.requestNewNote(kind: .markdown)
        case .newInk: session.requestNewNote(kind: .ink)
        }
        return false
    }

    /// Opens a note from a widget's link: only inside a vault Jet knows, and only if it exists.
    func openFromLink(vault: UUID?, path: String) {
        guard JetLink.isSafeVaultPath(path) else { return }
        if let vault, session?.ref.id != vault {
            guard let ref = vaults.first(where: { $0.id == vault }) else { return }
            open(ref)
        }
        guard let session, (try? session.root.vaultFile(path)) != nil, session.exists(path), !session.isDirectory(path) else { return }
        session.selection = path
    }
}

#if os(iOS)
private struct CaptureSupport: ViewModifier {
    let app: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var showCapture = false
    /// An action that arrived before a vault was open; runs once one is.
    @State private var waiting: JetAction?

    func body(content: Content) -> some View {
        content
            .task { activate() }
            .onChange(of: phase) { _, new in
                if new == .active { activate() } else if new == .background { app.publishCaptureState() }
            }
            .onChange(of: app.session?.ref.id) { activate() }
            .onReceive(NotificationCenter.default.publisher(for: PendingAction.didRequest)) { _ in activate() }
            .onOpenURL { url in
                guard let link = JetLink(url) else { return }  // other URLs are files; RootView handles them
                switch link {
                case .action(let action): run(action)
                case .open(let vault, let path): app.openFromLink(vault: vault, path: path)
                }
            }
            .sheet(isPresented: $showCapture) {
                if let session = app.session { QuickCaptureSheet(session: session) }
            }
    }

    private func activate() {
        if let action = PendingAction.take() { waiting = action }
        app.fileCaptures()
        if let action = waiting, app.session != nil {
            waiting = nil
            run(action)
        }
    }

    private func run(_ action: JetAction) {
        guard app.session != nil else { waiting = action; return }
        if app.perform(action) { showCapture = true }
    }
}

/// A sheet for jotting something down without choosing where it goes: a new note in `Inbox/`, or a
/// line in today's note.
struct QuickCaptureSheet: View {
    let session: VaultSession
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var destination = CaptureItem.Destination.inbox
    @State private var confirmDiscard = false
    @State private var failed = false
    @FocusState private var focused: Bool

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Save to", selection: $destination) {
                        Text("New note in Inbox").tag(CaptureItem.Destination.inbox)
                        Text("Today's note").tag(CaptureItem.Destination.dailyNote)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if destination == .inbox {
                    Section { TextField("Title (optional)", text: $title) }
                }
                Section {
                    TextEditor(text: $text)
                        .focused($focused)
                        .frame(minHeight: 220)
                }
            }
            .navigationTitle("Quick Capture")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if isEmpty { dismiss() } else { confirmDiscard = true } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(isEmpty)
                }
            }
            .confirmationDialog("Discard this note?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
            }
            .alert("Couldn't save", isPresented: $failed) { Button("OK") {} } message: {
                Text("Jet couldn't write to the vault. Your text is still here.")
            }
        }
        .interactiveDismissDisabled(!isEmpty)
        .onAppear { focused = true }
    }

    private func save() {
        let item = CaptureItem(destination: destination, title: title, text: text, origin: "Quick Capture")
        if session.apply(item) != nil { dismiss() } else { failed = true }
    }
}
#endif
