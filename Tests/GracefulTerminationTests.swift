import Foundation

@main
enum GracefulTerminationTests {
    @MainActor static func main() async throws {
        var requests = 0
        try await GracefulApplicationTermination.terminate(request: { requests += 1; return true }, isTerminated: { true })
        precondition(requests == 0)
        do {
            try await GracefulApplicationTermination.terminate(request: { requests += 1; return false }, isTerminated: { false })
            preconditionFailure("refusal must propagate")
        } catch GracefulApplicationTermination.Failure.refused { }
        precondition(requests == 1)
        do {
            try await GracefulApplicationTermination.terminate(timeout: .zero, request: { requests += 1; return true }, isTerminated: { false })
            preconditionFailure("an unanswered save dialog must time out")
        } catch GracefulApplicationTermination.Failure.timedOut { }
        precondition(requests == 2, "timeout cannot escalate the termination request")
        var terminated = false
        try await GracefulApplicationTermination.terminate(request: { terminated = true; return true }, isTerminated: { terminated })
        let task = Task { @MainActor in
            try await GracefulApplicationTermination.terminate(request: { requests += 1; return true }, isTerminated: { false })
        }
        task.cancel()
        do { try await task.value; preconditionFailure("cancelled tasks cannot terminate an app") }
        catch is CancellationError { }
        precondition(requests == 2)
        print("PASS: graceful termination, refusal, timeout, already-exited and cancellation paths")
    }
}
