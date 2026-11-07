//
//  NativeMenuBarSnapshot.swift
//  FloeBar
//

import CoreGraphics

/// A return to the same display must not resurrect work from a previous visit.
struct NativeMenuBarDisplaySession {
    private(set) var displayID: CGDirectDisplayID?
    private(set) var generation: UInt64 = 0

    /// A backend change cancels endpoint authority even on the same display.
    mutating func invalidate() { generation &+= 1 }

    mutating func select(_ displayID: CGDirectDisplayID?) -> Bool {
        guard self.displayID != displayID else { return false }
        self.displayID = displayID
        generation &+= 1
        return true
    }
}

/// Select one display before resolving duplicate hosted presentations.
enum NativeMenuBarSnapshot {
    struct Candidate {
        let semanticIdentity: String
        let objectIdentity: String
        let frame: CGRect
        let isOwnedControl: Bool
    }

    static func indices(in candidates: [Candidate], display: CGRect) -> [Int] {
        let strip = CGRect(x: display.minX, y: display.minY, width: display.width, height: 40)
        let indices = candidates.indices.filter {
            let frame = candidates[$0].frame
            return frame.width > 0 && frame.height > 0 && strip.contains(frame)
        }
        let groups = Dictionary(grouping: indices) { candidates[$0].semanticIdentity }
        return groups.values.compactMap { group in
            guard let first = group.first else { return nil }
            let reference = candidates[first]
            guard group.allSatisfy({
                let candidate = candidates[$0]
                return candidate.frame == reference.frame &&
                    (candidate.objectIdentity == reference.objectIdentity ||
                        (candidate.isOwnedControl && reference.isOwnedControl))
            }) else { return nil }
            // Ambiguous identities are not numbered from their position.
            return first
        }.sorted { candidates[$0].frame.minX < candidates[$1].frame.minX }
    }
}
