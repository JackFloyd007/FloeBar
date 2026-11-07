import AppKit

final class MemoryDefaults: UserDefaults {
    var values: [String: Any] = [:]
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@main
enum DisplayLayoutTests {
    @MainActor static func main() throws {
        for tag in [MenuBarItemTag.clock, .controlCenter] {
            let duplicate = MenuBarItemTag(namespace: tag.namespace, title: tag.title, instanceIndex: 3)
            precondition(!duplicate.isMovable && !duplicate.canBeHidden)
        }
        let privateIndicator = MenuBarItemTag(namespace: .uuid(UUID()), title: "AudioVideoModule", instanceIndex: 2)
        precondition(!privateIndicator.canBeHidden)

        let defaults = MemoryDefaults()
        let legacyKey = "MacOS27MenuBarController.layout.v3"
        let newKey = "MacOS27MenuBarController.displayLayouts.v1"
        let tag = MenuBarItemTag(namespace: .string("test.owner"), title: "item")
        let runtime = "test.owner:Ice.RuntimeItem.old#0"
        let legacy = try JSONSerialization.data(withJSONObject: [
            "assignments": [tag.persistentIdentifier: "hidden", runtime: "hidden"],
            "order": ["hidden", [tag.persistentIdentifier, runtime]],
        ])
        defaults.set(legacy, forKey: legacyKey)
        func controller() -> MacOS27MenuBarController {
            MacOS27MenuBarController(defaults: defaults,
                displayBounds: { CGRect(x: $0 == 1 ? 0 : -1000, y: 0, width: 1000, height: 800) },
                displayKey: { "uuid-\($0)" })
        }
        let model = controller()
        let initialInteraction = model.interactionGeneration
        precondition(model.absenceCandidates(liveItems: [], sourceItems: [], displayID: 1).isEmpty)
        precondition(model.interactionGeneration == initialInteraction, "first-display absence query cannot select/reset the display")
        let a = MenuBarItem(tag: tag, bounds: CGRect(x: 100, y: 0, width: 20, height: 24))
        let b = MenuBarItem(tag: tag, bounds: CGRect(x: -200, y: 0, width: 20, height: 24))
        var cache = model.makeCache(liveItems: [a, b], sourceItems: [a, b], displayID: 1)
        precondition(cache[.hidden] == [a], "legacy assignments import only on first display")
        let beforeSwitch = model.interactionGeneration
        precondition(model.absenceCandidates(liveItems: [a, b], sourceItems: [a, b], displayID: 2).isEmpty)
        precondition(model.interactionGeneration == beforeSwitch, "absence query cannot invalidate the scan which selected a new display")
        cache = model.makeCache(liveItems: [a, b], sourceItems: [a, b], displayID: 2)
        precondition(cache[.visible] == [b] && cache[.hidden].isEmpty, "second display starts independently")
        if #available(macOS 27.0, *) {
            model.move(item: b, to: .alwaysHidden, currentCache: cache)
        }
        cache = model.makeCache(liveItems: [a], sourceItems: [a], displayID: 1)
        precondition(cache[.hidden] == [a] && cache[.alwaysHidden].isEmpty, "switching back restores A without B snapshots")
        let restored = controller()
        let restoredB = restored.makeCache(liveItems: [b], sourceItems: [b], displayID: 2)
        if #available(macOS 27.0, *) { precondition(restoredB[.alwaysHidden] == [b]) }
        precondition(defaults.data(forKey: legacyKey) == legacy, "migration preserves the legacy data")
        let saved = String(data: defaults.data(forKey: newKey)!, encoding: .utf8)!
        precondition(!saved.contains("Ice.RuntimeItem.old"), "runtime identities cannot survive relaunch")
        try testTextInputMigration()
        try testNormalModePresentation()
        print("PASS: fixed-item protection, per-display layout persistence, legacy migration and snapshot isolation")
    }
    @MainActor static func fixture(assignments: [String: String], order: [Any]) throws -> (MemoryDefaults, MacOS27MenuBarController) {
        let defaults = MemoryDefaults()
        defaults.set(try JSONSerialization.data(withJSONObject: ["assignments": assignments, "order": order]),
            forKey: "MacOS27MenuBarController.layout.v3")
        let model = MacOS27MenuBarController(defaults: defaults,
            displayBounds: { _ in CGRect(x: 0, y: 0, width: 1000, height: 800) }, displayKey: { _ in "test-display" })
        return (defaults, model)
    }

    static func textItem(_ title: String, x: CGFloat = 100) -> MenuBarItem {
        MenuBarItem(tag: MenuBarItemTag(namespace: .textInputMenuAgent, title: title),
            bounds: CGRect(x: x, y: 0, width: 20, height: 24))
    }

    @MainActor static func savedLayout(_ defaults: MemoryDefaults) throws -> [String: Any] {
        let layouts = try JSONSerialization.jsonObject(with: defaults.data(forKey: "MacOS27MenuBarController.displayLayouts.v1")!) as! [String: [String: Any]]
        return layouts["test-display"]!
    }

    @MainActor static func savedAssignments(_ defaults: MemoryDefaults) -> [String: String] {
        try! savedLayout(defaults)["assignments"] as! [String: String]
    }

