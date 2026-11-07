//
//  NativeReorderVerification.swift
//  FloeBar
//

/// Verifies the requested real-item order without requiring unrelated handles.
enum NativeReorderVerification {
    enum Side { case before, after }

    struct Section<Tag: Hashable> {
        let items: [Tag]
        let boundary: Tag?
        let side: Side
    }

    enum Result<Tag: Hashable>: Equatable {
        case converged
        case incomplete
        case needsMove(Tag)
    }

    /// Even an already-correct ordinal result needs fresh visible endpoints.
    static func confirmedEndpointOrder(
        sourceHit: Bool,
        targetHit: Bool,
        alreadyOrdered: Bool,
        sourceOwned: @autoclosure () -> Bool = false,
        targetOwned: @autoclosure () -> Bool = false
    ) throws -> Bool {
        guard sourceHit, targetHit else {
            if (!sourceHit && sourceOwned()) || (!targetHit && targetOwned()) { throw NativeReorderFailure.applicationHidden }
            throw NativeReorderFailure.endpointUnavailable
        }
        return alreadyOrdered
    }

    static func evaluate<Tag: Hashable>(
        sections: [Section<Tag>],
        touched: Set<Tag>,
        live: [Tag],
        enforceSectionOrder: Bool = true
    ) -> Result<Tag> {
        let desired = sections.flatMap(\.items).filter { touched.contains($0) }
        guard !desired.isEmpty else { return .converged }
        let desiredSet = Set(desired)
        let observed = live.filter { desiredSet.contains($0) }
        guard desired.count == desiredSet.count, Set(observed) == desiredSet,
            observed.count == desired.count else { return .incomplete }
        // In system-overflow mode, saved rows can physically interleave.
        // Verify each requested row without inventing a cross-row partition.
        let orders = enforceSectionOrder ? [desired] : sections.map { $0.items.filter { touched.contains($0) } }
        for order in orders {
            let tags = Set(order)
            let actual = observed.filter { tags.contains($0) }
            for index in order.indices where order[index] != actual[index] {
                return .needsMove(order[index])
            }
        }
        for section in sections {
            let items = section.items.filter { touched.contains($0) }
            guard !items.isEmpty, let boundary = section.boundary else { continue }
            guard let boundaryIndex = live.firstIndex(of: boundary) else { return .incomplete }
            for item in items {
                guard let index = live.firstIndex(of: item) else { return .incomplete }
                let correct = section.side == .before ? index < boundaryIndex : index > boundaryIndex
                if !correct { return .needsMove(item) }
            }
        }
        return .converged
    }
}

/// Reasons survive the native gesture boundary; none authorize replay.
enum NativeReorderFailure: Error, Equatable {
    case inputInterrupted
    case displayChanged
    case modeChanged
    case visibilityChanging
    case endpointUnavailable
    case applicationHidden
    case verificationUnconfirmed
    case eventDeliveryFailed
}

/// Published only for the current edit after its actual-order readback.
enum NativeReorderFeedback: Equatable {
    case idle
    case arranging
    case readingActualOrder
    case confirmed
    case stopped(NativeReorderFailure)
    case readbackUnavailable(NativeReorderFailure)
    case expandingOverflow
    case overflowExpanded
    case overflowExpansionFailed
}

/// A final message requires this edit's completed actual-order readback.
/// Late completion from an older edit cannot replace a newer progress/result.
struct NativeReorderFeedbackState {
    private(set) var generation: UInt64 = 0
    private(set) var phase = NativeReorderFeedback.idle
    private var overflowExpansionID: UInt64 = 0

    mutating func begin(generation: UInt64) {
        guard generation >= self.generation else { return }
        self.generation = generation
        phase = .arranging
    }

    mutating func beginReadback(generation: UInt64) {
        guard generation >= self.generation else { return }
        self.generation = generation
        phase = .readingActualOrder
    }

    mutating func finishReadback(generation: UInt64, failure: NativeReorderFailure? = nil, succeeded: Bool = true) {
        guard generation == self.generation, phase == .readingActualOrder else { return }
        guard succeeded else {
            phase = .readbackUnavailable(failure ?? .verificationUnconfirmed)
            return
        }
        phase = failure.map { .stopped($0) } ?? .confirmed
    }

    mutating func beginOverflowExpansion(generation: UInt64) -> UInt64? {
        guard generation == self.generation else { return nil }
        switch phase {
        case .stopped(.endpointUnavailable), .readbackUnavailable(.endpointUnavailable), .overflowExpansionFailed:
            overflowExpansionID &+= 1
            phase = .expandingOverflow
            return overflowExpansionID
        default:
            return nil
        }
    }

    mutating func cancelOverflowExpansion(generation: UInt64, token: UInt64? = nil) {
        guard generation == self.generation, phase == .expandingOverflow,
            token == nil || token == overflowExpansionID else { return }
        overflowExpansionID &+= 1
        phase = .stopped(.endpointUnavailable)
    }

    mutating func finishOverflowExpansion(generation: UInt64, token: UInt64, succeeded: Bool) {
        guard generation == self.generation, token == overflowExpansionID, phase == .expandingOverflow else { return }
        phase = succeeded ? .overflowExpanded : .overflowExpansionFailed
    }

    /// Refreshing reads the list only. Invalidate this failure's recovery token
    /// without discarding a newer edit or keeping any old move destination.
    mutating func prepareOverflowFailureRefresh(generation: UInt64) -> Bool {
        guard generation == self.generation, phase == .overflowExpansionFailed else { return false }
        overflowExpansionID &+= 1
        phase = .idle
        return true
    }

    mutating func reset(generation: UInt64) {
        guard generation >= self.generation else { return }
        self.generation = generation
        phase = .idle
    }
}
