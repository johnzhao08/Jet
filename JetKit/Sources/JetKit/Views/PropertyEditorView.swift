import SwiftUI

struct PropertyEditorView: View {
    let session: VaultSession
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var key = ""
    @State private var kind = PropertyKind.text
    @State private var value = ""
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Properties") {
                    ForEach(NoteSyntax.frontmatter(in: source).properties, id: \.key) { property in
                        Button {
                            key = property.key
                            kind = EditableProperty.kind(raw: EditableProperty.rawValue(for: key, in: source))
                            value = property.values.joined(separator: kind == .list ? "\n" : ", ")
                        } label: {
                            LabeledContent(property.key, value: property.values.joined(separator: ", "))
                        }.buttonStyle(.plain)
                    }
                }
                Section {
                    TextField("Property name", text: $key)
                    Picker("Type", selection: $kind) {
                        ForEach(PropertyKind.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    switch kind {
                    case .checkbox:
                        Toggle("Checked", isOn: Binding(get: { value.lowercased() == "true" }, set: { value = String($0) }))
                    case .list:
                        TextField("One item per line", text: $value, axis: .vertical).lineLimit(2...8)
                    default:
                        TextField(kind == .date ? "YYYY-MM-DD" : "Value", text: $value)
                    }
                    Button("Save property", action: save).disabled(key.isEmpty || session.syncState == .syncing)
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }.formStyle(.grouped)
            .navigationTitle("Edit properties")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear {
            session.flushEditors()
            do { source = try String(contentsOf: session.root.vaultFile(path), encoding: .utf8) }
            catch { failure = error.localizedDescription }
        }.sheetSize(width: 480, height: 460)
    }

    private func save() {
        do {
            let file = try session.root.vaultFile(path)
            session.flushEditors()
            let latest = try String(contentsOf: file, encoding: .utf8)
            let updated = try EditableProperty.set(key: key, kind: kind, value: kind == .checkbox ? String(value.lowercased() == "true") : value, in: latest)
            try updated.write(to: file, atomically: true, encoding: .utf8)
            source = updated
            session.didWriteFile()
            session.contentVersion += 1
            failure = nil
        } catch { failure = error.localizedDescription }
    }
}
