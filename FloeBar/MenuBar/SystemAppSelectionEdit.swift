//
//  SystemAppSelectionEdit.swift
//  FloeBar
//

import Foundation

/// The choice is committed only after the owned system mutation and its fresh
/// readback. Failures never roll other applications back or replay the write.
@MainActor
enum SystemAppSelectionEdit {
    enum Failure: Error { case recoveryRequired, journalRemaining, unexpectedState }

    static func perform(
        selected: Bool,
        collapsed: Bool,
        requiresRecovery: Bool,
        target: String,
        expectedAllowed: Bool?,
        hide: () async throws -> Void,
        restoreOwned: () async throws -> Void,
        read: () async throws -> [String: Bool],
        commit: ([String: Bool]) -> Void,
        failed: () -> Void
    ) async throws {
        do {
            guard !requiresRecovery else { throw Failure.recoveryRequired }
            try Task.checkCancellation()
            if selected && collapsed { try await hide() }
            if !selected { try await restoreOwned() }
            try Task.checkCancellation()
            let states = try await read()
            if let expectedAllowed, states[target] != expectedAllowed { throw Failure.unexpectedState }
            commit(states)
        } catch {
            failed()
            throw error
        }
    }

    static func recover(
        restoreAll: () async throws -> Void,
        journalExists: () -> Bool,
        read: () async throws -> [String: Bool],
        commit: ([String: Bool]) -> Void,
        failed: () -> Void
    ) async throws {
        do {
            try await restoreAll()
            guard !journalExists() else { throw Failure.journalRemaining }
            let states = try await read()
            commit(states)
        } catch {
            failed()
            throw error
        }
    }
}
