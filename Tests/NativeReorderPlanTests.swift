@main
enum NativeReorderPlanTests {
    static func main() {
        let initial = [0, 1, 2, 3, 4]
        func verify(_ desired: [Int], pending originalPending: Set<Int>) {
            var actual = initial
            var pending = originalPending
            var moved = Set<Int>()
            while let step = NativeReorderPlan.next(desired: [desired], pending: pending) {
                precondition(pending.remove(step.source) != nil)
                precondition(moved.insert(step.source).inserted, "a source must not be replayed")
                guard let anchor = step.anchor else { continue }
                actual.removeAll { $0 == step.source }
                let index = actual.firstIndex(of: anchor)!
                actual.insert(step.source, at: index + (step.placingBefore ? 0 : 1))
            }
            precondition(pending.isEmpty && actual == desired, "merged moves must converge without a retry")
        }
        // A after B, then D after A; FIFO final-neighbor planning undid A's move.
        verify([1, 0, 3, 2, 4], pending: [0, 3])
        // A pending suffix must anchor to the stationary prefix, not each other.
        verify([2, 3, 4, 0, 1], pending: [0, 1])
        func permutations(_ values: [Int]) -> [[Int]] {
            if values.isEmpty { return [[]] }
            return values.flatMap { first in
                permutations(values.filter { $0 != first }).map { [first] + $0 }
            }
        }
        var cases = 0
        for desired in permutations(initial) {
            for mask in 0 ..< (1 << initial.count) {
                let pending = Set(initial.filter { mask & (1 << $0) != 0 })
                // User edits preserve the relative order of untouched items.
                guard initial.filter({ !pending.contains($0) }) == desired.filter({ !pending.contains($0) }) else { continue }
                verify(desired, pending: pending)
                cases += 1
            }
        }
        let independent = NativeReorderPlan.next(desired: [[0, 1], [2, 3]], pending: [0, 3])!
        precondition(independent.source == 0 && independent.anchor == 1 && independent.placingBefore)
        precondition(NativeReorderPlan.next(desired: [[0, 1]], pending: Set<Int>()) == nil)
        let privateSeed = NativeReorderPlan.next(desired: [[0, 1]], pending: [0, 1], usesPhysicalBoundaries: true)!
        precondition(privateSeed.source == 1 && privateSeed.anchor == nil, "private empty section must seed at its actual boundary")
        let afterSeed = NativeReorderPlan.next(desired: [[0, 1]], pending: [0], usesPhysicalBoundaries: true)!
        precondition(afterSeed.source == 0 && afterSeed.anchor == 1 && afterSeed.placingBefore)
        print("PASS: \(cases) merged-order permutations, stable suffix anchors and one move per source")
    }
}
