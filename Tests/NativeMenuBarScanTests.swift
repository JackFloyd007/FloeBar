import ApplicationServices
import Foundation

final class ScanTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    func now() -> TimeInterval { lock.withLock { time } }
    func advance(_ duration: TimeInterval) { lock.withLock { time += duration } }
}

@main
enum NativeMenuBarScanTests {
    @MainActor static func main() async throws {
        let clock = ScanTestClock()
        let budget = NativeMenuBarScanContext(purpose: "fixture", budget: 0.05, now: { clock.now() })
        var reads = 0
        let first = try budget.performRead { timeout in
            precondition(timeout > 0 && timeout <= 0.04)
            reads += 1; clock.advance(0.04); return "first"
        }
        precondition(first == "first")
        do {
            _ = try budget.performRead { timeout in
                precondition(timeout > 0 && timeout <= 0.011)
                reads += 1; clock.advance(0.04); return "expired-result"
            }
            preconditionFailure("an uninterruptible read crossing the deadline cannot return usable data")
        } catch NativeMenuBarScanStatus.budgetExceeded { }
        do { _ = try budget.performRead { _ in reads += 1; return "must-not-run" }; preconditionFailure() }
        catch NativeMenuBarScanStatus.budgetExceeded { }
        precondition(reads == 2 && budget.metrics.calls == 2)
        precondition(clock.now() <= 0.05 + 0.04, "budget overshoot is limited to the current uninterruptible fixture call")
        let cancelled = NativeMenuBarScanContext(purpose: "cancel", now: { clock.now() })
        do {
            _ = try cancelled.performRead { _ in cancelled.cancel(); clock.advance(0.007); return "discard" }
            preconditionFailure("cancelled read cannot publish its result")
        } catch NativeMenuBarScanStatus.cancelled { }
        precondition((cancelled.metrics.cancelDrain ?? 0) >= 0.006, "cancel drain is measured from first cancellation signal")
        var order = [Int]()
        let responsive = NativeMenuBarScanContext(purpose: "heartbeat", budget: 1)
        _ = try await responsive.readOnMain { _ in
            order.append(1)
            DispatchQueue.main.async { order.append(2) }
            return 1
        }
        _ = try await responsive.readOnMain { _ in order.append(3); return 2 }
        precondition(order == [1, 2, 3], "main-queue heartbeat runs between atomic reads, not after the full owner")
        let bar = AXUIElementCreateApplication(1) // Local proxy construction only, no AX query.
        typealias Attributes = NativeMenuBarScanAttributes
        precondition(Attributes.extras(error: .attributeUnsupported, value: nil) == .empty)
        precondition(Attributes.extras(error: .noValue, value: nil) == .empty)
        precondition(Attributes.extras(error: .cannotComplete, value: nil) == .incomplete)
        precondition(Attributes.extras(error: .notImplemented, value: nil) == .incomplete)
        precondition(Attributes.extras(error: .notImplemented, value: nil, attributeNames: []) == .empty)
        precondition(Attributes.extras(error: .success, value: nil) == .incomplete)
        precondition(Attributes.extras(error: .success, value: "wrong" as CFString) == .incomplete)
        precondition(Attributes.extras(error: .success, value: bar) == .bar)
        precondition(Attributes.children(error: .success, value: [] as CFArray)?.isEmpty == true)
        for failure in [AXError.attributeUnsupported, .noValue, .cannotComplete] {
            let parsed = Attributes.children(error: failure, value: [] as CFArray)
            precondition(parsed == nil)
            let status = NativeMenuBarScanCompletion.status(required: [1], confirmed: parsed == nil ? [] : [1], terminal: .complete)
            precondition(NativeMenuBarScanResult(value: Set(["old-item"]), status: status).completeValue == nil,
                "unsupported/unresponsive children cannot authorize retiring an old item")
        }
        precondition(Attributes.children(error: .success, value: "wrong" as CFString) == nil)
        var unsupported = AXError.attributeUnsupported
        let missing = AXValueCreate(.axError, &unsupported)!
        var unresponsive = AXError.cannotComplete
        let failed = AXValueCreate(.axError, &unresponsive)!
        precondition(Attributes.fields(error: .success, value: [missing] as CFArray, names: [kAXIdentifierAttribute])?.isEmpty == true)
        precondition(Attributes.fields(error: .success, value: [failed] as CFArray, names: [kAXIdentifierAttribute]) == nil)
        precondition(Attributes.fields(error: .success, value: [failed] as CFArray, names: [kAXHelpAttribute])?.isEmpty == true,
            "supplementary metadata can degrade without inventing a new identity")
        var rect = CGRect(x: 300, y: 4, width: 24, height: 22)
        let axFrame = AXValueCreate(.cgRect, &rect)!
        let frameOnly = Attributes.fields(error: .success, value: [axFrame, "stable-id" as CFString] as CFArray,
            names: ["AXFrame", kAXIdentifierAttribute])!
        precondition(Attributes.frame(frameOnly) == rect, "AXFrame-only owner uses the original geometry API without optional backup reads")
        var point = rect.origin
        var size = rect.size
        let axPoint = AXValueCreate(.cgPoint, &point)!
        let axSize = AXValueCreate(.cgSize, &size)!
        let alternate = Attributes.fields(error: .success, value: [axPoint, axSize] as CFArray,
            names: [kAXPositionAttribute, kAXSizeAttribute])!
        precondition(Attributes.frame(alternate) == rect, "position/size-only hosts remain supported")
        precondition(Attributes.frame(["AXFrame": "wrong" as CFString]) == nil)
        precondition(Attributes.frame(["AXFrame": axPoint]) == nil)
        precondition(Attributes.frame([kAXPositionAttribute: "wrong" as CFString, kAXSizeAttribute: axSize]) == nil)
        precondition(Attributes.frame([kAXPositionAttribute: axPoint]) == nil)
        precondition(Attributes.frame([:]) == nil, "no geometry is never a complete frame")
        precondition(Attributes.fields(error: .success, value: [axFrame, failed] as CFArray,
            names: ["AXFrame", kAXIdentifierAttribute]) == nil, "valid geometry never hides a failed identity read")
        typealias Status = NativeMenuBarScanStatus
        precondition(NativeMenuBarScanCompletion.status(required: [], confirmed: [1, 3], terminal: .complete) == .complete,
            "unrelated applications without AX cannot poison initial discovery")
        precondition(NativeMenuBarScanCompletion.status(required: [1, 2, 3], confirmed: [1, 3], terminal: .complete) == .incomplete,
            "partial endpoints A/C cannot wash a missing guard owner B into a complete reorder")
        precondition(NativeMenuBarScanCompletion.status(required: [1], confirmed: [1], terminal: .budgetExceeded) == .budgetExceeded)
        for status in [Status.incomplete, .cancelled, .budgetExceeded] {
            precondition(NativeMenuBarScanResult(value: ["a", "c"], status: status).completeValue == nil)
            precondition(NativeMenuBarScanResult(value: [String](), status: status).completeValue == nil)
        }
        precondition(NativeMenuBarScanResult(value: [String](), status: .complete).completeValue != nil,
            "authoritative empty and cancelled empty have different meanings")
        let gate = NativeMenuBarScanGate()
        let active = NativeMenuBarScanContext(purpose: "active", budget: 10)
        let acquired = await gate.acquire(active)
        precondition(acquired)
        let waiting = NativeMenuBarScanContext(purpose: "cancelled-waiter", budget: 10)
        var entered = false
        let waiter = Task { @MainActor in
            let result = await gate.acquire(waiting)
            if result { entered = true; await gate.release(waiting.id) }
            return result
        }
        await Task.yield()
        waiting.cancel()
        await gate.discardWaiter(waiting.id)
        let waiterAcquired = await waiter.value
        precondition(!waiterAcquired && !entered, "cancelled waiter performs no AX work after lock release")
        let timedClock = ScanTestClock()
        let expired = NativeMenuBarScanContext(purpose: "expired", budget: 0.1, now: { timedClock.now() })
        let expiredTask = Task { await gate.acquire(expired) }
        await Task.yield()
        timedClock.advance(0.2)
        await gate.discardWaiter(expired.id)
        let expiredAcquired = await expiredTask.value
        precondition(!expiredAcquired)
        let latest = NativeMenuBarScanContext(purpose: "latest", budget: 10)
        let next = Task { @MainActor in
            let result = await gate.acquire(latest)
            if result { entered = true; await gate.release(latest.id) }
            return result
        }
        await Task.yield()
        precondition(!entered, "only one full scan owns the gate")
        await gate.release(active.id)
        let latestAcquired = await next.value
        precondition(latestAcquired && entered)
        var refreshes = NativeMenuBarRefreshQueue<String>()
        precondition(refreshes.request(["old-session"]))
        precondition(refreshes.takePending() == ["old-session"])
        refreshes.cancelPending() // Close the old Layout while its reader is in flight.
        precondition(!refreshes.request(["new-session"]), "new request waits for the cancelled owner to drain")
        let carry = refreshes.finish()
        precondition(carry == ["new-session"], "old cancellation cannot clear a reopened session's request")
        precondition(refreshes.request(carry))
        precondition(refreshes.takePending() == ["new-session"])
        precondition(refreshes.finish().isEmpty)
        print("PASS: per-read/overall budgets, cancellation, main heartbeat, complete-empty/owner requirements and serial queued cancellation")
    }
}
