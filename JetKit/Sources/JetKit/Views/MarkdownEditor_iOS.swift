#if os(iOS)
import SwiftUI
import UIKit

struct MarkdownPadEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var insertion: String?
    let action: MarkdownEditorAction?
    let fontSize: CGFloat
    let completion: (MarkdownCompletion?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.accessibilityIdentifier = "markdown-editor"
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.delegate = context.coordinator
        view.text = text
        context.coordinator.style(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        let resized = coordinator.parent.fontSize != fontSize
        coordinator.parent = self
        if view.text != text {
            let caret = min(view.selectedRange.location, text.utf16.count)
            view.text = text
            view.selectedRange = NSRange(location: caret, length: 0)
            coordinator.style(view)
        } else if resized { coordinator.style(view) }
        if let action, coordinator.lastAction != action.id {
            coordinator.lastAction = action.id
            DispatchQueue.main.async {
                if case .reveal(let range) = action.kind {
                    guard NSMaxRange(range) <= view.text.utf16.count else { return }
                    view.selectedRange = range
                    view.scrollRangeToVisible(range)
                } else if let (range, replacement, selection) = action.replacement(in: view.text, selection: view.selectedRange) {
                    view.selectedRange = range
                    view.insertText(replacement)
                    view.selectedRange = selection
                    view.becomeFirstResponder()
                }
            }
        }
        if let snippet = insertion {
            DispatchQueue.main.async {
                guard insertion == snippet else { return }
                insertion = nil
                let source = view.text as NSString
                let range = view.selectedRange
                let before = range.location == 0 || source.character(at: range.location - 1) == 10 ? "" : "\n"
                let after = NSMaxRange(range) >= source.length || source.character(at: NSMaxRange(range)) == 10 ? "" : "\n"
                view.insertText(before + snippet + after)
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownPadEditor
        var lastAction: UUID?
        init(_ parent: MarkdownPadEditor) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            guard view.markedTextRange == nil else { return }
            parent.text = view.text
            style(view)
            textViewDidChangeSelection(view)
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            let token = MarkdownCompletion.at(view.selectedRange, in: view.text)
            DispatchQueue.main.async { self.parent.completion(token) }
        }

        func style(_ view: UITextView) {
            let storage = view.textStorage
            let size = parent.fontSize
            let base: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size), .foregroundColor: UIColor.label]
            storage.beginEditing()
            storage.setAttributes(base, range: NSRange(location: 0, length: storage.length))
            if storage.length < 300_000 {
                for span in MarkdownStyling.spans(in: view.text) {
                    let attrs: [NSAttributedString.Key: Any]
                    switch span.role {
                    case .heading(let level): attrs = [.font: UIFont.boldSystemFont(ofSize: size * CGFloat(1.85 - 0.14 * Double(level)))]
                    case .bold: attrs = [.font: UIFont.boldSystemFont(ofSize: size)]
                    case .italic: attrs = [.font: UIFont.italicSystemFont(ofSize: size)]
                    case .code, .codeBlock, .frontmatter: attrs = [.font: UIFont.monospacedSystemFont(ofSize: size - 1, weight: .regular), .backgroundColor: UIColor.secondarySystemBackground]
                    case .strike, .taskDone: attrs = [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
                    case .link, .wikilink, .url, .tag, .embed, .listMarker: attrs = [.foregroundColor: view.tintColor ?? UIColor.link]
                    case .quote, .markup, .rule: attrs = [.foregroundColor: UIColor.secondaryLabel]
                    }
                    storage.addAttributes(attrs, range: span.range)
                }
            }
            storage.endEditing()
            view.typingAttributes = base
        }
    }
}
#endif
