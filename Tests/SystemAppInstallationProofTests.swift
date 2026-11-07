import Foundation

final class ProofCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var active = 0
    private var maximum = 0
    private var completed = 0
    func begin() -> Int { lock.lock(); defer { lock.unlock() }; calls += 1; active += 1; maximum = max(maximum, active); return calls }
    func end() { lock.lock(); defer { lock.unlock() }; active -= 1; completed += 1 }
    var counts: (Int, Int, Int) { lock.lock(); defer { lock.unlock() }; return (calls, maximum, completed) }
}

@main
struct SystemAppInstallationProofTests {
    typealias P = SystemAppInstallationProof
    typealias G = SystemAppVisibilityGroup
    @MainActor
    static func main() async throws {
        // These are the production timing decisions, independent of scheduler
        // sleeps: queue time counts, and result age has its own equal budget.
        precondition(P.completionBudget(queued: 0, finished: 8, consumed: 13, budget: 12) == .consumedLate)
        precondition(P.completionBudget(queued: 0, finished: 1, consumed: 13.1, budget: 12) == .agedOut)
        precondition(P.completionBudget(queued: 0, finished: 12.1, consumed: 12.2, budget: 12) == .workerLate)
        precondition(P.completionBudget(queued: 3, finished: 15, consumed: 27, budget: 12) == .consumedLate)
        precondition(P.completionBudget(queued: 0, finished: 12, consumed: 12, budget: 12) == .accepted)
        precondition(P.completionBudget(queued: 0, finished: 13, consumed: 13, budget: 12) == .workerLate)
        let descriptor = G.Descriptor(root: "io.root.app", members: ["io.root.app", "io.root.helper"])
        let binding = G.InstallationBinding(root: descriptor.root, rootPath: "/Applications/Root.app", members: [G.Member(bundle: descriptor.root, relativeBundlePath: ""), G.Member(bundle: "io.root.helper", relativeBundlePath: "Contents/SharedSupport/Helper.app")], signerDigest: Data(repeating: 1, count: 32), team: "TESTTEAM")
        let request = P.Request(descriptor: descriptor, rootPath: binding.rootPath, memberPaths: [descriptor.root: binding.rootPath, "io.root.helper": binding.rootPath + "/Contents/SharedSupport/Helper.app"], expected: binding)
        precondition(request.memberPaths["io.root.helper"] == "/Applications/Root.app/Contents/SharedSupport/Helper.app")
        for path in ["/Applications/Outside.app", "Contents/../Outside.app", "Contents//Helper.app", "Contents/Helper.app/../Sibling.app"] { precondition(!P.validRelativePath(path)) }
        let service = P(inspect: { request, _, _ in
            Thread.sleep(forTimeInterval: 0.1)
            return P.Receipt(binding: request.expected!, stamp: "test")
        })
        var heartbeat = 0
        let pulse = Task { @MainActor in
            while !Task.isCancelled { heartbeat += 1; try? await Task.sleep(for: .milliseconds(5)) }
        }
        let verified = try await service.verify(request, fresh: true)
        pulse.cancel()
        precondition(verified == binding && heartbeat > 2, "installation signature work must not block the main actor")
        let timeout = P(deadline: 0.06, inspect: { request, _, _ in
            Thread.sleep(forTimeInterval: 0.1)
            return P.Receipt(binding: request.expected!, stamp: "late")
        })
        do { _ = try await timeout.verify(request, fresh: true); preconditionFailure() } catch P.Failure.deadline {} catch { preconditionFailure() }
        // A late completed timeout is discarded before lookup: one new call,
        // rather than a third user attempt, starts a genuinely fresh proof.
        let lateCount = ProofCounter()
        let late = P(deadline: 0.06, inspect: { request, _, _ in
            let call = lateCount.begin(); defer { lateCount.end() }
            Thread.sleep(forTimeInterval: call == 1 ? 0.15 : 0.001)
            return P.Receipt(binding: request.expected!, stamp: "late-retry")
        })
        do { _ = try await late.verify(request, fresh: true); preconditionFailure() } catch P.Failure.deadline {} catch { preconditionFailure() }
        do { _ = try await late.verify(request, fresh: true); preconditionFailure() } catch P.Failure.deadline {} catch { preconditionFailure() }
        precondition(lateCount.counts.0 == 1, "unfinished expired work still occupies its slot")
        let lateDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while late.unfinishedWorkerCount != 0 {
            precondition(ContinuousClock.now < lateDeadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = try await late.verify(request, fresh: true)
        precondition(lateCount.counts.0 == 2)
        // An old waiter cannot erase a newer same-key slot. Real unfinished
        // workers keep consuming the two-worker budget even across timeouts.
        let counts = ProofCounter()
        let firstGate = DispatchSemaphore(value: 0)
        let restGate = DispatchSemaphore(value: 0)
        let overlap = P(deadline: 2, inspect: { request, _, _ in
            let call = counts.begin(); defer { counts.end() }
            if call == 1 { firstGate.wait() } else { restGate.wait() }
            return P.Receipt(binding: request.expected!, stamp: "overlap")
        })
        func waitForCalls(_ target: Int) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while counts.counts.0 < target {
                precondition(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        let first = Task { try await overlap.verify(request, fresh: true) }
        try await waitForCalls(1)
        firstGate.signal()
        let overlapDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while overlap.unfinishedWorkerCount != 0 {
            precondition(ContinuousClock.now < overlapDeadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        let replacement = Task { try await overlap.verify(request, fresh: true) }
        try await waitForCalls(2)
        _ = try await first.value
        let other = P.Request(descriptor: descriptor, rootPath: "/Applications/Other.app", memberPaths: request.memberPaths, expected: binding)
        let third = Task { try await overlap.verify(other, fresh: true) }
        try await waitForCalls(3)
        let denied = P.Request(descriptor: descriptor, rootPath: "/Applications/Denied.app", memberPaths: request.memberPaths, expected: binding)
        do { _ = try await overlap.verify(denied, fresh: true); preconditionFailure() } catch P.Failure.unavailable {} catch { preconditionFailure() }
        precondition(counts.counts.1 <= 2 && overlap.unfinishedWorkerCount == 2)
        restGate.signal(); restGate.signal()
        _ = try await replacement.value
        _ = try await third.value
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/Helper.app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("Contents/Helper.app")
        try FileManager.default.createSymbolicLink(at: helper.appendingPathComponent("safe"), withDestinationURL: root.appendingPathComponent("Contents"))
        try P.validateLinks(helper, root: root)
        try FileManager.default.createSymbolicLink(at: helper.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        do { try P.validateLinks(helper, root: root); preconditionFailure() } catch P.Failure.containment {} catch { preconditionFailure() }
        print("PASS: off-main proof responsiveness, bounded late rejection, saved exact member paths and symlink containment")
    }
}
