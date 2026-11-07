//
//  NativeMenuBarInteraction.swift
//  FloeBar
//

import CoreGraphics

/// Input authorization uses object equality, never a shared process or label.
enum NativeMenuBarInteraction {
    static func matchesHit<Element>(
        expected: Element?,
        hit: Element?,
        expectedPID: Int32,
        expectedFrame: CGRect,
        parent: (Element) -> Element?,
        pid: (Element) -> Int32?,
        frame: (Element) -> CGRect?,
        equals: (Element, Element) -> Bool
    ) -> Bool {
        guard let expected, frame(expected) == expectedFrame,
            expectedFrame.width > 0, expectedFrame.height > 0 else { return false }
        var candidate = hit
        for _ in 0..<4 {
            guard let element = candidate, pid(element) == expectedPID else { return false }
            if equals(expected, element) { return true }
            candidate = parent(element)
        }
        return false
    }

    static func inputIsQuiet(buttonsDown: Bool, flags: CGEventFlags, recentlyMoved: Bool, recentlyScrolled: Bool) -> Bool {
        canStartDrag(buttonsDown: buttonsDown, flags: flags) && !recentlyMoved && !recentlyScrolled
    }

    static func canStartDrag(buttonsDown: Bool, flags: CGEventFlags) -> Bool {
        !buttonsDown && flags.isDisjoint(with: [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn])
    }
}
