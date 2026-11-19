import SwiftUI

enum VaultCommand: String, CaseIterable, Identifiable {
    case quickOpen = "Quick open"
    case back = "Go back"
    case forward = "Go forward"
    case markdown = "New text note"
    case ink = "New handwritten note"
    case template = "New note from template"
    case daily = "Open today's note"
    case weekly = "Open this week's note"
    case monthly = "Open this month's note"
    case graph = "Open graph"
    case brokenLinks = "Check broken links"
    case library = "Open vault library"
    case sync = "Sync settings"

    var id: Self { self }
}

struct VaultCommandPalette: View {
    let session: VaultSession
    let run: (VaultCommand) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private var matches: [VaultCommand] {
        VaultCommand.allCases.filter {
            ($0 != .back || !session.backPaths.isEmpty) && ($0 != .forward || !session.forwardPaths.isEmpty)
                && (query.isEmpty || QuickOpenView.score(query, in: $0.rawValue) > 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            TextField("Find a command…", text: $query)
                .font(.title3).textFieldStyle(.plain).padding()
                .accessibilityIdentifier("command-search")
                .focused($focused).onSubmit { if let first = matches.first { run(first) } }
            Divider()
            List(matches) { command in
                Button(command.rawValue) { run(command) }
            }
            .listStyle(.plain)
        }
        .sheetSize(width: 440, height: 420)
        .onAppear { focused = true }
    }
}

struct TemplatePicker: View {
    let session: VaultSession
    @Environment(\.dismiss) private var dismiss
    @State private var template: String?
    @State private var name = ""
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                TextField("New note name", text: $name)
                    .textFieldStyle(.roundedBorder).padding(.horizontal)
                List(selection: $template) {
                    ForEach(session.allNotes.filter {
                        $0.fileExtension != "ink" && (filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter))
                    }) { note in
                        Button {
                            template = note.path
                        } label: {
                            HStack {
                                Text(note.path)
                                Spacer()
                                if note.path == template { Image(systemName: "checkmark") }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tag(note.path)
                    }
                }
                .searchable(text: $filter, prompt: "Find a Markdown template")
            }
            .navigationTitle("New note from template")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        if let template, session.createFromTemplate(template, named: name) { dismiss() }
                    }
                    .disabled(template == nil)
                }
            }
        }
        .sheetSize(width: 520, height: 440)
    }
}

struct BrokenLinksView: View {
    let session: VaultSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let missing = session.index.brokenLinks
            Group {
                if session.indexVersion == 0 {
                    ProgressView("Checking links…")
                } else if missing.isEmpty {
                    ContentUnavailableView("No broken links", systemImage: "checkmark.circle")
                } else {
                    List(missing.keys.sorted(), id: \.self) { path in
                        Button {
                            session.selection = path
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(path)
                                Text((missing[path] ?? []).joined(separator: ", "))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Broken links")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheetSize(width: 520, height: 420)
    }
}
