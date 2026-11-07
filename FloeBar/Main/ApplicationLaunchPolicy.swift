//
//  ApplicationLaunchPolicy.swift
//  FloeBar
//

import Foundation

/// Only the later launch arbitrates a conflict. Equal timestamps use PID as a
/// stable tie-breaker, so two copies cannot both ask to terminate each other.
enum ApplicationLaunchPolicy {
    struct Instance: Equatable {
        let pid: Int32
        let bundleIdentifier: String
        let launchedAt: Date?
    }

    static func hasUnverifiedStartOrder(current: Instance, among instances: [Instance]) -> Bool {
        let peers = instances.filter { $0.pid != current.pid && $0.bundleIdentifier == current.bundleIdentifier }
        return !peers.isEmpty && (current.launchedAt == nil || peers.contains { $0.launchedAt == nil })
    }

    static func predecessors(of current: Instance, among instances: [Instance]) -> [Instance] {
        instances.filter {
            $0.bundleIdentifier == current.bundleIdentifier && $0.pid != current.pid && precedes($0, current)
        }.sorted(by: precedes)
    }

    enum ExitResult: Equatable { case exited, refused, timedOut }

    @MainActor
    static func requestExit(
        timeout: TimeInterval = 5,
        request: () -> Bool,
        isTerminated: () -> Bool,
        now: () -> TimeInterval,
        waitStep: () -> Void
    ) -> ExitResult {
        if isTerminated() { return .exited }
        guard request() else { return .refused }
        let deadline = now() + timeout
        while !isTerminated() {
            guard now() < deadline else { return .timedOut }
            waitStep()
        }
        return .exited
    }

    private static func precedes(_ lhs: Instance, _ rhs: Instance) -> Bool {
        let left = lhs.launchedAt ?? .distantPast
        let right = rhs.launchedAt ?? .distantPast
        if left != right { return left < right }
        return lhs.pid < rhs.pid
    }
}

/// Lifecycle callbacks can arrive while a native launch alert pumps the run
/// loop. No migration/setup effect is emitted before explicit authorization.
struct ApplicationLaunchLifecycle {
    enum Effect: Equatable { case migrate, setup }
    private(set) var isAuthorized = false
    private var sawWillFinish = false
    private var sawDidFinish = false
    private var didMigrate = false
    private var didSetup = false

    mutating func authorize() -> [Effect] {
        isAuthorized = true
        return effects()
    }

    mutating func willFinish() -> [Effect] {
        sawWillFinish = true
        return effects()
    }

    mutating func didFinish() -> [Effect] {
        sawDidFinish = true
        return effects()
    }

    private mutating func effects() -> [Effect] {
        guard isAuthorized else { return [] }
        var result = [Effect]()
        if !didMigrate && (sawWillFinish || sawDidFinish) {
            didMigrate = true
            result.append(.migrate)
        }
        if !didSetup && sawDidFinish {
            didSetup = true
            result.append(.setup)
        }
        return result
    }
}
