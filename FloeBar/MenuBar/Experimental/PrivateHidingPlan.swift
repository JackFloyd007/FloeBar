//
//  PrivateHidingPlan.swift
//  FloeBar
//

import Foundation

/// Refuse partial-app selections and shared system hosts rather than broaden hiding.
enum PrivateHidingPlan {
    static func supports(bundle: String?, own: String) -> Bool {
        guard let bundle else { return false }
        return !bundle.isEmpty && !bundle.hasPrefix("com.apple.") && bundle != own
    }

    static func targets(hidden: [String?], visible: [String?], own: String) -> Set<String>? {
        guard hidden.allSatisfy({ $0 != nil }) else { return nil }
        let targets = Set(hidden.compactMap { $0 })
        guard targets.allSatisfy({ supports(bundle: $0, own: own) }),
              targets.isDisjoint(with: Set(visible.compactMap { $0 })) else { return nil }
        return targets
    }
}
