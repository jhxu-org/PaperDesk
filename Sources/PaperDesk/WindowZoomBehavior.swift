import AppKit
import SwiftUI

/// Observe just this window's title regions, without replacing SwiftUI's window delegate.
struct WindowZoomArea: NSViewRepresentable {
    var includesTitleBar = false
    var includesContentArea = true

    func makeNSView(context: Context) -> WindowZoomTrackingView {
        let view = WindowZoomTrackingView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: WindowZoomTrackingView, context: Context) {
        view.includesTitleBar = includesTitleBar
        view.includesContentArea = includesContentArea
    }

    static func dismantleNSView(_ view: WindowZoomTrackingView, coordinator: ()) { view.stopMonitoring() }
}

final class WindowZoomTrackingView: NSView {
    var includesTitleBar = false
    var includesContentArea = true
    private var monitor: Any?
    private var consumedMouseDown = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if event.type == .leftMouseUp, self.consumedMouseDown {
                self.consumedMouseDown = false
                return nil
            }
            guard event.type == .leftMouseDown, event.clickCount == 2,
                  !window.styleMask.contains(.fullScreen), window.attachedSheet == nil,
                  window.styleMask.contains(.resizable), self.isTitlePoint(event.locationInWindow, in: window) else { return event }
            self.consumedMouseDown = true
            WindowZoomState.toggle(window)
            return nil
        }
    }

    private func isTitlePoint(_ point: NSPoint, in window: NSWindow) -> Bool {
        if includesContentArea, bounds.contains(convert(point, from: nil)), !isHiddenOrHasHiddenAncestor { return true }
        guard includesTitleBar, point.y >= window.contentLayoutRect.maxY else { return false }
        // A double click on window controls or toolbar actions must retain its original behavior.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(kind), button.convert(button.bounds, to: nil).contains(point) { return false }
        }
        for item in window.toolbar?.items ?? [] {
            if let view = item.view, view.convert(view.bounds, to: nil).contains(point) { return false }
        }
        if let frameView = window.contentView?.superview {
            var hit = frameView.hitTest(frameView.convert(point, from: nil))
            while let view = hit {
                if view is NSButton || view is NSSegmentedControl { return false }
                if let field = view as? NSTextField, field.isEditable || field.isSelectable { return false }
                hit = view.superview
            }
        }
        return true
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        consumedMouseDown = false
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

@MainActor
private final class WindowZoomState {
    private static let states = NSMapTable<NSWindow, WindowZoomState>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var restoreFrame: NSRect?
    private var expandedFrame: NSRect?

    static func toggle(_ window: NSWindow) {
        let state = states.object(forKey: window) ?? WindowZoomState()
        states.setObject(state, forKey: window)
        state.toggle(window)
    }

    private func toggle(_ window: NSWindow) {
        guard let screen = window.screen else { return }
        let visible = screen.visibleFrame
        let current = window.frame
        let isExpanded = nearlyEqual(current, visible) || expandedFrame.map { nearlyEqual(current, $0) } == true
        let target: NSRect
        if isExpanded {
            // A window can already fill the display before this behavior first runs.
            let fallbackSize = NSSize(width: visible.width * 0.78, height: visible.height * 0.82)
            let fallback = NSRect(x: visible.midX - fallbackSize.width / 2,
                y: visible.midY - fallbackSize.height / 2, width: fallbackSize.width, height: fallbackSize.height)
            target = constrained(restoreFrame ?? fallback, to: visible, window: window)
            restoreFrame = nil
            expandedFrame = nil
        } else {
            restoreFrame = current
            expandedFrame = visible
            target = visible
        }
        window.setFrame(target, display: true, animate: true)
    }

    private func nearlyEqual(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3 &&
        abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }

    private func constrained(_ frame: NSRect, to visible: NSRect, window: NSWindow) -> NSRect {
        let contentMinimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        let width = min(visible.width, max(frame.width, window.minSize.width, contentMinimum.width))
        let height = min(visible.height, max(frame.height, window.minSize.height, contentMinimum.height))
        return NSRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
            y: min(max(frame.minY, visible.minY), visible.maxY - height), width: width, height: height)
    }
}
