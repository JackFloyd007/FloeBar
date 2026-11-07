import CoreGraphics

@main
enum NativeDragSessionTests {
    static func main() {
        let start = CGPoint(x: 100, y: 15)
        let end = CGPoint(x: 150, y: 15)
        var cancelledBeforeDown = NativeMenuBarDragSession(token: 1, start: start)
        precondition(cancelledBeforeDown.takeMouseRelease() == nil)
        precondition(!cancelledBeforeDown.takeCommandRelease())
        precondition(cancelledBeforeDown.canRestoreCursor)
        cancelledBeforeDown.observe(type: .mouseMoved, token: 0, point: start, delta: .zero)
        precondition(!cancelledBeforeDown.interrupted && cancelledBeforeDown.stationaryNotifications == 1)
        cancelledBeforeDown.observe(type: .mouseMoved, token: 0, point: start, delta: CGPoint(x: 1, y: 0))
        precondition(cancelledBeforeDown.interrupted, "real motion cannot hide behind a coincident rounded point")

        var foreignClick = NativeMenuBarDragSession(token: 5, start: start)
        foreignClick.observe(type: .leftMouseDown, token: 0, point: start, delta: .zero)
        precondition(foreignClick.firstInterruption?.phase == .preflight && foreignClick.firstInterruption?.type == .leftMouseDown)
        precondition(foreignClick.interrupted, "a click at our exact point is still competing input")

        var flags = NativeMenuBarDragSession(token: 11, start: start)
        flags.enter(.hover)
        flags.observe(type: .flagsChanged, token: 0, point: start)
        precondition(flags.interrupted && flags.firstInterruption?.phase == .hover && flags.firstInterruption?.type == .flagsChanged)
        flags.enter(.dragging)
        flags.observe(type: .keyDown, token: 12, point: start)
        precondition(flags.firstInterruption?.phase == .hover) // First reason stays stable; key content is never stored.

        var interrupted = NativeMenuBarDragSession(token: 2, start: start)
        interrupted.didPressCommand()
        interrupted.didPressMouse()
        let intermediate = CGPoint(x: 110, y: 15)
        interrupted.didDrag(to: intermediate)
        interrupted.observe(type: .mouseMoved, token: 0, point: CGPoint(x: 500, y: 500))
        precondition(interrupted.interrupted)
        precondition(interrupted.takeMouseRelease() == intermediate, "cancel at the last sent point, not the target")
        precondition(interrupted.takeMouseRelease() == nil, "cleanup cannot replay mouse-up")
        precondition(interrupted.takeCommandRelease())
        precondition(!interrupted.takeCommandRelease())
        interrupted.observe(type: .leftMouseUp, token: 2, point: intermediate)
        precondition(interrupted.mouseReleaseObserved && !interrupted.canRestoreCursor)

        var normal = NativeMenuBarDragSession(token: 3, start: start)
        normal.didPressCommand()
        normal.observe(type: .flagsChanged, token: 3, point: start)
        normal.didPressMouse()
        normal.observe(type: .leftMouseDown, token: 3, point: start)
        normal.observe(type: .leftMouseUp, token: 3, point: end)
        precondition(!normal.mouseReleaseObserved, "an up before our release is not a receipt")
        normal.didDrag(to: end)
        precondition(normal.takeMouseRelease() == end)
        precondition(!normal.canRestoreCursor, "missing receipt must not warp the cursor")
        normal.observe(type: .leftMouseUp, token: 3, point: start)
        precondition(!normal.mouseReleaseObserved, "wrong-point release is not a receipt")
        normal.observe(type: .leftMouseDragged, token: 3, point: end)
        precondition(!normal.mouseReleaseObserved)
        normal.observe(type: .leftMouseUp, token: 3, point: end)
        precondition(normal.mouseReleaseObserved && normal.canRestoreCursor && !normal.interrupted)
        precondition(normal.takeCommandRelease())

        var staleReceipt = NativeMenuBarDragSession(token: 4, start: start)
        staleReceipt.didPressMouse()
        _ = staleReceipt.takeMouseRelease()
        staleReceipt.observe(type: .leftMouseUp, token: 3, point: start)
        precondition(staleReceipt.interrupted && !staleReceipt.mouseReleaseObserved)

        for target in [end, CGPoint(x: -200, y: 15), CGPoint(x: 2500, y: 15)] {
            let path = NativeMenuBarDragSession.path(from: start, to: target)
            precondition(path.last == target && path.count >= 40 && path.count <= 80)
            let sign: CGFloat = target.x > start.x ? 1 : -1
            var previous = start
            for point in path {
                precondition((point.x - previous.x) * sign > 0 && point.y == start.y)
                previous = point
            }
        }
        print("PASS: native drag cancellation, exactly-once releases, receipt identity, cursor ownership and continuous paths")
    }
}
