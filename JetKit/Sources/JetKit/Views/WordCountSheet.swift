#if os(macOS)
import SwiftUI

struct WordCountSheet: View {
    let count: MarkdownWordCount
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Word Count").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                row("Words", \.words)
                row("Characters", \.characters)
                row("Characters excluding spaces", \.charactersExcludingSpaces)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .fixedSize()
        .onExitCommand { dismiss() }
    }

    private func row(_ label: LocalizedStringKey, _ key: KeyPath<MarkdownWordCount.Counts, Int>) -> some View {
        GridRow {
            Text(label)
            Group {
                if let selection = count.selection {
                    Text("\(selection[keyPath: key]) of \(count.total[keyPath: key])")
                } else {
                    Text(count.total[keyPath: key], format: .number)
                }
            }
            .monospacedDigit()
            .gridColumnAlignment(.trailing)
        }
    }
}
#endif
