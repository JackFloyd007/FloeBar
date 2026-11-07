import Foundation

@main
struct MenuBarPreviewAuthorizationTests {
    @MainActor
    static func main() async {
        var granted = true
        var generation = 1
        var checks = 0
        var captures = 0
        func preflight() -> Bool { checks += 1; return granted }
        for _ in 0..<6 {
            let value = await MenuBarPreviewAuthorization.capture(userInitiated: false, isCurrent: { true }, preflight: preflight) {
                captures += 1; return "pixels"
            }
            precondition(value == nil)
        }
        precondition(checks == 0 && captures == 0, "Navigation/background updates must not touch capture or permission APIs")
        let value = await MenuBarPreviewAuthorization.capture(userInitiated: true, isCurrent: { generation == 1 }, preflight: preflight) {
            captures += 1; return "pixels"
        }
        precondition(value == "pixels" && checks == 1 && captures == 1)
        granted = false // A formerly true cache is not authority after revocation.
        let denied = await MenuBarPreviewAuthorization.capture(userInitiated: true, isCurrent: { true }, preflight: preflight) {
            captures += 1; return "pixels"
        }
        precondition(denied == nil && checks == 2 && captures == 1)
        granted = true
        var queued: CheckedContinuation<Void, Never>?
        let cancelled = Task { @MainActor in
            await withCheckedContinuation { queued = $0 }
            return await MenuBarPreviewAuthorization.capture(userInitiated: true, isCurrent: { true }, preflight: preflight) {
                captures += 1; return "pixels"
            }
        }
        while queued == nil { await Task.yield() }
        cancelled.cancel()
        queued?.resume()
        let cancelledValue = await cancelled.value
        precondition(cancelledValue == nil && checks == 2 && captures == 1, "Cancelled scale/session wait must not issue a late screenshot")
        let late = await MenuBarPreviewAuthorization.capture(userInitiated: true, isCurrent: { generation == 1 }, preflight: preflight) {
            captures += 1
            await Task.yield()
            generation = 2
            return "old pixels"
        }
        precondition(late == nil && captures == 2, "A page/display generation change must reject publication")
        let stale = await MenuBarPreviewAuthorization.capture(userInitiated: true, isCurrent: { generation == 1 }, preflight: preflight) {
            captures += 1; return "pixels"
        }
        precondition(stale == nil && checks == 3 && captures == 2)
        var request = MenuBarPreviewRequest()
        precondition(!request.consume(in: 1))
        request.issue(in: 1)
        precondition(request.consume(in: 1))
        precondition(!request.consume(in: 1), "A previously consumed request must not replay when the same view reappears")
        request.issue(in: 1)
        request.discard()
        precondition(!request.consume(in: 1), "Leaving before task start must discard a queued click")
        request.issue(in: 1)
        precondition(request.consume(in: 1))
        request.issue(in: 1)
        precondition(!request.consume(in: 2), "A queued click from the closed window cannot bind to a reopened session")
        precondition(!request.consume(in: 1))
        request.issue(in: 2)
        precondition(request.consume(in: 2))
        print("PASS: automatic0, explicit granted1, fresh revoked0, queued cancel0, late generation no publication")
    }
}
