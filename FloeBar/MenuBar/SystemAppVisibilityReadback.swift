//
//  SystemAppVisibilityReadback.swift
//  FloeBar
//

import Foundation

/// A single mutation may take time to reach the preferences file. Waiting only
/// repeats reads; it never repeats the write or blocks MainActor with sleep.
@MainActor
enum SystemAppVisibilityReadback {
    enum Failure: Error { case expired }

    static func wait(
        budget: Duration = .seconds(2),
        interval: Duration = .milliseconds(100),
        now: () -> ContinuousClock.Instant = { .now },
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        read: () throws -> Bool,
        retryable: (any Error) -> Bool
    ) async throws -> Bool {
        let deadline = now().advanced(by: budget)
        while true {
            try Task.checkCancellation()
            guard now() < deadline else { throw Failure.expired }
            do {
                let value = try read()
                try Task.checkCancellation()
                guard now() < deadline else { throw Failure.expired }
                return value
            } catch {
                guard retryable(error) else { throw error }
                let remaining = now().duration(to: deadline)
                guard remaining > .zero else { throw Failure.expired }
                try await sleep(min(interval, remaining))
            }
        }
    }
}
