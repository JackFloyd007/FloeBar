import Foundation

@main
struct SystemAppVisibilityModelTests {
    typealias M = SystemAppVisibilityModel
    enum FixtureError: Error { case persist, write }
    static let target = "com.figma.Desktop"
    static let own = "io.github.jackfloyd007.IceEric"
    static var key: [String: Any] { ["bundle": ["_0": target]] }
    static func value(allowed: Any = true, revision: Int = 1) -> [String: Any] {
        ["isAllowed": allowed, "location": key, "menuItemLocations": [key], "unknown": ["revision": revision]]
    }
    @MainActor
    static func main() async throws {
        let original = value()
        let input: [Any] = [["unknown-kind": "preserved"], ["foreign": [1, 2]], key, original]
        let current = try M.record(in: input, bundle: target, own: own)
        var events = [String]()
        var saved: M.Journal?
        _ = try await M.hide(record: current, bundle: target, persist: { journal in
            events.append("persist"); saved = journal
        }, write: { hidden, expected in
            events.append("write")
            let expectedAllowed = try M.allowed(in: expected)
            let hiddenAllowed = try M.allowed(in: hidden)
            precondition(expectedAllowed && !hiddenAllowed)
            return false
        })
        precondition(events == ["persist", "write"])
        let journal = saved!
        var writes = 0
        do {
            _ = try await M.hide(record: current, bundle: target, persist: { _ in throw FixtureError.persist }, write: { _, _ in writes += 1; return false })
            preconditionFailure("Persistence failure accepted")
        } catch {}
        precondition(writes == 0)
        var persisted = false
        do {
            _ = try await M.hide(record: current, bundle: target, persist: { _ in persisted = true }, write: { _, _ in throw FixtureError.write })
            preconditionFailure("Write failure accepted")
        } catch {}
        precondition(persisted)
        // System metadata changes after hide are retained through recovery.
        let metadataChanged = value(allowed: false, revision: 2)
        let hiddenRecord = try M.record(in: [key, metadataChanged], bundle: target, own: own)
        var restoredArray: [Any] = []
        var cleared = false
        _ = try await M.restore(journal: journal, current: hiddenRecord, write: { restored, expected in
            let data = try M.replacing(in: input.dropLast().map { $0 } + [metadataChanged], bundle: target, own: own, expected: expected, value: restored)
            restoredArray = try M.decode(data)
            return true
        }, clear: { cleared = true })
        precondition(cleared)
        let restored = try M.record(in: restoredArray, bundle: target, own: own)
        precondition(restored.allowed)
        precondition((restored.value["unknown"] as? [String: Int])?["revision"] == 2)
        precondition(NSDictionary(dictionary: restoredArray[1] as! [String: Any]).isEqual(to: input[1] as! [String: Any]))
        // Changes between journal persistence and the fresh write survive too.
        let fresh = value(revision: 3)
        let updated = try M.replacing(in: [key, fresh], bundle: target, own: own, expected: original, value: M.dictionary(journal.lastWritten))
        let freshHidden = try M.record(in: M.decode(updated), bundle: target, own: own)
        precondition(!freshHidden.allowed && (freshHidden.value["unknown"] as? [String: Int])?["revision"] == 3)
        writes = 0
        _ = try await M.restore(journal: journal, current: M.record(in: [key, value(revision: 4)], bundle: target, own: own), write: { _, _ in writes += 1; return true }, clear: {})
        precondition(writes == 0) // User already restored the owned field.
        cleared = false
        do {
            _ = try await M.restore(journal: journal, current: hiddenRecord, write: { _, _ in throw FixtureError.write }, clear: { cleared = true })
            preconditionFailure("Failed restoration cleared journal")
        } catch {}
        precondition(!cleared)
        for bundle in [own, "com.apple.controlcenter", "unknown"] {
            precondition(!M.eligible(bundle, own: own))
        }
        for invalid in [value(allowed: NSNumber(value: 1)), ["location": key], value(allowed: "true")] {
            do { _ = try M.record(in: [key, invalid], bundle: target, own: own); preconditionFailure("Invalid Bool accepted") } catch {}
        }
        var mixed = original
        mixed["menuItemLocations"] = [["bundle": ["_0": "org.other.app"]]]
        do { _ = try M.record(in: [key, mixed], bundle: target, own: own); preconditionFailure("Mixed app locations accepted") } catch {}
        mixed["menuItemLocations"] = [["unknown": "shape"]]
        do { _ = try M.record(in: [key, mixed], bundle: target, own: own); preconditionFailure("Unverified location accepted") } catch {}
        do { _ = try M.record(in: [key, original, key, original], bundle: target, own: own); preconditionFailure("Duplicate target accepted") } catch {}
        let otherKey: [String: Any] = ["bundle": ["_0": "org.other.app"]]
        let daemon: [Any] = [otherKey, ["unknown": "fresh"], key, value(allowed: false, revision: 10)]
        let disk: [Any] = [key, value(allowed: false, revision: 8)]
        let confirmed = try M.ownedReadback(daemon: daemon, disk: disk, bundle: target, own: own)
        precondition(!confirmed.record.allowed && (confirmed.record.value["unknown"] as? [String: Int])?["revision"] == 10)
        precondition(confirmed.diskSnapshotMatchesOwnedValue)
        let staleDisk = try M.ownedReadback(daemon: daemon, disk: [key, original], bundle: target, own: own)
        precondition(!staleDisk.record.allowed && !staleDisk.diskSnapshotMatchesOwnedValue)
        // Even when stale, disk identity/ownership is still checked; a foreign
        // location is not accepted as another copy of the authorized target.
        var foreignDisk = original
        foreignDisk["location"] = otherKey
        do {
            _ = try M.ownedReadback(daemon: daemon, disk: [key, foreignDisk], bundle: target, own: own)
            preconditionFailure("Foreign disk identity accepted")
        } catch {}
        var other = value()
        other["location"] = otherKey
        other["menuItemLocations"] = [key]
        let references = M.referencingParents(in: [key, original, otherKey, other], target: target)
        precondition(references.count == 2 && references.contains { $0.contains("org.other.app") })
        let diagnostic = M.targetDiagnostics(in: [key, original], bundle: target).joined()
        precondition(diagnostic.contains("allowed=true") && diagnostic.contains("menuItemLocations=[bundle(com.figma.Desktop)]"))
        let second = "org.other.app"
        let secondValue: [String: Any] = ["isAllowed": true, "location": otherKey, "menuItemLocations": [otherKey]]
        let secondRecord = try M.record(in: [otherKey, secondValue], bundle: second, own: own)
        let secondJournal = try M.hideJournal(record: secondRecord, bundle: second)
        let encoder = PropertyListEncoder()
        let legacy = try M.journals(from: encoder.encode(journal), own: own)
        precondition(legacy.count == 1 && legacy[0].bundle == target)
        let batch = try M.journals(from: encoder.encode(M.JournalSet(version: 2, entries: [journal, secondJournal])), own: own)
        precondition(batch.map(\.bundle) == [target, second])
        for invalid in [M.JournalSet(version: 2, entries: [journal, journal]), M.JournalSet(version: 99, entries: batch)] {
            do { _ = try M.journals(from: encoder.encode(invalid), own: own); preconditionFailure("Invalid journal set accepted") } catch {}
        }
        precondition(M.manageableSelection([target, second, "org.stopped.app"], available: [target: true, second: false]) == [target])
        precondition(M.manageableSelection([], available: [target: true]).isEmpty)
        precondition(M.manageableSelection([second], available: [target: true, second: false]).isEmpty)
        let catalog: [Any] = [key, original, otherKey, secondValue]
        precondition(M.candidates(daemon: catalog, disk: catalog, own: own) == [target, second].sorted())
        precondition(M.candidates(daemon: catalog + [key, original], disk: catalog, own: own) == [second])
        precondition(M.candidates(daemon: catalog, disk: [otherKey, secondValue], own: own) == [second])
        let mixedCatalog: [Any] = [key, foreignDisk, otherKey, secondValue]
        precondition(M.candidates(daemon: mixedCatalog, disk: catalog, own: own) == [second])
        // Partial recovery retains its failed entry and still restores the next
        // app, preserving fresh per-target and unrelated metadata throughout.
        var pending = batch
        var attempted = [String]()
        for entry in batch {
            do {
                let entryKey: [String: Any] = ["bundle": ["_0": entry.bundle]]
                var freshValue = try M.dictionary(entry.lastWritten)
                freshValue["fresh"] = entry.bundle
                let freshRecord = try M.record(in: [entryKey, freshValue], bundle: entry.bundle, own: own)
                _ = try await M.restore(journal: entry, current: freshRecord, write: { value, _ in
                    attempted.append(entry.bundle)
                    if entry.bundle == target { throw FixtureError.write }
                    precondition(value["fresh"] as? String == second)
                    return try M.allowed(in: value)
                }, clear: { pending.removeAll { $0.bundle == entry.bundle } })
            } catch {}
        }
        precondition(attempted == [target, second] && pending.map(\.bundle) == [target])
        precondition(!M.visibilityConfirmed(allowed: false, exactHits: 0))
        precondition(!M.visibilityConfirmed(allowed: false, exactHits: 1))
        precondition(!M.visibilityConfirmed(allowed: true, exactHits: 0))
        precondition(M.visibilityConfirmed(allowed: true, exactHits: 1))
        func hidden(children: [String] = ["target", "witness"], before: [String] = ["target", "witness"], afterChildren: [String] = ["target", "witness"], visible: [String]) -> Bool {
            M.hiddenInVisibleSubset(target: "target", baselineChildren: children, baselineVisible: before, currentChildren: afterChildren, currentVisible: visible, equals: ==)
        }
        precondition(hidden(visible: ["witness"]))
        precondition(!hidden(visible: ["target", "witness"]))
        precondition(!hidden(visible: [])) // No positive surviving witness.
        precondition(!hidden(afterChildren: ["witness"], visible: ["witness"])) // Old-object absence is not proof.
        precondition(!hidden(afterChildren: ["new-anonymous-target", "witness"], visible: ["witness"]))
        precondition(!hidden(afterChildren: ["target", "witness", "new"], visible: ["witness"]))
        precondition(!hidden(before: ["witness"], visible: ["witness"])) // No positive visible baseline.
        precondition(!hidden(visible: ["witness", "foreign"]))
        precondition(!hidden(visible: ["witness", "witness"]))
        precondition(!M.sameIdentitySet(["a", "a"], ["a", "a"], equals: ==))
        func hostHidden(targets: [String] = ["a", "b"], children: [String], visible: [String]) -> Bool {
            M.hiddenInHostSubset(targets: targets, baselineChildren: ["a", "b", "witness"], baselineVisible: ["a", "b", "witness"], currentChildren: children, currentVisible: visible, equals: ==)
        }
        precondition(hostHidden(children: ["witness"], visible: ["witness"]))
        precondition(hostHidden(children: ["a", "witness"], visible: ["witness"]))
        precondition(!hostHidden(children: ["new", "witness"], visible: ["witness"]))
        precondition(!hostHidden(children: ["witness"], visible: []))
        precondition(!hostHidden(children: ["a", "b", "witness"], visible: ["b", "witness"]))
        precondition(!hostHidden(targets: ["a"], children: ["witness"], visible: ["witness"])) // Unbound b cannot disappear.
        precondition(!hostHidden(targets: ["a", "b", "unbound"], children: ["witness"], visible: ["witness"]))
        precondition(!hostHidden(children: ["witness", "witness"], visible: ["witness"]))
        let rejected = M.candidateRejections(daemon: [key, value()], disk: [], bundles: [target], own: own)
        precondition(rejected[target] == "file-missing")
        let absent = M.candidateRejections(daemon: [], disk: [key, value()], bundles: [target], own: own)
        precondition(absent[target] == "live-missing")
        let duplicate = M.candidateRejections(daemon: [key, value(), key, value()], disk: [key, value()], bundles: [target], own: own)
        precondition(duplicate[target] == "live-duplicate(count=2)")
        precondition(M.candidateRejections(daemon: [key, value()], disk: [key, value()], bundles: [target], own: own).isEmpty)
        precondition(M.candidates(daemon: [key, value()], disk: [], own: own).isEmpty)
        let bothMissing = M.candidateRejections(daemon: [], disk: [], bundles: [target], own: own)
        precondition(bothMissing[target] == "live-missing;file-missing")
        let exactShape = M.catalogShape(in: [key, value()], bundle: target, exactValues: [target])
        precondition(exactShape.first?.contains("complete=true") == true && exactShape.first?.contains("exact_pairs=1") == true)
        precondition(exactShape.joined().contains("root_bundle=" + target))
        let executableKey: [String: Any] = ["executablePath": ["_0": "/Applications/Other.app/Contents/MacOS/test"]]
        let noAlias = M.catalogShape(in: [executableKey, value()], bundle: "io.unknown.helper", exactValues: ["io.unknown.helper", "/Applications/Test.app/Contents/MacOS/test"])
        precondition(noAlias.first?.contains("exact_pairs=0") == true, "matching a basename never establishes a source relation")
        let explicitGroup = M.catalogShape(in: [executableKey, value()], bundle: target, exactValues: [target])
        precondition(explicitGroup.first?.contains("exact_pairs=1") == true)
        precondition(explicitGroup.joined().contains("/Applications/") == false)
        let secretKey: [String: Any] = ["OtherPrivateApp": ["privateField": "/secret/path"]]
        let redacted = M.catalogShape(in: [secretKey, ["privateField": "privateValue"], key, value()], bundle: target, exactValues: [target]).joined()
        precondition(!redacted.contains("OtherPrivateApp") && !redacted.contains("privateField") && !redacted.contains("privateValue") && !redacted.contains("/secret/path"))
        print("PASS: strict target/Bool/location, journal-before-write, failure retention, field-only fresh metadata recovery")
    }
}
