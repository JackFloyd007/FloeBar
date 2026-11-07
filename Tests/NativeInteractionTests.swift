import CoreGraphics
import Foundation

@main
enum NativeInteractionTests {
    final class Node {
        let pid: Int32
        var frame: CGRect
        var parent: Node?
        init(_ frame: CGRect, pid: Int32 = 10, parent: Node? = nil) {
            self.pid = pid; self.frame = frame; self.parent = parent
        }
    }

    static func main() {
        let frame = CGRect(x: 100, y: 0, width: 20, height: 24)
        let source = Node(frame)
        func matches(_ hit: Node?, expected: Node? = nil) -> Bool {
            NativeMenuBarInteraction.matchesHit(
                expected: expected ?? source, hit: hit, expectedPID: 10, expectedFrame: frame,
                parent: { $0.parent }, pid: { $0.pid }, frame: { $0.frame }, equals: { $0 === $1 }
            )
        }
        precondition(matches(source))
        precondition(matches(Node(frame, parent: source)))
        precondition(!matches(Node(frame)), "same PID and same frame do not identify the requested AX object")
        precondition(!matches(Node(frame, pid: 11, parent: source)))
        precondition(!matches(nil))
        source.frame.origin.x += 1
        precondition(!matches(source), "a stale frame must fail even for the same object")
        source.frame = frame
        let deep = Node(frame, parent: Node(frame, parent: Node(frame, parent: Node(frame, parent: source))))
        precondition(!matches(deep), "ancestor traversal must stay bounded")
        for flag: CGEventFlags in [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn] {
            precondition(!NativeMenuBarInteraction.canStartDrag(buttonsDown: false, flags: flag))
        }
        precondition(!NativeMenuBarInteraction.canStartDrag(buttonsDown: true, flags: []))
        precondition(NativeMenuBarInteraction.canStartDrag(buttonsDown: false, flags: .maskAlphaShift))

        precondition(NativeMenuBarInteraction.inputIsQuiet(buttonsDown: false, flags: .maskAlphaShift, recentlyMoved: false, recentlyScrolled: false))
        precondition(!NativeMenuBarInteraction.inputIsQuiet(buttonsDown: false, flags: .maskCommand, recentlyMoved: false, recentlyScrolled: false))
        precondition(!NativeMenuBarInteraction.inputIsQuiet(buttonsDown: false, flags: [], recentlyMoved: true, recentlyScrolled: false))
        precondition(!NativeMenuBarInteraction.inputIsQuiet(buttonsDown: false, flags: [], recentlyMoved: false, recentlyScrolled: true))
        precondition(NativeMenuBarInteraction.inputIsQuiet(buttonsDown: false, flags: [], recentlyMoved: false, recentlyScrolled: false))

        var registry = MacOS27RuntimeItemRegistry<Node>(capacity: 1)
        let token = registry.identity(for: source, owner: "10:launch1", now: 0, equals: { $0 === $1 })
        precondition(registry.element(for: token) === source)
        _ = registry.identity(for: Node(frame), owner: "10:launch2", now: 1, equals: { $0 === $1 })
        precondition(registry.element(for: token) == nil, "evicted identities cannot authorize input")
        registry.removeUnavailableOwners([])
        precondition(registry.count == 0)

        typealias Candidate = NativeMenuBarSnapshot.Candidate
        func candidate(_ key: String, _ object: String, x: CGFloat, y: CGFloat = 0, own: Bool = false) -> Candidate {
            Candidate(semanticIdentity: key, objectIdentity: object, frame: CGRect(x: x, y: y, width: 20, height: 24), isOwnedControl: own)
        }
        let left = CGRect(x: -1000, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let above = CGRect(x: 0, y: -800, width: 1000, height: 800)
        let all = [candidate("a", "1", x: -200), candidate("a", "2", x: 100), candidate("a", "3", x: 100, y: -800), candidate("overflow", "4", x: 200, y: 50)]
        precondition(NativeMenuBarSnapshot.indices(in: all, display: left) == [0])
        precondition(NativeMenuBarSnapshot.indices(in: all, display: right) == [1])
        precondition(NativeMenuBarSnapshot.indices(in: all, display: above) == [2])
        let ambiguous = [candidate("same", "owner1", x: 100), candidate("same", "owner2", x: 130)]
        precondition(NativeMenuBarSnapshot.indices(in: ambiguous, display: right).isEmpty)
        precondition(NativeMenuBarSnapshot.indices(in: ambiguous.reversed(), display: right).isEmpty)
        precondition(NativeMenuBarSnapshot.indices(in: [all[1], all[1]], display: right) == [0])
        let coincident = [candidate("same", "1", x: 100), candidate("same", "2", x: 100)]
        precondition(NativeMenuBarSnapshot.indices(in: coincident, display: right).isEmpty)
        let owned = [candidate("own", "1", x: 100, own: true), candidate("own", "2", x: 100, own: true)]
        precondition(NativeMenuBarSnapshot.indices(in: owned, display: right) == [0])
        var session = NativeMenuBarDisplaySession()
        precondition(session.select(1))
        let original = session.generation
        precondition(!session.select(1) && session.generation == original)
        precondition(session.select(2) && session.select(1))
        precondition(session.generation != original, "A-B-A cannot revive old work")
        let beforeModeChange = session.generation
        session.invalidate()
        precondition(session.displayID == 1 && session.generation != beforeModeChange,
            "backend change invalidates in-flight endpoint authority on the same display")
        precondition(session.select(nil))
        print("PASS: native identity, stale geometry, physical input, duplicate items and multi-display sessions")
    }
}