    @MainActor static func testTextInputMigration() throws {
        let a = textItem("Item-0")
        let b = textItem("Item-1", x: 140)
        let old = textItem("ABC").tag.persistentIdentifier
        let otherOld = textItem("简体拼音").tag.persistentIdentifier
        let aid = a.tag.persistentIdentifier, bid = b.tag.persistentIdentifier
        for items in [[a, b], [b, a]] {
            let (defaults, model) = try fixture(assignments: [aid: "hidden", bid: "alwaysHidden"],
                order: ["hidden", [aid], "alwaysHidden", [bid]])
            let first = model.makeCache(liveItems: items, sourceItems: items, displayID: 1)
            precondition(first[.hidden] == [a] && first[.alwaysHidden] == [b], "canonical siblings cannot overwrite each other's assignments")
            let initialSaved = defaults.data(forKey: "MacOS27MenuBarController.displayLayouts.v1")!
            _ = model.makeCache(liveItems: items.reversed(), sourceItems: items, displayID: 1)
            precondition(defaults.data(forKey: "MacOS27MenuBarController.displayLayouts.v1")! == initialSaved, "migration is idempotent")
            let assignments = try savedLayout(defaults)["assignments"] as! [String: String]
            precondition(assignments[aid] == "hidden" && assignments[bid] == "alwaysHidden")
        }
        let (singleDefaults, single) = try fixture(assignments: [old: "hidden"], order: ["hidden", [old]])
        let migrated = single.makeCache(liveItems: [a], sourceItems: [a], displayID: 1)
        precondition(migrated[.hidden] == [a], "single known old label keeps its section and position")
        let migratedAssignments = try savedLayout(singleDefaults)["assignments"] as! [String: String]
        precondition(migratedAssignments[old] == nil && migratedAssignments[aid] == "hidden")
        _ = single.makeCache(liveItems: [a], sourceItems: [a], displayID: 1)
        precondition(savedAssignments(singleDefaults) == migratedAssignments)
        for (assignments, items) in [
            ([old: "hidden", otherOld: "alwaysHidden"], [a]),
            ([old: "hidden"], [a, b]),
            ([old: "hidden", aid: "alwaysHidden"], [a]),
            ([textItem("Unknown input label").tag.persistentIdentifier: "hidden"], [a]),
        ] {
            let (defaults, model) = try fixture(assignments: assignments,
                order: ["hidden", assignments.keys.sorted()])
            _ = model.makeCache(liveItems: items, sourceItems: items, displayID: 1)
            let after = try savedLayout(defaults)["assignments"] as! [String: String]
            for (key, value) in assignments {
                precondition(after[key] == value, "ambiguous/unknown legacy preferences must remain unchanged")
            }
        }
        print("PASS: independent input-source canonical identities, idempotence, unique old label migration and ambiguity preservation")
    }

    @MainActor static func testNormalModePresentation() throws {
        let a = textItem("Item-0", x: 300)
        let b = MenuBarItem(tag: MenuBarItemTag(namespace: .string("test.hidden"), title: "item"),
            bounds: CGRect(x: 100, y: 0, width: 20, height: 24))
        let c = MenuBarItem(tag: MenuBarItemTag(namespace: .string("test.always"), title: "item"),
            bounds: CGRect(x: 200, y: 0, width: 20, height: 24))
        let ice = MenuBarItem(tag: .visibleControlItem, bounds: CGRect(x: 50, y: 0, width: 20, height: 24))
        let original = [a.tag.persistentIdentifier: "visible", b.tag.persistentIdentifier: "hidden", c.tag.persistentIdentifier: "alwaysHidden"]
        let (defaults, model) = try fixture(assignments: original,
            order: ["visible", [a.tag.persistentIdentifier], "hidden", [b.tag.persistentIdentifier], "alwaysHidden", [c.tag.persistentIdentifier]])
        let normal = model.makeCache(liveItems: [a, b, c], sourceItems: [a, b, c, ice], displayID: 1, usesSystemOverflow: true)
        precondition(normal[.visible] == [b, c, a] && normal[.hidden].isEmpty && normal[.alwaysHidden].isEmpty,
            "normal physical row contains every old section exactly once")
        precondition(savedAssignments(defaults) == original,
            "ordinary AX caching must not rewrite assignments from FloeBar geometry")
        if #available(macOS 27.0, *) {
            _ = model.move(item: b, to: .rightOfItem(a), currentCache: normal, preservingAssignment: true)
        }
        precondition(savedAssignments(defaults) == original,
            "normal cross-historical-section reorder preserves all assignments")
        var movedB = b; movedB.bounds.origin.x = 340
        let moved = [a, movedB, c]
        let actual = model.makeCache(liveItems: moved, sourceItems: moved + [ice], displayID: 1, usesSystemOverflow: true)
        precondition(actual[.visible] == [c, a, movedB], "readback follows actual bounds after reorder")
        // Real refreshes include FloeBar. Merely entering private presentation
        // must not import the normal row's geometry as new section assignments.
        let privateCache = model.makeCache(liveItems: moved, sourceItems: moved + [ice], displayID: 1)
        precondition(privateCache[.visible] == [a] && privateCache[.hidden] == [movedB] && privateCache[.alwaysHidden] == [c])
        let normalAgain = model.makeCache(liveItems: moved, sourceItems: moved + [ice], displayID: 1, usesSystemOverflow: true)
        precondition(normalAgain[.visible] == [c, a, movedB])
        precondition(savedAssignments(defaults) == original,
            "normal/private/normal presentation switching cannot lose history")
        print("PASS: full normal physical row, historical assignment preservation, cross-row reorder and mode round trip")
    }

}
