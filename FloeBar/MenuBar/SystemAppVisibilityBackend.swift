//
//  SystemAppVisibilityBackend.swift
//  FloeBar
//

import AppKit
import Darwin
import Foundation
import OSLog

/// Writes only the verified trackedApplications key through the public
/// CFPreferences API. The exact file must already have user-selected access.
@MainActor
final class SystemAppVisibilityBackend {
    enum Failure: Error { case unavailable, mismatchedRead, writeUnconfirmed, invalidJournal }
    typealias Model = SystemAppVisibilityModel
    typealias Group = SystemAppVisibilityGroup
    private let installationProof = SystemAppInstallationProof()
    private var groups = [String: Group.InstallationBinding]()
    struct PreferencesIO {
        let readLive: (URL) throws -> Data
        let readFile: (URL) throws -> Data
        let writeLive: (Data, URL) throws -> Void
    }
    struct ProofHooks {
        let verify: (Group.Descriptor, Group.InstallationBinding?, Bool) async throws -> Group.InstallationBinding
        let isCurrent: (Group.InstallationBinding) -> Bool
    }
    private let preferences: PreferencesIO?
    private let proofHooks: ProofHooks?
    private let logger = Logger(category: "SystemAppVisibility")
    private let own: String
    private let journalURL: URL
    private(set) var candidateRejections = [String: String]()
    private var diagnosedMissingOwners = Set<String>()
    var reopenAuthorizedSnapshot: ((URL) throws -> Data)?

