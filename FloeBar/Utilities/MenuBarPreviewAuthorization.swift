//
//  MenuBarPreviewAuthorization.swift
//  FloeBar
//

import Foundation

/// Pixel access needs a current, explicit request. A prior grant or a previous
/// page visit does not authorize a new background capture.
@MainActor
enum MenuBarPreviewAuthorization {
    static func capture<Value>(
        userInitiated: Bool,
        isCurrent: () -> Bool,
        preflight: () -> Bool,
        operation: () async throws -> Value
    ) async rethrows -> Value? {
        guard userInitiated, !Task.isCancelled, isCurrent(), preflight() else { return nil }
        let value = try await operation()
        guard !Task.isCancelled, isCurrent() else { return nil }
        return value
    }
}

/// A view reappearing with the same State cannot replay an old button press.
struct MenuBarPreviewRequest {
    private(set) var id: UInt64 = 0
    private var consumed: UInt64 = 0
    private var session: UInt = 0

    mutating func issue(in session: UInt) {
        self.session = session
        id &+= 1
    }
    mutating func discard() { consumed = id }
    mutating func consume(in currentSession: UInt) -> Bool {
        guard id != consumed else { return false }
        consumed = id
        return session == currentSession
    }
}
