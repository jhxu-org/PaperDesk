import SwiftUI
import WebKit
import PaperDeskCore

/// A local, selectable Markdown/LaTeX surface shared by the sidebar and floating chat.
struct ChatRichText: View {
    let message: ChatMessage
    let fontSize: CGFloat
    var documentURL: URL? = nil
    var onVisualPDF: (ChatVisual) -> Void = { _ in }
    let onSource: (SourceChunk) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 24
    @State private var failed = false
    @State private var ready = false
    @State private var images: [ChatPageImage] = []
    @State private var preview: ChatVisual?
    private var visualKey: String { (documentURL?.path ?? "") + (message.visuals ?? []).map(\.id).joined(separator: "|") }

    static func containsMath(_ text: String) -> Bool {
        text.contains("\\(") || text.contains("\\[") || text.contains("$")
    }

    var body: some View {
        Group {
          if failed {
            VStack(alignment: .leading) {
                Text(message.content).font(.system(size: fontSize)).lineSpacing(6).textSelection(.enabled)
                ForEach(message.visuals ?? []) { visual in
                    Button("查看第 \(visual.page + 1) 页原文配图") { preview = visual }
                }
            }
          } else {
            ZStack(alignment: .topLeading) {
                if !ready {
                    Text(message.content).font(.system(size: fontSize)).lineSpacing(6).textSelection(.enabled)
                }
                ChatWebContent(message: message, images: images, fontSize: fontSize, dark: colorScheme == .dark,
                    height: $height, failed: $failed, ready: $ready, onSource: onSource,
                    onVisual: { visual, showPDF in if showPDF { onVisualPDF(visual) } else { preview = visual } })
                    .frame(height: height).opacity(ready ? 1 : 0)
            }
          }
        }
        .task(id: visualKey) {
            guard let documentURL, let visuals = message.visuals, !visuals.isEmpty else { images = []; return }
            do {
                let loaded = try await PDFVisualCache.shared.images(url: documentURL, visuals: visuals)
                guard !Task.isCancelled else { return }
                images = loaded
            } catch { /* The card still offers PDF navigation if a preview cannot be rendered. */ }
        }
        .sheet(item: $preview) { visual in
            PDFVisualPreview(visual: visual, documentURL: documentURL, onShowPDF: onVisualPDF)
        }
    }
}

private struct ChatWebContent: NSViewRepresentable {
    let message: ChatMessage
    let images: [ChatPageImage]
    let fontSize: CGFloat
    let dark: Bool
    @Binding var height: CGFloat
    @Binding var failed: Bool
    @Binding var ready: Bool
    let onSource: (SourceChunk) -> Void
    let onVisual: (ChatVisual, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "chatHeight")
        configuration.userContentController.add(context.coordinator, name: "chatSource")
        configuration.userContentController.add(context.coordinator, name: "chatVisual")
        let view = ChatWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.allowsLinkPreview = false
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        let resources = Bundle.main.resourceURL?.appending(path: "PaperDesk_PaperDesk.bundle")
        let bundle = resources.flatMap { Bundle(url: $0) } ?? Bundle.module
        if let url = bundle.url(forResource: "index", withExtension: "html", subdirectory: "Chat") {
            context.coordinator.documentURL = url
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else { context.coordinator.fail() }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.scheduleRender()
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.renderTask?.cancel()
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.navigationDelegate = nil
        view.stopLoading()
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: ChatWebContent
        weak var webView: WKWebView?
        var documentURL: URL?
        var loaded = false
        var renderTask: Task<Void, Never>?
        private var previousMessage: ChatMessage?
        private var previousDark: Bool?
        private var previousSize: CGFloat?
        private var previousImages: [String] = []

        init(_ parent: ChatWebContent) { self.parent = parent }
        func scheduleRender() {
            guard loaded else { return }
            guard previousMessage != parent.message || previousDark != parent.dark || previousSize != parent.fontSize || previousImages != parent.images.map({ $0.visual.id }) else { return }
            // Coalesce streamed tokens without reloading the web document or fonts.
            guard renderTask == nil else { return }
            renderTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, !Task.isCancelled else { return }
                self.renderTask = nil
                self.render()
            }
        }
        func render() {
            guard let webView else { return }
            previousMessage = parent.message; previousDark = parent.dark; previousSize = parent.fontSize
            let imageIDs = parent.images.map { $0.visual.id }
            var payload: [String: Any] = [
                "text": parent.message.content, "fontSize": Double(parent.fontSize), "dark": parent.dark,
                "sources": parent.message.sources.map { ["id": $0.id, "page": $0.page] as [String: Any] },
                "visuals": (parent.message.visuals ?? []).map { visual in
                    ["id": visual.id, "page": visual.page, "caption": visual.caption] as [String: Any]
                }
            ]
            // A token update should not resend megabytes of unchanged page images to WebKit.
            if previousImages != imageIDs {
                payload["images"] = parent.images.map { ["id": $0.visual.id, "dataURL": $0.dataURL] }
                previousImages = imageIDs
            }
            webView.callAsyncJavaScript("window.PaperDeskChat.update(payload)", arguments: ["payload": payload],
                in: nil, in: .page) { [weak self] result in
                    if case .failure = result { self?.fail() }
                }
        }
        func fail() {
            Task { @MainActor [weak self] in self?.parent.failed = true }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; render() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail() }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url == documentURL && !loaded ? .allow : .cancel)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame else { return }
            if message.name == "chatHeight", let number = message.body as? NSNumber {
                let value = CGFloat(number.doubleValue)
                guard value.isFinite, value >= 0, value < 1_000_000 else { return }
                let height = max(24, value)
                if abs(parent.height - height) > 0.5 { parent.height = height }
                parent.ready = true
            } else if message.name == "chatSource", let id = message.body as? String,
                      let source = parent.message.sources.first(where: { $0.id == id }) {
                parent.onSource(source)
            } else if message.name == "chatVisual", let value = message.body as? [String: String],
                      let id = value["id"], let action = value["action"], ["preview", "pdf"].contains(action),
                      let visual = parent.message.visuals?.first(where: { $0.id == id }) {
                parent.onVisual(visual, action == "pdf")
            }
        }
    }
}

private final class ChatWebView: WKWebView {
    // The outer SwiftUI conversation owns vertical scrolling; long equations may scroll horizontally.
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let scroll = enclosingScrollView {
            scroll.scrollWheel(with: event)
        } else { super.scrollWheel(with: event) }
    }
}
