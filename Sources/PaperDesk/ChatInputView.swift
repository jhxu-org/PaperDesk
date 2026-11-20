import AppKit
import SwiftUI

/// One native text layout owns both the placeholder and the editable text.
struct ChatInputView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var canSubmit: Bool
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 76))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentInsets = .init()

        let input = ChatTextView(frame: scroll.contentView.bounds)
        input.drawsBackground = false
        input.isRichText = false
        input.importsGraphics = false
        input.allowsUndo = true
        input.font = .systemFont(ofSize: 13)
        input.textColor = .labelColor
        input.insertionPointColor = .labelColor
        input.textContainerInset = NSSize(width: 4, height: 6)
        input.textContainer?.lineFragmentPadding = 0
        input.textContainer?.widthTracksTextView = true
        input.textContainer?.heightTracksTextView = false
        input.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        input.isHorizontallyResizable = false
        input.isVerticallyResizable = true
        input.autoresizingMask = [.width]
        input.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.setAccessibilityLabel("向阅读助手提问")
        input.setAccessibilityHelp("Enter 发送问题，Shift+Enter 换行。")
        input.delegate = context.coordinator
        input.onSubmit = { [weak input, weak coordinator = context.coordinator] in
            guard let input, let coordinator else { return }
            coordinator.parent.text = input.string
            coordinator.parent.onSubmit()
        }
        scroll.documentView = input
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let input = scroll.documentView as? ChatTextView else { return }
        input.placeholder = placeholder
        input.canSubmit = canSubmit
        // SwiftUI updates must not replace the input method's in-progress composition.
        if input.string != text && !input.hasMarkedText() {
            input.string = text
            input.undoManager?.removeAllActions()
            input.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            input.scrollRangeToVisible(input.selectedRange())
            input.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputView
        init(_ parent: ChatInputView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let input = notification.object as? ChatTextView else { return }
            parent.text = input.string
            input.needsDisplay = true
        }
    }
}

final class ChatTextView: NSTextView {
    var placeholder = "" { didSet { if oldValue != placeholder { needsDisplay = true } } }
    var canSubmit = true
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && modifiers == .shift && !hasMarkedText() {
            insertNewline(nil)
            return
        }
        if isReturn && (modifiers.isEmpty || modifiers == .command) && !hasMarkedText() {
            if canSubmit && !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onSubmit?() }
            return
        }
        // Shift+Return and input-method candidate confirmation retain native text behavior.
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if window?.firstResponder === self, modifiers == .command,
           event.keyCode == 36 || event.keyCode == 76, !hasMarkedText() {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty && !hasMarkedText(), let font else { return }
        let origin = textContainerOrigin
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (placeholder as NSString).draw(in: NSRect(x: origin.x, y: origin.y,
            width: max(0, bounds.width - origin.x - textContainerInset.width), height: font.ascender - font.descender + font.leading + 4),
            withAttributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor, .paragraphStyle: paragraph])
    }
}
