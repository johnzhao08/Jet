import SwiftUI
import WebKit
import PDFKit
import UniformTypeIdentifiers

struct MarkdownOutputRequest: Equatable {
    let id = UUID()
    let printDialog: Bool
}

struct MarkdownPDFDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    let data: Data
    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

#if os(macOS)
typealias ReaderRepresentable = NSViewRepresentable
#else
typealias ReaderRepresentable = UIViewRepresentable
#endif

struct MarkdownReader: ReaderRepresentable {
    let session: VaultSession
    let model: MarkdownNoteModel
    let path: String
    let text: String
    let version: Int
    let fontSize: CGFloat
    let jump: MarkdownHeadingJump?
    let output: MarkdownOutputRequest?

    #if os(macOS)
    var wordCountID: UUID? = nil
    var showWordCount: ((MarkdownWordCount) -> Void)? = nil

    func wordCountRequest(_ id: UUID?, show: @escaping (MarkdownWordCount) -> Void) -> Self {
        var reader = self
        reader.wordCountID = id
        reader.showWordCount = show
        return reader
    }
    #endif

    var follow: (String, String) -> Void
    var export: (Result<Data, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: "note")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = coordinator
        let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "MarkdownReader")!
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return web
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ web: WKWebView, context: Context) { context.coordinator.update(self, web) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ web: WKWebView, context: Context) { context.coordinator.update(self, web) }
    #endif

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
        private var parent: MarkdownReader
        private var loaded = false
        private var rendering = false
        private var generation = 0
        private var jumpID: UUID?
        private var outputID: UUID?
        #if os(macOS)
        private var wordCountID: UUID?
        #endif
        init(_ parent: MarkdownReader) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let allowed = navigationAction.request.url == Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "MarkdownReader")
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            render(webView)
        }

        func update(_ next: MarkdownReader, _ web: WKWebView) {
            let changed = next.text != parent.text || next.fontSize != parent.fontSize || next.version != parent.version || next.path != parent.path
            parent = next
            guard loaded else { return }
            if changed { render(web) } else if !rendering { deliverActions(web) }
        }

        private func render(_ web: WKWebView) {
            generation += 1
            let current = generation
            rendering = true
            let args: [String: Any] = ["note": Self.payload(parent.text, path: parent.path), "size": parent.fontSize]
            web.callAsyncJavaScript("await renderNote(note, size)", arguments: args, in: nil, in: .page) { [weak self] result in
                guard let self, current == self.generation else { return }
                self.rendering = false
                if case .failure(let error) = result { self.parent.export(.failure(error)); return }
                self.deliverActions(web)
            }
        }

        private static func payload(_ text: String, path: String) -> [String: Any] {
            let front = NoteSyntax.frontmatter(in: text)
            let body = front.lineCount == 0 ? text : text.components(separatedBy: "\n").dropFirst(front.lineCount).joined(separator: "\n")
            let properties = front.properties.map { ["key": $0.key, "values": $0.values] as [String: Any] }
            return ["path": path, "body": body, "offset": front.lineCount, "properties": properties]
        }

        private func deliverActions(_ web: WKWebView) {
            if let jump = parent.jump, jump.path == parent.path, jump.id != jumpID {
                jumpID = jump.id
                web.callAsyncJavaScript("jumpToHeading(title)", arguments: ["title": jump.heading], in: nil, in: .page)
            }
            #if os(macOS)
            if let id = parent.wordCountID, id != wordCountID {
                wordCountID = id
                readWordCount(web, id: id)
            }
            #endif
            guard let request = parent.output, request.id != outputID else { return }
            outputID = request.id
            DispatchQueue.main.async { self.output(web, printDialog: request.printDialog) }
        }

        #if os(macOS)
        private func readWordCount(_ web: WKWebView, id: UUID) {
            web.evaluateJavaScript("""
                (() => {
                    const main = document.querySelector('main');
                    const body = document.createRange();
                    body.selectNodeContents(main);
                    const properties = main.querySelector(':scope > .properties');
                    if (properties) body.setStartAfter(properties);
                    const total = main.innerText;
                    const metadata = properties?.innerText;
                    const text = metadata && total.startsWith(metadata)
                        ? total.slice(metadata.length).replace(/^\\n+/, '') : total;
                    const selection = window.getSelection();
                    if (!selection.rangeCount || selection.isCollapsed) return [text];
                    const range = selection.getRangeAt(0).cloneRange();
                    const start = body.comparePoint(range.startContainer, range.startOffset);
                    const end = body.comparePoint(range.endContainer, range.endOffset);
                    if (end < 0 || start > 0) return [text, ''];
                    if (start >= 0 && end <= 0) return [text, selection.toString()];
                    if (start < 0) range.setStart(body.startContainer, body.startOffset);
                    if (end > 0) range.setEnd(body.endContainer, body.endOffset);
                    return [text, range.toString()];
                })()
                """) { [weak self] result, _ in
                guard let self, self.parent.wordCountID == id else { return }
                let text = result as? [String] ?? []
                let count = text.first.map { MarkdownWordCount(total: $0, selection: text.dropFirst().first) }
                self.parent.showWordCount?(count ?? MarkdownWordCount(source: self.parent.text))
            }
        }
        #endif

        private func output(_ web: WKWebView, printDialog: Bool) {
            #if os(macOS)
            Task {
                do {
                    let size = try await web.evaluateJavaScript("""
                        [document.documentElement.clientWidth, document.documentElement.scrollHeight]
                        """) as? [Double]
                    guard let size, size.count == 2, size[0] > 0, size[1] > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    let info = NSPrintInfo.shared.copy() as! NSPrintInfo
                    let paper = info.paperSize
                    let height = size[0] * max(1, paper.height) / max(1, paper.width)
                    let document = PDFDocument()
                    for top in stride(from: 0.0, to: size[1], by: height) {
                        let config = WKPDFConfiguration()
                        config.rect = CGRect(x: 0, y: top, width: size[0], height: height)
                        let data = try await web.pdf(configuration: config)
                        guard let page = PDFDocument(data: data)?.page(at: 0) else { throw CocoaError(.fileReadCorruptFile) }
                        document.insert(page, at: document.pageCount)
                    }
                    if printDialog {
                        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true),
                              let window = web.window else { throw CocoaError(.fileWriteUnknown) }
                        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
                    } else {
                        guard let data = document.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
                        parent.export(.success(data))
                    }
                } catch { parent.export(.failure(error)) }
            }
            #else
            let formatter = web.viewPrintFormatter()
            if printDialog {
                let controller = UIPrintInteractionController.shared
                controller.printFormatter = formatter
                controller.present(from: web.bounds, in: web, animated: true)
            } else {
                let renderer = MarkdownPrintRenderer()
                renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
                parent.export(.success(UIGraphicsPDFRenderer(bounds: renderer.paperRect).pdfData { context in
                    let range = NSRange(location: 0, length: renderer.numberOfPages)
                    renderer.prepare(forDrawingPages: range)
                    for page in 0..<renderer.numberOfPages {
                        context.beginPage()
                        renderer.drawPage(at: page, in: renderer.paperRect)
                    }
                }))
            }
            #endif
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let action = body["action"] as? String else {
                replyHandler(nil, "Invalid request"); return
            }
            let session = parent.session
            switch action {
            case "toggle":
                if let line = body["value"] as? Int { parent.model.toggleTask(atLine: line) }
            case "tag":
                if let tag = body["value"] as? String { session.sidebarQuery = "#" + tag }
            case "open", "embed":
                guard let value = body["value"] as? [String: String], let target = value["target"], let source = value["path"] else {
                    replyHandler(nil, "Missing target"); return
                }
                if action == "open" { parent.follow(target, source) }
                else if let embed = embedded(target, source: source) { replyHandler(embed, nil); return }
                else { replyHandler(nil, "Missing embed"); return }
            default: replyHandler(nil, "Unknown action"); return
            }
            replyHandler(nil, nil)
        }

        private func embedded(_ target: String, source: String) -> [String: Any]? {
            let session = parent.session
            let parts = target.components(separatedBy: "#")
            let name = parts[0]
            guard let path = name.isEmpty ? source : (session.file(name, relativeTo: source) ?? session.resolve(name, from: source)) else { return nil }
            let url = session.url(for: path).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(session.root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { return nil }
            switch FileKind(path: path) {
            case .markdown:
                guard var source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                if parts.count > 1 {
                    guard let section = MarkdownHeading.section(parts.dropFirst().joined(separator: "#"), in: source) else { return nil }
                    source = section
                }
                return Self.payload(source, path: path)
            case .image:
                guard let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
                      let file = try? Data(contentsOf: url) else { return nil }
                return ["image": "data:\(mime);base64," + file.base64EncodedString()]
            case .ink:
                guard let data = try? Data(contentsOf: url), let ink = InkDocument.decode(data) else { return nil }
                let bounds = ink.contentBounds.insetBy(dx: -16, dy: -16)
                guard !bounds.isNull, bounds.width > 1, bounds.height > 1 else { return ["path": path] }
                let scale = min(2, 1300 / max(bounds.width, bounds.height))
                guard let image = InkRenderer.compose(ink.pkDrawing, images: ink.images ?? [], texts: ink.texts ?? [], root: session.root, rect: bounds,
                                                      scale: scale, dark: false, background: CGColor(gray: 1, alpha: 1)) else { return nil }
                #if os(macOS)
                let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                #else
                let png = UIImage(cgImage: image).pngData()
                #endif
                return png.map { ["image": "data:image/png;base64," + $0.base64EncodedString()] }
            default: return ["path": path]
            }
        }
    }
}

#if os(iOS)
private final class MarkdownPrintRenderer: UIPrintPageRenderer {
    override var paperRect: CGRect { CGRect(x: 0, y: 0, width: 612, height: 792) }
    override var printableRect: CGRect { paperRect.insetBy(dx: 36, dy: 36) }
}
#endif
