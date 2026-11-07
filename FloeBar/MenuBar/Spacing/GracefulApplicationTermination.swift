//
//  GracefulApplicationTermination.swift
//  FloeBar
//

import Foundation

/// A refusal or an unanswered save dialog must never become a forced quit.
@MainActor
enum GracefulApplicationTermination {
    enum Failure: Error {
        case refused
        case timedOut
    }

    static func terminate(
        timeout: Duration = .seconds(5),
        request: () -> Bool,
        isTerminated: () -> Bool
    ) async throws {
        try Task.checkCancellation()
        guard !isTerminated() else { return }
        guard request() else { throw Failure.refused }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !isTerminated() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
