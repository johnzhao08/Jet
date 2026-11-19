import AppKit
import PDFKit
import SwiftUI
import WebKit
@testable import JetKit

@MainActor
func checkMarkdownReader() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = "Sample.md"
    let source = #"""
    ---
    tags: [test]
    ---
    # Intro

    [[#End|Last section]] and ==highlight== with an inline formula $x^2$.

    | A | B |
    |---|---|
    | 1 | 2 |

    > [!note] Remember
    > A callout.

    - [ ] Check this task

    %%Hidden comment%%
    A footnote[^1].

    [^1]: Footnote body.

    ![[Other#Inside]]

    ```swift
    let value = "colour"
    ```

    ```mermaid
    graph LR
      A --> B
    ```

    ## End

    <script>window.executed = true</script>
    """# + String(repeating: "\n\nAnother printed paragraph.", count: 80) + "\n\nLast printed line."
    try source.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    try "# Before\nwrong section\n## Inside\nEmbedded paragraph.\n## After\nwrong section"
        .write(to: root.appendingPathComponent("Other.md"), atomically: true, encoding: .utf8)
    let session = VaultSession(ref: VaultRef(name: "Markdown test", location: root.path))
    session.refreshTree()
    let model = MarkdownNoteModel(url: root.appendingPathComponent(path))
    let caret = NSRange(location: "🖊 [[Ot".utf16.count, length: 0)
    let token = MarkdownCompletion.at(caret, in: "🖊 [[Ot]]")!
    let completion = MarkdownEditorAction(kind: .complete(token, "Other"))
    precondition(completion.replacement(in: "🖊 [[Ot]]", selection: caret)?.0 == NSRange(location: 3, length: 6))
    precondition(MarkdownHeading.outline(source).map(\.title) == ["Intro", "End"])
    var output: Result<Data, Error>?
    let reader = MarkdownReader(session: session, model: model, path: path, text: source, version: 0,
                                fontSize: 15, jump: MarkdownHeadingJump(path: path, heading: "End"),
                                output: MarkdownOutputRequest(printDialog: false), follow: { _, _ in }) { output = $0 }
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 540, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: reader)
    window.contentView = host
    window.orderBack(nil)
    host.layoutSubtreeIfNeeded()
    func wait(_ message: String, until ready: () -> Bool) {
        let end = Date().addingTimeInterval(40)
        while !ready() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        precondition(ready(), message)
    }
    wait("Reader failed to export", until: { output != nil })
    let pdf = PDFDocument(data: try output!.get())!
    precondition(pdf.pageCount > 1 && pdf.string?.contains("Embedded paragraph.") == true)
    precondition(pdf.page(at: pdf.pageCount - 1)?.string?.contains("Last printed line.") == true, "PDF omitted the final paragraph")
    let web = host.firstDescendant(of: WKWebView.self)!
    var assertions: [String: Bool]?
    web.evaluateJavaScript("""
      (() => {
        const has = s => !!document.querySelector(s);
        const result = { table: has('table'), callout: has('.callout'), highlight: has('mark'), math: has('math'),
          mermaid: has('[data-render=mermaid] svg'), colour: has('code .hljs-keyword'), footnotes: has('.footnotes'),
          embedded: document.body.innerText.includes('Embedded paragraph.') && !document.body.innerText.includes('wrong section'),
          comments: !document.body.innerText.includes('Hidden comment'), heading: window.scrollY > 0,
          html: !window.executed && document.body.innerText.includes('<script>'), task: has('.task input') };
        document.querySelector('.task input')?.click();
        return result;
      })()
    """) { value, error in
        precondition(error == nil, String(describing: error))
        assertions = value as? [String: Bool]
    }
    wait("Reader DOM checks timed out", until: { assertions != nil })
    precondition(assertions!.values.allSatisfy { $0 }, "Reader checks: \(assertions!)")
    wait("Checkbox didn't update source", until: { model.text.contains("- [x] Check this task") })
    print("Markdown editor ranges, heading outline, rendered note, linked section, diagram, math, tasks and PDF passed.")
    window.orderOut(nil)
}
