import AppKit
import SwiftUI

extension View {
    /// Calls `action` with the vertical scroll distance in points (positive for scrolling up,
    /// whatever the natural-scrolling setting) while the pointer is over this view. Clicks and
    /// drags pass through to the view as usual.
    func onScrollWheel(_ action: @escaping (CGFloat) -> Void) -> some View {
        overlay(ScrollWheelReader(action: action))
    }
}

/// SwiftUI on macOS 14 has no scroll-wheel events for plain views, so this watches the window's
/// scroll events and keeps the ones over its own frame.
private struct ScrollWheelReader: NSViewRepresentable {
    let action: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.action = action
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.action = action
    }

    final class ReaderView: NSView {
        var action: (CGFloat) -> Void = { _ in }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                // Momentum after a trackpad flick would keep turning the control after the fingers lift.
                guard event.momentumPhase.isEmpty else { return nil }
                var delta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
                if !event.hasPreciseScrollingDeltas { delta *= 8 }  // wheel notches come as lines
                if delta != 0 { self.action(delta) }
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
