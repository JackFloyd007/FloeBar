import Foundation

@main
struct SystemAppVisibilityReadbackTests {
    enum Failure: Error { case transient, permanent }

    @MainActor
    static func main() async throws {
        var instant = ContinuousClock.now
        var reads = 0
        var pauses = 0
        let observed = try await SystemAppVisibilityReadback.wait(now: { instant }, sleep: { duration in
            pauses += 1
            instant = instant.advanced(by: duration)
            await Task.yield()
        }, read: {
            reads += 1
            if reads < 3 { throw Failure.transient }
            return false // A confirmed hidden value is a valid result.
        }, retryable: { ($0 as? Failure) == .transient })
        precondition(!observed && reads == 3 && pauses == 2)

        reads = 0
        instant = .now
        do {
            _ = try await SystemAppVisibilityReadback.wait(budget: .milliseconds(200), now: { instant }, sleep: { duration in
                instant = instant.advanced(by: duration)
            }, read: { reads += 1; throw Failure.transient }, retryable: { _ in true })
            preconditionFailure("Unbounded readback accepted")
        } catch is SystemAppVisibilityReadback.Failure {}
        precondition(reads == 2)

        instant = .now
        do {
            _ = try await SystemAppVisibilityReadback.wait(budget: .milliseconds(100), now: { instant }, read: {
                instant = instant.advanced(by: .milliseconds(101))
                return true
            }, retryable: { _ in false })
            preconditionFailure("Late result accepted")
        } catch is SystemAppVisibilityReadback.Failure {}

        reads = 0
        let cancelled = Task { @MainActor in
            try await SystemAppVisibilityReadback.wait(sleep: { _ in try await Task.sleep(for: .seconds(10)) }, read: {
                reads += 1
                throw Failure.transient
            }, retryable: { _ in true })
        }
        while reads == 0 { await Task.yield() }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancellation ignored") } catch is CancellationError {}
        precondition(reads == 1)

        reads = 0
        pauses = 0
        do {
            _ = try await SystemAppVisibilityReadback.wait(sleep: { _ in pauses += 1 }, read: {
                reads += 1
                throw Failure.permanent
            }, retryable: { ($0 as? Failure) == .transient })
            preconditionFailure("Permanent validation error retried")
        } catch is Failure {}
        precondition(reads == 1 && pauses == 0)

        // Production journal transaction: one write, then asynchronous reads;
        // clearing cannot happen before the owned value has been confirmed.
        typealias M = SystemAppVisibilityModel
        let bundle = "com.figma.Desktop"
        let key: [String: Any] = ["bundle": ["_0": bundle]]
        let original: [String: Any] = ["isAllowed": true, "location": key, "menuItemLocations": [key]]
        let initial = try M.record(in: [key, original], bundle: bundle, own: "own.bundle")
        let journal = try M.hideJournal(record: initial, bundle: bundle)
        var hidden = original
        hidden["isAllowed"] = false
        let current = try M.record(in: [key, hidden], bundle: bundle, own: "own.bundle")
        var writes = 0
        var clears = 0
        reads = 0
        instant = .now
        let restored = try await M.restore(journal: journal, current: current, write: { _, _ in
            writes += 1
            return try await SystemAppVisibilityReadback.wait(now: { instant }, sleep: { duration in
                precondition(clears == 0)
                instant = instant.advanced(by: duration)
                await Task.yield()
            }, read: {
                precondition(clears == 0)
                reads += 1
                if reads == 1 { throw Failure.transient }
                return true
            }, retryable: { ($0 as? Failure) == .transient })
        }, clear: { clears += 1 })
        precondition(restored && writes == 1 && reads == 2 && clears == 1)
        clears = 0
        do {
            _ = try await M.restore(journal: journal, current: current, write: { _, _ in throw CancellationError() }, clear: { clears += 1 })
            preconditionFailure("Cancelled recovery cleared journal")
        } catch is CancellationError {}
        precondition(clears == 0)
        print("PASS: async readback yields, deadline/cancel reject late reads, one write and journal clears only after confirmation")
    }
}
