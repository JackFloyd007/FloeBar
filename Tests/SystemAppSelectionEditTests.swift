import Foundation

@MainActor
final class SelectionFixture {
    typealias M = SystemAppVisibilityModel
    enum Failure: Error { case write, read }
    let own = "io.test.floebar"
    var array: [Any] = []
    var journals = [M.Journal]()
    var choices = Set<String>()
    var recovery = false
    var failWrite = false
    var failRead = false
    var events = [String]()
    init() {
        for bundle in ["io.test.a", "io.test.b", "io.test.external"] {
            let key: [String: Any] = ["bundle": ["_0": bundle]]
            array += [key, ["isAllowed": bundle != "io.test.external", "location": key, "menuItemLocations": [key]]]
        }
    }
    func record(_ bundle: String) throws -> M.Record { try M.record(in: array, bundle: bundle, own: own) }
    func hide(_ bundle: String) async throws {
        _ = try await M.hide(record: record(bundle), bundle: bundle, persist: { journal in
            self.journals.removeAll { $0.bundle == bundle }
            self.journals.append(journal)
            let encoded = try PropertyListEncoder().encode(M.JournalSet(version: 2, entries: self.journals))
            self.journals = try M.journals(from: encoded, own: self.own)
            self.events.append("persist:" + bundle)
        }, write: { value, expected in
            if self.failWrite { throw Failure.write }
            self.events.append("write:" + bundle)
            self.array = try M.decode(M.replacing(in: self.array, bundle: bundle, own: self.own, expected: expected, value: value))
            return false
        })
    }
    func restore(_ bundle: String) async throws {
        guard let journal = journals.first(where: { $0.bundle == bundle }) else { return }
        _ = try await M.restore(journal: journal, current: record(bundle), write: { value, expected in
            if self.failWrite { throw Failure.write }
            self.events.append("restore:" + bundle)
            self.array = try M.decode(M.replacing(in: self.array, bundle: bundle, own: self.own, expected: expected, value: value))
            return true
        }, clear: { self.journals.removeAll { $0.bundle == bundle } })
    }
    func states() throws -> [String: Bool] {
        if failRead { throw Failure.read }
        return try Dictionary(uniqueKeysWithValues: ["io.test.a", "io.test.b", "io.test.external"].map { ($0, try record($0).allowed) })
    }
    func edit(_ bundle: String, selected: Bool) async throws {
        try await SystemAppSelectionEdit.perform(selected: selected, collapsed: !journals.isEmpty, requiresRecovery: recovery, target: bundle, expectedAllowed: selected && !journals.isEmpty ? false : !selected && journals.contains(where: { $0.bundle == bundle }) ? true : nil, hide: { try await self.hide(bundle) }, restoreOwned: { try await self.restore(bundle) }, read: { try self.states() }, commit: { _ in
            if selected { self.choices.insert(bundle) } else { self.choices.remove(bundle) }
        }, failed: { self.recovery = true })
    }
    func recover() async throws {
        try await SystemAppSelectionEdit.recover(restoreAll: {
            for bundle in self.journals.map(\.bundle) { try await self.restore(bundle) }
        }, journalExists: { !self.journals.isEmpty }, read: { try self.states() }, commit: { _ in self.recovery = false }, failed: { self.recovery = true })
    }
}

@main
struct SystemAppSelectionEditTests {
    @MainActor
    static func main() async throws {
        let f = SelectionFixture()
        try await f.edit("io.test.a", selected: true) // Expanded selection is not a hide.
        precondition(f.events.isEmpty && f.choices.contains("io.test.a"))
        try await f.hide("io.test.a")
        try await f.edit("io.test.b", selected: true)
        precondition(f.events.suffix(2) == ["persist:io.test.b", "write:io.test.b"])
        precondition(f.journals.count == 2)
        try await f.edit("io.test.a", selected: false)
        let afterOff = try f.states()
        precondition(afterOff["io.test.a"] == true)
        precondition(afterOff["io.test.b"] == false && f.journals.map(\.bundle) == ["io.test.b"])
        f.choices.insert("io.test.external")
        let eventCount = f.events.count
        try await f.edit("io.test.external", selected: false)
        let external = try f.record("io.test.external").allowed
        precondition(f.events.count == eventCount && !external)
        f.failWrite = true
        do { try await f.edit("io.test.b", selected: false); preconditionFailure() } catch {}
        precondition(f.recovery && f.choices.contains("io.test.b") && f.journals.count == 1)
        _ = try f.states() // A successful Refresh cannot clear the mutation gate.
        precondition(f.recovery)
        f.failWrite = false
        try await f.recover()
        precondition(!f.recovery && f.journals.isEmpty)
        // Failed new hide leaves an orphan journal, but not a new choice.
        try await f.hide("io.test.b")
        f.choices.removeAll()
        f.failWrite = true
        do { try await f.edit("io.test.a", selected: true); preconditionFailure() } catch {}
        precondition(f.choices.isEmpty && f.journals.count == 2 && f.recovery)
        f.failWrite = false
        let beforeBlocked = f.events.count
        do { try await f.edit("io.test.a", selected: true); preconditionFailure() } catch {}
        precondition(f.events.count == beforeBlocked)
        try await f.recover() // Independent of selected count and UI readiness.
        precondition(f.journals.isEmpty && !f.recovery)
        // Restoration can finish yet fresh list read fails: explicit empty recovery unlocks.
        f.failRead = true
        do { try await f.recover(); preconditionFailure() } catch {}
        precondition(f.journals.isEmpty && f.recovery)
        f.failRead = false
        try await f.recover()
        precondition(!f.recovery)
        // A durable successful write followed by conflicting/missing fresh target cannot commit.
        for state: [String: Bool] in [[:], ["io.test.a": true]] {
            let conflict = SelectionFixture()
            try await conflict.hide("io.test.b")
            var committed = false
            do {
                try await SystemAppSelectionEdit.perform(selected: true, collapsed: true, requiresRecovery: false, target: "io.test.a", expectedAllowed: false, hide: { try await conflict.hide("io.test.a") }, restoreOwned: {}, read: { state }, commit: { _ in committed = true }, failed: { conflict.recovery = true })
                preconditionFailure()
            } catch {}
            precondition(!committed && conflict.recovery && conflict.journals.count == 2)
            precondition(conflict.events.suffix(2) == ["persist:io.test.a", "write:io.test.a"])
            try await conflict.recover()
            precondition(conflict.journals.isEmpty)
        }
        print("SystemAppSelectionEditTests passed")
    }
}
