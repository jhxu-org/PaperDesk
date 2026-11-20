import AppKit
import SwiftUI

@MainActor
final class FloatingChatController: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private let panel: ReadingChatPanel

    init(model: AppModel) {
        self.model = model
        panel = ReadingChatPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 780),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        panel.title = "阅读助手 · 浮窗"
        panel.minSize = NSSize(width: 480, height: 580)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        // Switching apps must not hide or reset the conversation panel.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FloatingChatView(model: model).tint(Palette.accent))
        panel.setFrameAutosaveName("PaperDeskReadingChat")
        if !panel.setFrameUsingName("PaperDeskReadingChat") {
            panel.center()
            if let screen = NSApp.mainWindow?.screen ?? NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameTopLeftPoint(NSPoint(x: max(frame.minX, frame.maxX - panel.frame.width - 32),
                    y: frame.maxY - 48))
            }
        }
    }

    func show() { panel.makeKeyAndOrderFront(nil) }
    func close() { if panel.isVisible || model?.isChatFloating == true { panel.close() } }
    func setPinned(_ pinned: Bool) { panel.level = pinned ? .floating : .normal }
    func windowWillClose(_ notification: Notification) { model?.floatingChatDidClose() }
}

private final class ReadingChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct FloatingChatView: View {
    @ObservedObject var model: AppModel
    @State private var pinned = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.system(size: 19)).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("阅读助手").font(.system(size: 15, weight: .semibold))
                        Text(model.selectedDocument?.title ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }.background(WindowZoomArea())
                Button {
                    pinned.toggle(); model.setFloatingChatPinned(pinned)
                } label: { Image(systemName: pinned ? "pin.fill" : "pin") }
                    .buttonStyle(.plain).foregroundStyle(pinned ? Palette.accent : .secondary)
                    .help(pinned ? "取消置顶" : "置顶浮窗").accessibilityLabel(pinned ? "取消置顶" : "置顶浮窗")
                Button { model.closeFloatingChat() } label: { Label("回到侧栏", systemImage: "sidebar.right") }
                    .controlSize(.small)
            }.padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
            AssistantPane(model: model, isFloating: true)
        }
        .background(.background)
        .background(WindowZoomArea(includesTitleBar: true, includesContentArea: false))
        .sheet(isPresented: Binding(get: { model.showSettings && model.isChatFloating },
            set: { model.showSettings = $0 })) { SettingsView(model: model) }
    }
}
