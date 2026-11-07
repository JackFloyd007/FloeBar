import Foundation

@MainActor
final class BackendFixture {
    typealias M = SystemAppVisibilityModel
    typealias G = SystemAppVisibilityGroup
    enum Failure: Error { case proof, write }
    let root = "io.test.parent"
    let helper = "io.test.child"
    let a = "io.test.exact.a"
    let b = "io.test.exact.b"
    let own = Constants.bundleIdentifier
    let directory: URL
    let journal: URL
    let url = SystemMenuBarFilePolicy.expectedURL
    var live = [Any]()
    var disk = [Any]()
    var writes = [String]()
    var freshProofs = 0
    var proofFails = false
    var mutateDuringProof = false
    var failFileOnceAfterTwoJournals = false
    var fileFailureInjected = false
    var reopeningFails = false
    var reopeningCount = 0
    var fileCorrupt = false
    var events = [String]()
    var permission: NSError { NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EPERM.rawValue))]) }
    var binding: G.InstallationBinding { G.InstallationBinding(root: root, rootPath: "/Applications/Fixture.app", members: [G.Member(bundle: root, relativeBundlePath: ""), G.Member(bundle: helper, relativeBundlePath: "Contents/SharedSupport/Child.app")], signerDigest: Data(repeating: 7, count: 32), team: "TESTTEAM") }
    init() throws {
        directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/wps-drag-cleanup-20261107/fixtures/" + UUID().uuidString)
        journal = directory.appendingPathComponent("journal.plist")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        live = [key(root), value(root, member: helper), key(a), value(a, member: a), key(b), value(b, member: b)]
        disk = live
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func key(_ bundle: String) -> [String: Any] { ["bundle": ["_0": bundle]] }
    func value(_ bundle: String, member: String) -> [String: Any] { ["isAllowed": true, "location": key(bundle), "menuItemLocations": [key(member)], "marker": 1] }
    func index(_ bundle: String) -> Int { stride(from: 0, to: live.count, by: 2).first { (($0 < live.count ? live[$0] : [:]) as? [String: [String: String]])?["bundle"]?["_0"] == bundle }! + 1 }
    func allowed(_ bundle: String) -> Bool { ((live[index(bundle)] as? [String: Any])?["isAllowed"] as? Bool) == true }
    func setAllowed(_ bundle: String, _ allowed: Bool) { var v = live[index(bundle)] as! [String: Any]; v["isAllowed"] = allowed; live[index(bundle)] = v }
    func changeMember(_ member: String) { var v = live[index(root)] as! [String: Any]; v["menuItemLocations"] = [key(member)]; live[index(root)] = v; disk[index(root)] = v }
    func entries() throws -> [M.Journal] { FileManager.default.fileExists(atPath: journal.path) ? try M.journals(from: Data(contentsOf: journal), own: own) : [] }
    func fileData() throws -> Data { try M.encoded(["trackedApplications": M.encoded(disk)]) }
    func backend() -> SystemAppVisibilityBackend {
        let preferences = SystemAppVisibilityBackend.PreferencesIO(readLive: { _ in try M.encoded(self.live) }, readFile: { _ in
            if self.fileCorrupt { return Data("invalid".utf8) }
            let count = try self.entries().count
            if self.failFileOnceAfterTwoJournals && !self.fileFailureInjected && self.writes.count == 1 && count == 2 {
                self.fileFailureInjected = true
                throw self.permission
            }
            return try self.fileData()
        }, writeLive: { data, _ in
            let next = try M.decode(data)
            let entries = try self.entries()
            for bundle in [self.root, self.a, self.b] {
                let index = self.index(bundle)
                let previous = try M.allowed(in: self.live[index] as! [String: Any])
                let nextValue = try M.allowed(in: next[index] as! [String: Any])
                if previous != nextValue {
                    precondition(entries.contains { $0.bundle == bundle }, "the real durable journal must precede every preference write")
                    self.writes.append(bundle)
                }
            }
            self.live = next
        })
        let hooks = SystemAppVisibilityBackend.ProofHooks(verify: { descriptor, saved, fresh in
            guard descriptor == self.binding.descriptor, saved == nil || saved?.sameInstallation(as: self.binding) == true else { throw Failure.proof }
            if fresh { self.freshProofs += 1 }
            if self.proofFails { throw Failure.proof }
            await Task.yield()
            if fresh && self.mutateDuringProof { self.changeMember("io.foreign.child") }
            return self.binding
        }, isCurrent: { $0.sameInstallation(as: self.binding) && !self.proofFails })
        let backend = SystemAppVisibilityBackend(own: own, journalURL: journal, preferences: preferences, proofHooks: hooks)
        backend.reopenAuthorizedSnapshot = { _ in
            self.reopeningCount += 1
            self.events.append("fresh-open")
            defer { self.events.append("fresh-close") }
            if self.reopeningFails { throw self.permission }
            // An unrelated live update while the old file read failed must not
            // be overwritten using the pre-reopen CF array.
            var v = self.live[self.index(self.a)] as! [String: Any]
            v["marker"] = 9
            self.live[self.index(self.a)] = v
            self.events.append("fresh-read")
            return try self.fileData()
        }
        return backend
    }
}

