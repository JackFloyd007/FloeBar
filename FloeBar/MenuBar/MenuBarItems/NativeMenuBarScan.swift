//
//  NativeMenuBarScan.swift
//  FloeBar
//

import Foundation

/// Enumeration termination is distinct from an empty, authoritative snapshot.
enum NativeMenuBarScanStatus: String, Error, Sendable {
    case complete, incomplete, cancelled, budgetExceeded
}

struct NativeMenuBarScanResult<Value> {
    let value: Value
    let status: NativeMenuBarScanStatus
    var completeValue: Value? { status == .complete ? value : nil }
}

/// One monotonic deadline covers queueing, every AX read and absence rereads.
/// Cancellation cannot interrupt an AX call already in progress; its result is
/// rejected immediately afterwards and no following read is authorized.
final class NativeMenuBarScanContext: @unchecked Sendable {
    let id = UUID()
    let purpose: String
    let startedAt: TimeInterval
    let deadline: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var cancelled = false
    private var cancelledAt: TimeInterval?
    private var calls = 0
    private var longestRead: TimeInterval = 0
    private var ownerDiagnosticCount = 0

    init(purpose: String, budget: TimeInterval = 3, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.purpose = purpose
        self.now = now
        startedAt = now()
        deadline = startedAt + budget
    }

    func cancel() {
        let timestamp = now()
        lock.withLock {
            if !cancelled { cancelledAt = timestamp }
            cancelled = true
        }
    }
    var elapsed: TimeInterval { max(0, now() - startedAt) }
    var remaining: TimeInterval { max(0, deadline - now()) }
    var termination: NativeMenuBarScanStatus? {
        if lock.withLock({ cancelled }) { return .cancelled }
        return now() >= deadline ? .budgetExceeded : nil
    }

    func check() throws {
        if let termination { throw termination }
    }

    /// This is per scan read, not a global AX timeout change.
    var readTimeout: Float { Float(min(0.04, remaining)) }
    var includesSupplementaryMetadata: Bool { remaining > 0.15 }

    func recordRead(started: TimeInterval) {
        let duration = max(0, now() - started)
        lock.withLock {
            calls += 1
            longestRead = max(longestRead, duration)
        }
    }

    /// One atomic read, tested with a controllable slow reader. The timeout
    /// limits the OS request; it is not a real-time guarantee from HIServices.
    @MainActor
    func performRead<Value>(_ operation: (Float) throws -> Value) throws -> Value {
        try check()
        let timeout = readTimeout
        guard timeout > 0 else { throw NativeMenuBarScanStatus.budgetExceeded }
        try check()
        let started = timestamp()
        let value: Value
        do { value = try operation(timeout) } catch { recordRead(started: started); throw error }
        recordRead(started: started)
        try check()
        return value
    }

    func readOnMain<Value>(_ operation: @escaping @MainActor (Float) throws -> Value) async throws -> Value {
        try check()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                do { continuation.resume(returning: try self.performRead(operation)) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func reserveOwnerDiagnostic() -> Bool {
        lock.withLock {
            guard ownerDiagnosticCount < 3 else { return false }
            ownerDiagnosticCount += 1
            return true
        }
    }

    func timestamp() -> TimeInterval { now() }
    var metrics: (calls: Int, longestRead: TimeInterval, cancelDrain: TimeInterval?) {
        let timestamp = now()
        return lock.withLock { (calls, longestRead, cancelledAt.map { max(0, timestamp - $0) }) }
    }
}

/// Suspends waiters rather than blocking a thread. A cancelled/deadline-expired
/// waiter is removed without ever acquiring the scan or touching Accessibility.
actor NativeMenuBarScanGate {
    private struct Waiter {
        let context: NativeMenuBarScanContext
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var active: UUID?
    private var waiters = [Waiter]()

    func acquire(_ context: NativeMenuBarScanContext) async -> Bool {
        guard context.termination == nil else { return false }
        if active == nil {
            active = context.id
            return true
        }
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(context: context, continuation: continuation))
        }
    }

    func discardWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.context.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    func release(_ id: UUID) {
        guard active == id else { return }
        active = nil
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            guard next.context.termination == nil else {
                next.continuation.resume(returning: false)
                continue
            }
            active = next.context.id
            next.continuation.resume(returning: true)
            return
        }
    }
}

/// A discovery can finish despite an unrelated app lacking AX support. A
/// transaction/capture must confirm every required live owner, including guards.
enum NativeMenuBarScanCompletion {
    static func status(required: Set<Int32>, confirmed: Set<Int32>, terminal: NativeMenuBarScanStatus) -> NativeMenuBarScanStatus {
        guard terminal == .complete else { return terminal }
        return required.isSubset(of: confirmed) ? .complete : .incomplete
    }
}

/// A cancelled capture owner hands later-session requests to a new task instead
/// of clearing them or executing them under its old interaction generation.
struct NativeMenuBarRefreshQueue<Element: Hashable> {
    private(set) var isRunning = false
    private(set) var pending = Set<Element>()

    mutating func request(_ elements: Set<Element>) -> Bool {
        pending.formUnion(elements)
        guard !isRunning, !pending.isEmpty else { return false }
        isRunning = true
        return true
    }

    mutating func takePending() -> Set<Element> {
        let result = pending
        pending.removeAll()
        return result
    }

    mutating func cancelPending() { pending.removeAll() }

    mutating func finish() -> Set<Element> {
        isRunning = false
        return takePending()
    }
}
