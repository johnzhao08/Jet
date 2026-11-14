#if os(iOS)
import SwiftUI

/// Choose which pens sit in the tool picker, and in what order.
struct InkToolsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(InkPickerTool.storageKey) private var stored = InkPickerTool.encode(InkPickerTool.defaults)

    private var tools: [InkPickerTool] { InkPickerTool.decode(stored) }
    private var available: [InkPickerTool] { InkPickerTool.allCases.filter { !tools.contains($0) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(tools) { tool in
                        row(tool)
                            .deleteDisabled(!canRemove(tool))
                    }
                    .onMove { from, to in
                        var list = tools
                        list.move(fromOffsets: from, toOffset: to)
                        stored = InkPickerTool.encode(list)
                    }
                    .onDelete { offsets in
                        var list = tools
                        list.remove(atOffsets: offsets)
                        if list.contains(where: \.inks) { stored = InkPickerTool.encode(list) }
                    }
                } header: {
                    Text("In the tool picker")
                } footer: {
                    Text("Drag to reorder. The lasso and Insert Space are always there. The picker remembers each pen's colour and width.")
                }

                if !available.isEmpty {
                    Section("More tools") {
                        ForEach(available) { tool in
                            Button {
                                stored = InkPickerTool.encode(tools + [tool])
                            } label: {
                                HStack {
                                    row(tool)
                                    Spacer()
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    Button("Restore defaults") { stored = InkPickerTool.encode(InkPickerTool.defaults) }
                        .disabled(tools == InkPickerTool.defaults)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Pens & Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The last pen can't go: the picker always needs something to write with.
    private func canRemove(_ tool: InkPickerTool) -> Bool {
        !tool.inks || tools.filter(\.inks).count > 1
    }

    private func row(_ tool: InkPickerTool) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.label)
                Text(tool.detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: tool.symbol).foregroundStyle(Color.accentColor)
        }
    }
}
#endif
