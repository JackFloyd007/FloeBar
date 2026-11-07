//
//  NativeMenuBarDragSession.swift
//  FloeBar
//

import CoreGraphics

/// State for one native gesture. Event delivery is not proof of a reordered item;
/// the caller still verifies the settled AX order after releasing input.
struct NativeMenuBarDragSession {
    enum Phase: String { case preflight, hover, dragging, release }
    private(set) var phase = Phase.preflight
    private(set) var firstInterruption: (phase: Phase, type: CGEventType, source: String)?
    mutating func enter(_ phase: Phase) { self.phase = phase }
    let token: Int64
    private(set) var lastPoint: CGPoint
    private(set) var interrupted = false
    private(set) var mouseReleaseObserved = false
    private(set) var mouseReleasePoint: CGPoint?
    private(set) var stationaryNotifications = 0
    private var mouseHeld = false
    private var commandHeld = false

    init(token: Int64, start: CGPoint) {
        self.token = token
        lastPoint = start
    }

    var canRestoreCursor: Bool {
        !interrupted && (mouseReleasePoint == nil || mouseReleaseObserved)
    }

    mutating func observe(type: CGEventType, token: Int64, point: CGPoint, delta: CGPoint = .zero) {
        guard token == self.token else {
            // A zero-motion notification at our exact last point does not
            // represent a competing pointer move. All actual movement and
            // every button/key/scroll event still interrupts the gesture.
            if type == .mouseMoved, point == lastPoint, delta == .zero {
                stationaryNotifications += 1
                return
            }
            if firstInterruption == nil {
                firstInterruption = (phase, type, token == 0 ? "untagged" : "other-token")
            }
            interrupted = true
            return
        }
        if type == .leftMouseUp, let mouseReleasePoint, point == mouseReleasePoint {
            mouseReleaseObserved = true
        }
    }

    mutating func didPressCommand() { commandHeld = true }
    mutating func didPressMouse() { mouseHeld = true }
    mutating func didDrag(to point: CGPoint) { lastPoint = point }

    /// Cancellation releases at the last posted point, never the unvisited target.
    mutating func takeMouseRelease() -> CGPoint? {
        guard mouseHeld else { return nil }
        mouseHeld = false
        mouseReleasePoint = lastPoint
        return lastPoint
    }

    mutating func takeCommandRelease() -> Bool {
        guard commandHeld else { return false }
        commandHeld = false
        return true
    }

    static func path(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        // A short 60 ms path can reach mouse-up before MenuBarAgent handles
        // reordering. Keep a continuous >=400 ms path at the caller's 10 ms pace.
        let steps = max(40, min(80, Int(ceil(abs(end.x - start.x) / 6))))
        return (1 ... steps).map { step in
            let progress = CGFloat(step) / CGFloat(steps)
            return CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
        }
    }
}
