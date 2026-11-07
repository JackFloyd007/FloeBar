//
//  NativeReorderPlan.swift
//  FloeBar
//

/// Plans merged edits against neighbors that will not subsequently move away.
enum NativeReorderPlan {
    struct Step<Tag: Hashable> {
        let source: Tag
        let anchor: Tag?
        let placingBefore: Bool
    }

    static func next<Tag: Hashable>(
        desired: [[Tag]],
        pending: Set<Tag>,
        usesPhysicalBoundaries: Bool = false
    ) -> Step<Tag>? {
        for items in desired {
            guard let index = items.lastIndex(where: { pending.contains($0) }) else { continue }
            if index + 1 < items.count {
                return Step(source: items[index], anchor: items[index + 1], placingBefore: true)
            }
            // The rightmost pending item uses a stationary left anchor, skipping
            // other pending items. The remaining moves then build to its left.
            // If every item moves, any predecessor can seed the right end;
            // all other sources are then inserted to its left. Still route the
            // seed through the normal verifier so section metadata is committed.
            // A private section must first seed against its real boundary;
            // a pending predecessor might still be in a different section.
            let anchor = items[..<index].last { !pending.contains($0) } ??
                (usesPhysicalBoundaries ? nil : items[..<index].last)
            return Step(source: items[index], anchor: anchor, placingBefore: false)
        }
        return nil
    }
}