    init(own: String = Constants.bundleIdentifier, journalURL: URL? = nil, preferences: PreferencesIO? = nil, proofHooks: ProofHooks? = nil) {
        self.own = own
        self.preferences = preferences
        self.proofHooks = proofHooks
        self.journalURL = journalURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/FloeBar/SystemAppVisibilityJournal.plist"
        )
    }

    var hasJournal: Bool { FileManager.default.fileExists(atPath: journalURL.path) }

    private func domain(_ url: URL) -> CFString { url.deletingPathExtension().path as CFString }

    private func snapshots(_ url: URL) throws -> (live: [Any], disk: [Any]) {
        guard SystemMenuBarFilePolicy.accepts(url) else { throw Failure.unavailable }
        let live = try liveData(url)
        var reopened = false
        let fileData = try SystemMenuBarFilePolicy.readSnapshot(url: url, read: { try self.preferences?.readFile(url) ?? Data(contentsOf: url) }, reopen: {
            guard let reopen = self.reopenAuthorizedSnapshot else { throw Failure.unavailable }
            self.logger.notice("Native preference read-only scope reopen attempted; no preference write replay")
            let data = try reopen(url)
            reopened = true
            self.logger.notice("Native preference read-only scope reopen succeeded")
            return data
        })
        guard fileData.count <= 262_144,
            let root = try PropertyListSerialization.propertyList(from: fileData, options: [], format: nil) as? [String: Any],
            let disk = root["trackedApplications"] as? Data else { throw Failure.unavailable }
        if reopened { return (try Model.decode(liveData(url)), try Model.decode(disk)) }
        return (try Model.decode(live), try Model.decode(disk))
    }

    private func liveData(_ url: URL) throws -> Data {
        if let preferences { return try preferences.readLive(url) }
        guard CFPreferencesSynchronize(domain(url), kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
            let data = CFPreferencesCopyValue("trackedApplications" as CFString, domain(url), kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Data else { throw Failure.unavailable }
        return data
    }

    private func authorizeGroup(_ target: Group.Descriptor, saved: Group.InstallationBinding?, fresh: Bool) async throws -> Group.InstallationBinding {
        if let proofHooks { return try await proofHooks.verify(target, saved, fresh) }
        let request = try SystemAppInstallationProof.request(target, saved: saved)
        return try await installationProof.verify(request, fresh: fresh)
    }

    private func proofIsCurrent(_ binding: Group.InstallationBinding) -> Bool {
        proofHooks?.isCurrent(binding) ?? installationProof.isCurrent(binding)
    }

    func candidates(_ url: URL, discovering bundles: Set<String> = []) async throws -> [String: Bool] {
        let sources = try snapshots(url)
        candidateRejections = Model.candidateRejections(daemon: sources.live, disk: sources.disk, bundles: bundles, own: own)
        for (bundle, reason) in candidateRejections.sorted(by: { $0.key < $1.key }) {
            logger.notice("Native application catalog rejected target=\(bundle, privacy: .public) reason=\(reason, privacy: .public); no ownership inferred")
            if reason.contains("missing"), diagnosedMissingOwners.insert(bundle).inserted {
                var values: Set<String> = [bundle]
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
                    for url in [app.bundleURL, app.executableURL].compactMap({ $0 }) {
                        values.insert(url.path); values.insert(url.absoluteString)
                    }
                }
                for (source, array) in [("live", sources.live), ("file", sources.disk)] {
                    for line in Model.catalogShape(in: array, bundle: bundle, exactValues: values) {
                        logger.notice("Native application catalog shape target=\(bundle, privacy: .public) source=\(source, privacy: .public) \(line, privacy: .public)")
                    }
                }
            }
        }
        let journals = try loadJournals()
        var declarations = groups.mapValues(\.descriptor)
        for journal in journals { if let binding = journal.group { declarations[journal.bundle] = binding.descriptor } }
        for source in bundles.sorted().prefix(64) {
            if let declared = try? Group.discover(daemon: sources.live, disk: sources.disk, source: source, own: own) {
                declarations[declared.root] = declared
            }
        }
        var verified = [String: Group.InstallationBinding]()
        var recoveryError: (any Error)?
        for (root, target) in declarations.sorted(by: { $0.key < $1.key }) {
            do {
                let saved = journals.first(where: { $0.bundle == root })?.group ?? groups[root]
                try Group.validateDeclaration(daemon: sources.live, disk: sources.disk, target: target, own: own)
                let binding = try await authorizeGroup(target, saved: saved, fresh: false)
                try Task.checkCancellation()
                let fresh = try snapshots(url)
                try Group.validateDeclaration(daemon: fresh.live, disk: fresh.disk, target: target, own: own)
                guard proofIsCurrent(binding) else { throw Failure.unavailable }
                verified[root] = binding
            } catch {
                logger.notice("Native application group unavailable root=\(root, privacy: .public) reason=\(String(describing: error), privacy: .public); no write")
                if journals.contains(where: { $0.bundle == root && $0.group != nil }) { recoveryError = error }
            }
        }
        groups = verified
        if let recoveryError { throw recoveryError }
        let fresh = try snapshots(url)
        var result = try Dictionary(uniqueKeysWithValues: Model.candidates(daemon: fresh.live, disk: fresh.disk, own: own).map {
            ($0, try Model.record(in: fresh.live, bundle: $0, own: own).allowed)
        })
        for (root, binding) in groups {
            try Group.validateDeclaration(daemon: fresh.live, disk: fresh.disk, target: binding.descriptor, own: own)
            guard proofIsCurrent(binding) else { throw Failure.unavailable }
            result[root] = try Group.record(in: fresh.live, target: binding.descriptor, own: own).allowed
            logger.notice("Native application group verified root=\(root, privacy: .public) members=\(binding.members.count); root setting only")
        }
        return result
    }

    func displayRoot(for source: String) -> String {
        groups.values.first(where: { $0.descriptor.members.contains(source) })?.root ?? source
    }

    func memberBundles(for root: String) -> Set<String> { groups[root]?.descriptor.members ?? [root] }

    func ownsSource(_ source: String) -> Bool {
        (try? loadJournals().contains { $0.bundle == source || $0.group?.descriptor.members.contains(source) == true }) == true
    }

    private func verifyGroup(_ binding: Group.InstallationBinding, url: URL) async throws -> Group.InstallationBinding {
        let sources = try snapshots(url)
        try Group.validateDeclaration(daemon: sources.live, disk: sources.disk, target: binding.descriptor, own: own)
        let verified = try await authorizeGroup(binding.descriptor, saved: binding, fresh: true)
        try Task.checkCancellation()
        let after = try snapshots(url)
        try Group.validateDeclaration(daemon: after.live, disk: after.disk, target: binding.descriptor, own: own)
        guard proofIsCurrent(verified) else { throw Failure.unavailable }
        groups[binding.root] = verified
        return verified
    }

    func read(_ url: URL, bundle: String, group: Group.InstallationBinding? = nil) throws -> (array: [Any], record: Model.Record) {
        let sources = try snapshots(url)
        if let group {
            try Group.validateDeclaration(daemon: sources.live, disk: sources.disk, target: group.descriptor, own: own)
            let current = try Group.record(in: sources.live, target: group.descriptor, own: own)
            _ = try Group.record(in: sources.disk, target: group.descriptor, own: own)
            return (sources.live, current)
        }
        let confirmed = try Model.ownedReadback(daemon: sources.live, disk: sources.disk, bundle: bundle, own: own)
        logger.notice("Native preference target=\(bundle, privacy: .public) allowed=\(confirmed.record.allowed) disk_snapshot_stale=\(!confirmed.diskSnapshotMatchesOwnedValue); live CF authoritative, both identities verified")
        return (sources.live, confirmed.record)
    }

    private func loadJournals() throws -> [Model.Journal] {
        guard hasJournal else { return [] }
        return try Model.journals(from: Data(contentsOf: journalURL), own: own)
    }

    private func persist(_ journals: [Model.Journal]) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Model.JournalSet(version: 2, entries: journals))
        // Never create a journal that the recovery reader would reject.
        _ = try Model.journals(from: data, own: own)
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: journalURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.synchronize()
        let directory = open(journalURL.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw Failure.invalidJournal }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw Failure.invalidJournal }
        // Read back before any system write. A failed journal stops mutation.
        guard try Data(contentsOf: journalURL) == data else { throw Failure.invalidJournal }
        logger.notice("Native application recovery journal durable targets=\(journals.count)")
    }

    private func clearJournal(bundle: String) throws {
        let remaining = try loadJournals().filter { $0.bundle != bundle }
        if !remaining.isEmpty { try persist(remaining); return }
        try FileManager.default.removeItem(at: journalURL)
        let directory = open(journalURL.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw Failure.invalidJournal }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw Failure.invalidJournal }
        logger.notice("Native application recovery journal cleared")
    }

    private func restoredGroupValue(_ url: URL, bundle: String, desired: Bool) throws -> Bool {
        let sources = try snapshots(url)
        let current = try Group.rootRecord(in: sources.live, root: bundle, own: own)
        _ = try Group.rootRecord(in: sources.disk, root: bundle, own: own)
        return current.allowed == desired
    }

    private func write(_ value: [String: Any], expecting expected: [String: Any], url: URL, bundle: String, group: Group.InstallationBinding? = nil, restoring: Bool = false) async throws -> Bool {
        // Refresh after journal persistence: preserve the newest unrelated
        // entries and reject a changed target, never replay a stale whole file.
        try Task.checkCancellation()
        var verified = group
        if let group {
            if restoring {
                let source = try snapshots(url)
                let current = try Group.rootRecord(in: source.live, root: bundle, own: own)
                _ = try Group.rootRecord(in: source.disk, root: bundle, own: own)
                if current.allowed == (try Model.allowed(in: value)) { return current.allowed }
            }
            do { verified = try await verifyGroup(group, url: url) } catch {
                if restoring, let current = try? restoredGroupValue(url, bundle: bundle, desired: Model.allowed(in: value)), current { return true }
                throw error
            }
            if restoring, try restoredGroupValue(url, bundle: bundle, desired: Model.allowed(in: value)) { return true }
        }
        let current = try read(url, bundle: bundle, group: verified)
        let data: Data
        if let verified {
            guard proofIsCurrent(verified) else { throw Failure.unavailable }
            data = try Group.replacing(in: current.array, target: verified.descriptor, own: own, expected: expected, value: value)
        } else {
            data = try Model.replacing(in: current.array, bundle: bundle, own: own, expected: expected, value: value)
        }
        if let preferences { try preferences.writeLive(data, url) } else {
            CFPreferencesSetValue("trackedApplications" as CFString, data as CFData, domain(url), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            guard CFPreferencesSynchronize(domain(url), kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw Failure.writeUnconfirmed }
        }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let accepted = try await SystemAppVisibilityReadback.wait(read: {
                let after = try self.read(url, bundle: bundle, group: verified).record
                guard after.allowed == (try Model.allowed(in: value)) else { throw Failure.mismatchedRead }
                return after.allowed
            }, retryable: { error in
                guard let failure = error as? Failure else { return false }
                if case .mismatchedRead = failure { return true }
                return false
            })
            let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            logger.notice("Native application preference accepted target=\(bundle, privacy: .public) allowed=\(accepted) readback_ms=\(milliseconds); one write only, physical visibility not yet confirmed")
            return accepted
        } catch {
            let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            logger.notice("Native preference readback unconfirmed readback_ms=\(milliseconds); journal retained; no additional write")
            throw error
        }
    }

    func ownedBundles() throws -> Set<String> { Set(try loadJournals().map(\.bundle)) }

    func hide(bundle: String, url: URL) async throws {
        try await change(bundles: [bundle], expanded: false, url: url)
    }

    /// Removing a non-owned choice never opens a system/user-hidden item.
    func restoreOwned(bundle: String, url: URL) async throws {
        guard try ownedBundles().contains(bundle) else { return }
        _ = try await restore(bundle: bundle, url: url)
    }

    func change(bundles: [String], expanded: Bool, url: URL) async throws {
        guard !bundles.isEmpty, Set(bundles).count == bundles.count else { throw Failure.unavailable }
        if expanded {
            try await restoreAll(url: url)
            return
        }
        // Preflight every target before mutating any. Never take ownership of a
        // system/user-hidden application that this journal does not own.
        let journals = try loadJournals()
        for bundle in bundles {
            let current = try read(url, bundle: bundle, group: groups[bundle]).record
            guard current.allowed || journals.contains(where: { $0.bundle == bundle }) else { throw Model.Failure.missingJournal }
        }
        for bundle in bundles {
            try Task.checkCancellation()
            do {
                let current = try read(url, bundle: bundle, group: groups[bundle]).record
                if let journal = try loadJournals().first(where: { $0.bundle == bundle }) {
                    guard !current.allowed, !(try Model.allowed(in: Model.dictionary(journal.lastWritten))) else { throw Model.Failure.conflict }
                    continue
                }
                guard current.allowed else { throw Model.Failure.conflict }
                let journalGroup = groups[bundle]
                _ = try await Model.hide(
                    record: current,
                    bundle: bundle,
                    group: groups[bundle],
                    persist: { journal in
                        var entries = try self.loadJournals()
                        guard !entries.contains(where: { $0.bundle == bundle }) else { throw Failure.invalidJournal }
                        entries.append(journal)
                        try self.persist(entries)
                    },
                    write: { value, expected in
                        try await self.write(value, expecting: expected, url: url, bundle: bundle, group: journalGroup)
                    }
                )
            }
        }
    }

    private func restore(bundle: String, url: URL) async throws -> Bool {
        guard let journal = try loadJournals().first(where: { $0.bundle == bundle }) else { return true }
        let current: Model.Record
        if let binding = journal.group {
            let sources = try snapshots(url)
            current = try Group.rootRecord(in: sources.live, root: binding.root, own: own)
            _ = try Group.rootRecord(in: sources.disk, root: binding.root, own: own)
        } else { current = try read(url, bundle: bundle).record }
        return try await Model.restore(
            journal: journal,
            current: current,
            write: { value, expected in
                try await self.write(value, expecting: expected, url: url, bundle: bundle, group: journal.group, restoring: true)
            },
            clear: { try self.clearJournal(bundle: bundle) }
        )
    }

    func restoreAll(url: URL) async throws {
        try await restore(bundles: loadJournals().map(\.bundle), url: url)
    }

    private func restore(bundles: [String], url: URL) async throws {
        var firstError: (any Error)?
        for bundle in bundles {
            do { _ = try await restore(bundle: bundle, url: url) } catch {
                logger.error("Native application recovery retained target=\(bundle, privacy: .public) error=\(String(describing: error), privacy: .public)")
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}
