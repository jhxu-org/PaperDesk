import SwiftUI
import PDFKit
import PaperDeskCore

struct PDFReaderView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        view.backgroundColor = NSColor(calibratedRed: 0.91, green: 0.92, blue: 0.93, alpha: 1)
        view.onHighlight = { model.highlightSelection() }
        view.onTranslate = { model.askAboutCurrentSelection("请翻译选中的内容，保留关键术语并标注原文依据。") }
        view.onExplain = { model.askAboutCurrentSelection("请解释选中内容的含义和关键概念，并标注原文依据。") }
        view.onDiscuss = { model.discussSelection() }
        view.onPDFInteraction = { [weak model] in
            guard let model, model.isChatFloating, !model.showSettings else { return }
            model.closeFloatingChat()
        }
        model.pdfView = view
        context.coordinator.observe(view)
        return view
    }
    func updateNSView(_ view: ReaderPDFView, context: Context) {
        if view.document !== model.pdfDocument {
            context.coordinator.isUpdating = true
            view.document = model.pdfDocument
            view.autoScales = true
            if let page = view.document?.page(at: model.currentPage) { view.go(to: page) }
            context.coordinator.isUpdating = false
        }
        context.coordinator.overlay.apply(model.notes, to: view.document)
    }
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    static func dismantleNSView(_ view: ReaderPDFView, coordinator: Coordinator) {
        view.stopInteractionMonitoring()
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: AppModel
        let overlay = PDFAnnotationOverlay()
        var isUpdating = false
        init(model: AppModel) { self.model = model }
        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: view)
            NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)), name: .PDFViewSelectionChanged, object: view)
        }
        @objc func pageChanged(_ notification: Notification) {
            guard !isUpdating, let view = notification.object as? PDFView,
                  let page = view.currentPage, let document = view.document else { return }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            // PDFKit can notify during a SwiftUI update; defer observable state changes.
            Task { @MainActor [weak self, weak document] in
                guard let self, document === self.model.pdfDocument else { return }
                self.model.pageChanged(index)
            }
        }
        @objc func selectionChanged(_ notification: Notification) {
            guard !isUpdating, let view = notification.object as? PDFView else { return }
            let text = view.currentSelection?.string ?? ""
            let document = view.document
            Task { @MainActor [weak self, weak document] in
                guard let self, document === self.model.pdfDocument else { return }
                self.model.selectedText = text
            }
        }
        func stop() { NotificationCenter.default.removeObserver(self) }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

final class ReaderPDFView: PDFView {
    var onHighlight: (() -> Void)?
    var onTranslate: (() -> Void)?
    var onExplain: (() -> Void)?
    var onDiscuss: (() -> Void)?
    var onPDFInteraction: (() -> Void)?
    private var interactionMonitor: Any?
    private var interactionTask: Task<Void, Never>?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopInteractionMonitoring()
        guard window != nil else { return }
        // PDFKit's internal document view receives clicks, so observe the actual event target.
        interactionMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  self.isPDFInteraction(event, in: window) else { return event }
            self.interactionTask?.cancel()
            let document = self.document
            // PDFKit can consume mouse-up inside its own selection tracking loop. Wait for release
            // without swallowing events or resizing the PDF while the user is still dragging.
            self.interactionTask = Task { @MainActor [weak self, weak window, weak document] in
                repeat {
                    do { try await Task.sleep(for: .milliseconds(25)) }
                    catch { return }
                } while NSEvent.pressedMouseButtons & 1 != 0
                guard !Task.isCancelled, let self, let window,
                      self.window === window, self.document === document else { return }
                self.interactionTask = nil
                self.onPDFInteraction?()
            }
            return event
        }
    }

    private func isPDFInteraction(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard document != nil, !isHiddenOrHasHiddenAncestor, window.attachedSheet == nil,
              bounds.contains(convert(event.locationInWindow, from: nil)),
              let content = window.contentView else { return false }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard let hit = content.hitTest(point), hit === self || hit.isDescendant(of: self) else { return false }
        // Scrollbars and controls over the reader aren't clicks on the PDF itself.
        var candidate: NSView? = hit
        while let view = candidate, view !== self {
            if view is NSScroller || view is NSControl { return false }
            candidate = view.superview
        }
        return true
    }

    func stopInteractionMonitoring() {
        if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor) }
        interactionMonitor = nil
        interactionTask?.cancel(); interactionTask = nil
    }
    deinit {
        if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor) }
        interactionTask?.cancel()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if !(currentSelection?.string ?? "").isEmpty {
            menu.addItem(.separator())
            for (title, action) in [("在浮窗中讨论选区", #selector(discussText)), ("保存高亮与笔记", #selector(highlightText)), ("翻译选中内容", #selector(translateText)), ("解释选中内容", #selector(explainText))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; menu.addItem(item)
            }
        }
        return menu
    }
    @objc private func highlightText() { onHighlight?() }
    @objc private func translateText() { onTranslate?() }
    @objc private func explainText() { onExplain?() }
    @objc private func discussText() { onDiscuss?() }
}
