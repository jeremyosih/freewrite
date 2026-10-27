//
//  FocusMode.swift
//  freewrite
//
//  Focus mode: scrolling down over the bottom bar hides the bar and the window chrome so only
//  the text remains; scrolling up over the same strip brings it back.
//

import AppKit
import SwiftUI

/// Turns scroll-wheel/trackpad events into deliberate "down" or "up" gestures: deltas add up
/// within one gesture until they pass a threshold, momentum (the glide after the fingers lift)
/// is ignored, and one gesture fires at most once, so a resting hand or a fling doesn't toggle.
struct FocusScrollGesture {
    enum Direction: Equatable {
        /// Towards the end of the document (`scrollingDeltaY < 0`): hide.
        case down
        /// Towards the start: show.
        case up
    }

    enum Phase: Equatable {
        /// Trackpad / Magic Mouse: fingers touched down.
        case began
        case changed
        /// Fingers lifted (or the system cancelled the gesture).
        case ended
        /// A classic mouse wheel: no phases, gestures are separated by a pause.
        case none
    }

    /// Points of a precise (trackpad) scroll: about a deliberate two-finger swipe.
    static let preciseThreshold: CGFloat = 60
    /// Lines of a mouse wheel: two notches.
    static let lineThreshold: CGFloat = 2
    /// A wheel pause longer than this starts a new gesture.
    static let wheelGap: TimeInterval = 0.35

    private var total: CGFloat = 0
    private var fired = false
    private var lastTime: TimeInterval?

    /// Feeds one event; returns a direction the moment the gesture passes the threshold.
    mutating func add(deltaY: CGFloat, isPrecise: Bool, phase: Phase, isMomentum: Bool, time: TimeInterval) -> Direction? {
        guard !isMomentum else { return nil }
        switch phase {
        case .began:
            reset()
        case .none:
            if let lastTime, time - lastTime > Self.wheelGap { reset() }
        case .changed, .ended:
            break
        }
        lastTime = time
        defer { if phase == .ended { reset() } }
        guard deltaY != 0 else { return nil }
        // Changing direction mid-gesture starts the count again.
        if total != 0 && (total < 0) != (deltaY < 0) {
            total = 0
        }
        total += deltaY
        let threshold = isPrecise ? Self.preciseThreshold : Self.lineThreshold
        guard !fired, abs(total) >= threshold else { return nil }
        fired = true
        return total < 0 ? .down : .up
    }

    mutating func reset() {
        total = 0
        fired = false
    }
}

extension FocusScrollGesture.Phase {
    init(_ event: NSEvent) {
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            self = .began
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            self = .ended
        } else if event.phase.isEmpty {
            self = .none
        } else {
            self = .changed
        }
    }
}

/// Reports the window a SwiftUI view lives in, so event monitors only act on their own window.
struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onChange?(window)
        }
    }
}
