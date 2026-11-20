import AppKit

// Isolated native text-control checks. No windows are shown and no model service is contacted.
@main
struct ChatInputChecks {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let input = ChatTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 76))
        input.isRichText = false
        var sent: [String] = []
        input.onSubmit = { sent.append(input.string) }
        func press(_ keyCode: UInt16 = 36, modifiers: NSEvent.ModifierFlags = []) {
            input.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: keyCode)!)
        }
        for empty in ["", " \n \t"] {
            input.string = empty; press()
            precondition(sent.isEmpty && input.string == empty, "Empty Enter must not submit or add newlines")
        }
        input.string = "你好，分析当前页"; press()
        precondition(sent == ["你好，分析当前页"], "Enter should submit the complete Unicode draft once")
        precondition(!input.string.contains("\n"), "Sending must not insert a newline")
        input.string = "第二个问题"; press(76)
        precondition(sent.last == "第二个问题" && sent.count == 2, "Numpad Enter should submit")
        input.string = "快捷发送"; press(modifiers: .command)
        precondition(sent.last == "快捷发送" && sent.count == 3, "Command Enter remains supported")
        input.canSubmit = false; input.string = "生成过程中保留草稿"; press()
        precondition(sent.count == 3 && input.string == "生成过程中保留草稿", "Busy Enter must preserve the draft")
        input.canSubmit = true; input.string = "第一行"; input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
        press(modifiers: .shift)
        precondition(sent.count == 3 && input.string == "第一行\n", "Shift Enter should insert one newline")
        input.string = ""; input.setMarkedText("中文候选", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(input.hasMarkedText(), "IME fixture must be composing")
        press()
        precondition(sent.count == 3, "IME confirmation must not send a question")
        input.unmarkText(); input.string = "已确认的中文"; press()
        precondition(sent.last == "已确认的中文" && sent.count == 4, "A later Enter should send committed Chinese")
        print("PASS  Enter, keypad Enter, Command Enter, Shift Enter, empty/busy drafts and Chinese composition")
    }
}
