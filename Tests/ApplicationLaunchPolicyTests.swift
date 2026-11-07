import Foundation

@main
enum ApplicationLaunchPolicyTests {
    @MainActor static func main() {
        typealias Instance = ApplicationLaunchPolicy.Instance
        let old = Instance(pid: 20, bundleIdentifier: "floe", launchedAt: Date(timeIntervalSince1970: 1))
        let new = Instance(pid: 30, bundleIdentifier: "floe", launchedAt: Date(timeIntervalSince1970: 2))
        let simultaneous = Instance(pid: 40, bundleIdentifier: "floe", launchedAt: new.launchedAt)
        let other = Instance(pid: 10, bundleIdentifier: "other", launchedAt: old.launchedAt)
        let unknown = Instance(pid: 50, bundleIdentifier: "floe", launchedAt: nil)
        let all = [new, old, simultaneous, other]
        precondition(ApplicationLaunchPolicy.predecessors(of: old, among: all).isEmpty)
        precondition(ApplicationLaunchPolicy.predecessors(of: new, among: all) == [old])
        precondition(ApplicationLaunchPolicy.predecessors(of: simultaneous, among: all.reversed()) == [old, new])
        precondition(ApplicationLaunchPolicy.hasUnverifiedStartOrder(current: unknown, among: all),
            "unknown current launch date must present manual resolution, never silently bypass conflict")
        precondition(ApplicationLaunchPolicy.hasUnverifiedStartOrder(current: new, among: all + [unknown]))
        precondition(!ApplicationLaunchPolicy.hasUnverifiedStartOrder(current: new, among: all))
        precondition(!ApplicationLaunchPolicy.hasUnverifiedStartOrder(current: unknown, among: [unknown, other]))
        precondition(ApplicationLaunchPolicy.predecessors(of: unknown, among: all + [unknown]).isEmpty)
        precondition(ApplicationLaunchPolicy.predecessors(of: new, among: all + [unknown]) == [unknown, old])
        for current in all where current.bundleIdentifier == "floe" {
            for earlier in ApplicationLaunchPolicy.predecessors(of: current, among: all) {
                precondition(!ApplicationLaunchPolicy.predecessors(of: earlier, among: all).contains(current),
                    "two simultaneous launches cannot arbitrate each other")
            }
        }
        var cancelled = ApplicationLaunchLifecycle()
        precondition(cancelled.willFinish().isEmpty && cancelled.didFinish().isEmpty)
        precondition(!cancelled.isAuthorized, "cancelled launch creates no migration/setup effects")
        precondition(cancelled.authorize() == [.migrate, .setup], "early AppKit callbacks are deferred until authorization")
        precondition(cancelled.authorize().isEmpty && cancelled.didFinish().isEmpty && cancelled.willFinish().isEmpty)
        var normal = ApplicationLaunchLifecycle()
        precondition(normal.authorize().isEmpty)
        precondition(normal.willFinish() == [.migrate])
        precondition(normal.didFinish() == [.setup])
        precondition(normal.didFinish().isEmpty, "late callbacks cannot start input listeners twice")
        var late = ApplicationLaunchLifecycle()
        precondition(late.willFinish().isEmpty)
        precondition(late.authorize() == [.migrate] && late.didFinish() == [.setup])
        var requests = 0, waits = 0
        var now: TimeInterval = 0
        func quit(request: () -> Bool, terminated: () -> Bool) -> ApplicationLaunchPolicy.ExitResult {
            ApplicationLaunchPolicy.requestExit(timeout: 1, request: { requests += 1; return request() },
                isTerminated: terminated, now: { now }, waitStep: { waits += 1; now += 0.5 })
        }
        precondition(quit(request: { false }, terminated: { false }) == .refused)
        precondition(requests == 1 && waits == 0)
        precondition(quit(request: { true }, terminated: { false }) == .timedOut)
        precondition(requests == 2 && waits == 2, "timeout never escalates or repeats quit")
        precondition(quit(request: { true }, terminated: { true }) == .exited && requests == 2)
        precondition(quit(request: { true }, terminated: { waits > 2 }) == .exited && requests == 3)
        print("PASS: deterministic launch arbitration, authorization before setup, lifecycle reentrancy and normal quit refusal/timeout")
    }
}
