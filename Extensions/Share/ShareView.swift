import SwiftUI
import JetCapture

struct ShareView: View {
    @ObservedObject var model: ShareModel
    let finish: () -> Void
    let cancel: () -> Void
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                if model.directory.vaults.count > 1 {
                    Section {
                        Picker("Vault", selection: $model.vaultID) {
                            ForEach(model.directory.vaults) { vault in Text(vault.name).tag(Optional(vault.id)) }
                        }
                    }
                }
                Section {
                    Picker("Save to", selection: $model.destination) {
                        Text("New note in Inbox").tag(CaptureItem.Destination.inbox)
                        Text("Today's note").tag(CaptureItem.Destination.dailyNote)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if model.destination == .inbox {
                    Section { TextField("Title", text: $model.title) }
                }
                if let link = model.link {
                    Section("Link") {
                        Label(link, systemImage: "link").lineLimit(2).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section("Note") {
                    TextEditor(text: $model.text).frame(minHeight: 120)
                }
                if !model.files.isEmpty {
                    Section("Files") {
                        ForEach(model.files) { file in
                            Label(file.name, systemImage: file.isImage ? "photo" : "doc").lineLimit(1)
                                .swipeActions { Button("Remove", role: .destructive) { model.remove(file) } }
                        }
                    }
                }
                if !model.skipped.isEmpty {
                    Section { Text("Not included: " + model.skipped.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary) }
                }
                if let message = model.errorMessage {
                    Section { Text(message).foregroundStyle(.red).font(.callout) }
                }
            }
            .overlay { if model.isLoading { ProgressView() } }
            .navigationTitle("Save to Jet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!model.canSave || saving)
                }
            }
        }
    }

    private func save() {
        saving = true
        do {
            try model.save()
            finish()
        } catch {
            model.errorMessage = error.localizedDescription
            saving = false
        }
    }
}