@main
struct SystemAppVisibilityBackendTests {
    @MainActor
    static func main() async throws {
        let f = try BackendFixture()
        let backend = f.backend()
        let initial = try await backend.candidates(f.url, discovering: [f.helper])
        precondition(initial[f.root] == true && backend.displayRoot(for: f.helper) == f.root)
        try await backend.hide(bundle: f.a, url: f.url)
        let legacy = try f.entries().first!
        var choices: Set<String> = [f.a]
        var recovery = false
        try await SystemAppSelectionEdit.perform(selected: true, collapsed: true, requiresRecovery: false, target: f.root, expectedAllowed: false, hide: { try await backend.hide(bundle: f.root, url: f.url) }, restoreOwned: {}, read: {
            try await backend.candidates(f.url, discovering: []) // AX empty, new selection still uncommitted.
        }, commit: { _ in choices.insert(f.root) }, failed: { recovery = true })
        precondition(choices.contains(f.root) && !recovery && !f.allowed(f.root))
        precondition(backend.ownsSource(f.helper), "helper drag recovery must resolve the root-owned group journal")
        let mixed = try f.entries()
        precondition(Set(mixed.map(\.version)) == [1, 2])
        let currentLegacy = mixed.first { $0.bundle == f.a }!
        precondition(currentLegacy.original == legacy.original && currentLegacy.lastWritten == legacy.lastWritten)
        let refreshed = try await backend.candidates(f.url, discovering: [])
        precondition(refreshed[f.root] == false)
        try await SystemAppSelectionEdit.perform(selected: false, collapsed: true, requiresRecovery: false, target: f.root, expectedAllowed: true, hide: {}, restoreOwned: { try await backend.restoreOwned(bundle: f.root, url: f.url) }, read: { try await backend.candidates(f.url, discovering: []) }, commit: { _ in choices.remove(f.root) }, failed: { recovery = true })
        precondition(f.allowed(f.root) && !f.allowed(f.a) && !choices.contains(f.root))
        precondition(tryCount(f) == 1)
        // Saved group recovery is independent of selection/AX/running helpers.
        try await backend.hide(bundle: f.root, url: f.url)
        try await backend.hide(bundle: f.b, url: f.url)
        f.proofFails = true
        let cold = f.backend()
        do { try await cold.restoreAll(url: f.url); preconditionFailure() } catch {}
        precondition(f.allowed(f.a) && f.allowed(f.b) && !f.allowed(f.root) && tryCount(f) == 1)
        f.proofFails = false
        try await cold.restoreAll(url: f.url)
        precondition(f.allowed(f.root) && !cold.hasJournal)
        // Member/installation changes cannot write, but original=true clears
        // the saved ownership without needing the old installation proof.
        _ = try await backend.candidates(f.url, discovering: [f.helper])
        try await backend.hide(bundle: f.root, url: f.url)
        f.changeMember("io.foreign.child")
        let countBefore = f.writes.count
        do { try await backend.restoreAll(url: f.url); preconditionFailure() } catch {}
        precondition(f.writes.count == countBefore && tryCount(f) == 1)
        f.setAllowed(f.root, true)
        f.proofFails = true
        try await backend.restoreAll(url: f.url)
        precondition(!backend.hasJournal && f.writes.count == countBefore)
        // Awaited proof cannot authorize an obsolete system membership.
        let race = try BackendFixture()
        let racedBackend = race.backend()
        _ = try await racedBackend.candidates(race.url, discovering: [race.helper])
        race.mutateDuringProof = true
        do { try await racedBackend.hide(bundle: race.root, url: race.url); preconditionFailure() } catch {}
        precondition(race.writes.isEmpty && tryCount(race) == 1)
        race.proofFails = true
        try await racedBackend.restoreAll(url: race.url) // Already original, no installation dependency.
        precondition(!racedBackend.hasJournal)
        // Exact v1 single-entry compatibility remains available.
        let old = try BackendFixture()
        let original = try SystemAppVisibilityModel.record(in: old.live, bundle: old.a, own: old.own)
        let journal = try SystemAppVisibilityModel.hideJournal(record: original, bundle: old.a)
        try PropertyListEncoder().encode(journal).write(to: old.journal)
        old.setAllowed(old.a, false)
        try await old.backend().restoreAll(url: old.url)
        precondition(old.allowed(old.a) && tryCount(old) == 0)
        // Mid-lease EPERM: reopen once, preserve newer live metadata, write each target once.
        let scope = try BackendFixture()
        scope.failFileOnceAfterTwoJournals = true
        let scopedBackend = scope.backend()
        try await scopedBackend.change(bundles: [scope.a, scope.b], expanded: false, url: scope.url)
        precondition(scope.reopeningCount == 1 && scope.writes == [scope.a, scope.b])
        precondition((scope.live[scope.index(scope.a)] as? [String: Any])?["marker"] as? Int == 9)
        precondition(scope.events == ["fresh-open", "fresh-read", "fresh-close"])
        try await scopedBackend.restoreAll(url: scope.url)
        let denied = try BackendFixture()
        denied.failFileOnceAfterTwoJournals = true
        denied.reopeningFails = true
        let deniedBackend = denied.backend()
        do { try await deniedBackend.change(bundles: [denied.a, denied.b], expanded: false, url: denied.url); preconditionFailure() } catch {}
        precondition(denied.reopeningCount == 1 && denied.writes == [denied.a] && tryCount(denied) == 2)
        precondition(denied.events == ["fresh-open", "fresh-close"])
        try await deniedBackend.restoreAll(url: denied.url)
        precondition(!deniedBackend.hasJournal)
        let corrupt = try BackendFixture()
        corrupt.fileCorrupt = true
        do { _ = try await corrupt.backend().candidates(corrupt.url); preconditionFailure() } catch {}
        precondition(corrupt.reopeningCount == 0 && corrupt.writes.isEmpty)
        print("PASS: real Backend mixed journals, new-owned/AX-empty selection window, refresh/off, cold and partial recovery, changed members/noop priority, proof race and EPERM single reopen/no write replay")
    }
    @MainActor static func tryCount(_ fixture: BackendFixture) -> Int { (try? fixture.entries().count) ?? -1 }
}
