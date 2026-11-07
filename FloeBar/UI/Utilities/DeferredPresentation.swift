//
//  DeferredPresentation.swift
//  FloeBar
//

import Foundation

/// Owns the entire asynchronous presentation lifecycle, including late results
/// from operations that do not cooperate with task cancellation.
@MainActor
final class DeferredPresentation {
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    var isPending: Bool { task != nil }

    func show(
        after prepare: @escaping @MainActor () async -> Void,
        present: @escaping @MainActor () -> Void
    ) {
        cancel()
        let token = generation
        task = Task { [weak self] in
            await prepare()
            guard let self, !Task.isCancelled, token == generation else { return }
            task = nil
            present()
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}
