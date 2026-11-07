//
//  SystemAppInstallationProof.swift
//  FloeBar
//

import AppKit
import CryptoKit
import Foundation
import OSLog
import Security

/// Security objects stay on a worker. Only immutable installation metadata is
/// returned to the main actor; cached catalog results never authorize writes.
@MainActor
final class SystemAppInstallationProof {
    typealias Group = SystemAppVisibilityGroup
    enum Failure: Error, Sendable { case unavailable, identity, signature, containment, changed, deadline }
    enum CompletionBudget: String {
        case accepted = "finished-in-budget"
        case consumedLate = "finished-in-budget-consumed-late"
        case workerLate = "finished-after-budget"
        case agedOut = "result-aged-out"
        case invalid = "invalid-timing"
    }

    nonisolated static func completionBudget(queued: TimeInterval, finished: TimeInterval, consumed: TimeInterval, budget: TimeInterval) -> CompletionBudget {
        guard budget > 0, finished >= queued, consumed >= finished else { return .invalid }
        guard finished - queued <= budget else { return .workerLate }
        guard consumed - finished <= budget else { return .agedOut }
        return consumed - queued > budget ? .consumedLate : .accepted
    }

    struct Request: Sendable {
        let descriptor: Group.Descriptor
        let rootPath: String
        let memberPaths: [String: String]
        let expected: Group.InstallationBinding?
    }
    struct Receipt: Sendable {
        let binding: Group.InstallationBinding
        let stamp: String
    }
    typealias Inspector = @Sendable (Request, Receipt?, Bool) throws -> Receipt

    private final class Pending: @unchecked Sendable {
        struct Observation {
            let result: Result<Receipt, Failure>?
            let beganAt: TimeInterval?
            let finishedAt: TimeInterval?
        }
        let started = ProcessInfo.processInfo.systemUptime
        private let lock = NSLock()
        private var result: Result<Receipt, Failure>?
        private var beganAt: TimeInterval?
        private var finishedAt: TimeInterval?
        func begin() { lock.lock(); defer { lock.unlock() }; beganAt = ProcessInfo.processInfo.systemUptime }
        func finish(_ result: Result<Receipt, Failure>) {
            lock.lock(); defer { lock.unlock() }
            finishedAt = ProcessInfo.processInfo.systemUptime
            self.result = result
        }
        func observation() -> Observation {
            lock.lock(); defer { lock.unlock() }
            return Observation(result: result, beganAt: beganAt, finishedAt: finishedAt)
        }
        func value() -> Result<Receipt, Failure>? { observation().result }
    }
    private var cached = [String: Receipt]()
    private var pending = [String: Pending]()
    private let inspect: Inspector
    private let deadline: TimeInterval
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FloeBar", category: "SystemAppVisibility")
    var unfinishedWorkerCount: Int { pending.values.filter { $0.value() == nil }.count }

    init(deadline: TimeInterval = 12, inspect: @escaping Inspector = { request, cached, fresh in try SystemAppInstallationProof.inspect(request, cached: cached, fresh: fresh) }) {
        self.deadline = deadline
        self.inspect = inspect
    }

    func verify(_ request: Request, fresh: Bool) async throws -> Group.InstallationBinding {
        try Task.checkCancellation()
        let identity = request.descriptor.root + "|" + request.rootPath + "|" + request.memberPaths.sorted(by: { $0.key < $1.key }).map { $0.key + "=" + $0.value }.joined(separator: "|")
        let key = identity + (fresh ? "|fresh" : "|catalog") + "|" + (request.expected?.signerDigest.base64EncodedString() ?? "new") + "|" + (request.expected?.team ?? "")
        pending = pending.filter { $0.value.value() == nil }
        let work: Pending
        if let existing = pending[key] { work = existing } else {
            guard pending.count < 2 else { throw Failure.unavailable }
            let slot = Pending()
            pending[key] = slot
            work = slot
            let inspect = inspect
            let previous = cached[identity]
            Task.detached(priority: fresh ? .userInitiated : .utility) {
                slot.begin()
                do { slot.finish(.success(try inspect(request, previous, fresh))) } catch let error as Failure { slot.finish(.failure(error)) } catch { slot.finish(.failure(.unavailable)) }
            }
        }
        func record(_ phase: String, _ observation: Pending.Observation) {
            let now = ProcessInfo.processInfo.systemUptime
            let queued = ((observation.beganAt ?? now) - work.started) * 1000
            let running = observation.beganAt.map { ((observation.finishedAt ?? now) - $0) * 1000 } ?? 0
            let age = observation.finishedAt.map { (now - $0) * 1000 } ?? -1
            logger.notice("Native group proof root=\(request.descriptor.root, privacy: .public) fresh=\(fresh) phase=\(phase, privacy: .public) queued_ms=\(queued) run_ms=\(running) result_age_ms=\(age); no preference replay")
        }
        while work.value() == nil {
            try Task.checkCancellation()
            if ProcessInfo.processInfo.systemUptime - work.started >= deadline {
                // Completion can race the timer: inspect result and its timing
                // together before classifying a still-unfinished worker.
                let observation = work.observation()
                if observation.result != nil { break }
                record("unfinished-deadline", observation)
                throw Failure.deadline
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        if pending[key] === work { pending[key] = nil }
        try Task.checkCancellation()
        let observation = work.observation()
        guard let result = observation.result, let finished = observation.finishedAt else { throw Failure.unavailable }
        let budget = Self.completionBudget(queued: work.started, finished: finished, consumed: ProcessInfo.processInfo.systemUptime, budget: deadline)
        switch budget {
        case .accepted, .consumedLate:
            if fresh || budget == .consumedLate { record(budget.rawValue, observation) }
        case .workerLate, .agedOut, .invalid:
            record(budget.rawValue, observation)
            throw Failure.deadline
        }
        let receipt = try result.get()
        guard request.expected == nil || request.expected?.sameInstallation(as: receipt.binding) == true else { throw Failure.changed }
        try Task.checkCancellation()
        if cached.count >= 8 { cached.removeAll() }
        cached[identity] = receipt
        return receipt.binding
    }

    func isCurrent(_ binding: Group.InstallationBinding) -> Bool {
        guard let request = try? Self.request(binding.descriptor, saved: binding), let current = try? Self.stamp(request) else { return false }
        return cached.values.contains { $0.binding == binding && $0.stamp == current }
    }

    static func request(_ descriptor: Group.Descriptor, saved: Group.InstallationBinding? = nil) throws -> Request {
        let root: URL
        var paths = [String: String]()
        guard let registeredRoot = NSWorkspace.shared.urlForApplication(withBundleIdentifier: descriptor.root) else { throw Failure.unavailable }
        root = registeredRoot.standardizedFileURL.resolvingSymlinksInPath()
        if let saved {
            guard saved.root == descriptor.root, saved.rootPath == root.path,
                Set(saved.members.map(\.bundle)) == descriptor.members, saved.members.count == descriptor.members.count else { throw Failure.identity }
            for member in saved.members {
                guard member.bundle == descriptor.root ? member.relativeBundlePath.isEmpty : validRelativePath(member.relativeBundlePath) else { throw Failure.containment }
                paths[member.bundle] = member.relativeBundlePath.isEmpty ? root.path : root.appendingPathComponent(member.relativeBundlePath).path
            }
        } else {
            for member in descriptor.members {
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: member).compactMap(\.bundleURL)
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: member) ?? running.first else { throw Failure.unavailable }
                paths[member] = url.standardizedFileURL.resolvingSymlinksInPath().path
            }
        }
        for (member, path) in paths {
            if let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: member) {
                guard registered.standardizedFileURL.resolvingSymlinksInPath().path == path else { throw Failure.identity }
            }
            for application in NSRunningApplication.runningApplications(withBundleIdentifier: member) {
                guard application.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == path,
                    let actual = application.executableURL?.standardizedFileURL.resolvingSymlinksInPath(),
                    let expected = Bundle(url: URL(fileURLWithPath: path))?.executableURL?.standardizedFileURL.resolvingSymlinksInPath(),
                    actual == expected else { throw Failure.identity }
            }
        }
        return Request(descriptor: descriptor, rootPath: root.path, memberPaths: paths, expected: saved)
    }

    nonisolated static func validRelativePath(_ path: String) -> Bool {
        Group.validRelativePath(path)
    }

    private nonisolated static func contained(_ url: URL, root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    private nonisolated static func stamp(_ request: Request) throws -> String {
        var values = [String]()
        let root = URL(fileURLWithPath: request.rootPath).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path == request.rootPath else { throw Failure.containment }
        for path in Set(request.memberPaths.values).union([request.rootPath]).sorted() {
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard contained(url, root: root), contained(url.appendingPathComponent("Contents/Info.plist").resolvingSymlinksInPath(), root: root),
                let bundle = Bundle(url: url), let executable = bundle.executableURL,
                contained(executable.resolvingSymlinksInPath(), root: root) else { throw Failure.identity }
            for file in [url, executable, url.appendingPathComponent("Contents/Info.plist"), url.appendingPathComponent("Contents/_CodeSignature/CodeResources")] {
                guard contained(file.resolvingSymlinksInPath(), root: root) else { throw Failure.containment }
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                values.append(file.resolvingSymlinksInPath().path + "|" + String(describing: attributes[.systemFileNumber]) + "|" + String(describing: attributes[.size]) + "|" + String((attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0))
            }
        }
        return SHA256.hash(data: Data(values.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func signature(_ url: URL, identifier: String, strict: Bool) throws -> (Data, String) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
            SecStaticCodeCheckValidity(code, strict ? SecCSFlags(rawValue: kSecCSStrictValidate) : [], nil) == errSecSuccess else { throw Failure.signature }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
            let values = information as? [String: Any],
            values[kSecCodeInfoIdentifier as String] as? String == identifier,
            let team = values[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
            let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first else { throw Failure.identity }
        return (Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)), team)
    }

    nonisolated static func validateLinks(_ member: URL, root: URL) throws {
        var complete = true
        guard let enumerator = FileManager.default.enumerator(at: member, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [], errorHandler: { _, _ in complete = false; return false }) else { throw Failure.unavailable }
        var count = 0
        for case let file as URL in enumerator {
            count += 1
            guard count <= 8192 else { throw Failure.unavailable }
            if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                let target = file.resolvingSymlinksInPath()
                guard contained(target, root: root), FileManager.default.fileExists(atPath: target.path) else { throw Failure.containment }
            }
        }
        guard complete else { throw Failure.unavailable }
    }

    nonisolated static func inspect(_ request: Request, cached: Receipt?, fresh: Bool) throws -> Receipt {
        let before = try stamp(request)
        if !fresh, let cached, cached.stamp == before, request.expected == nil || request.expected?.sameInstallation(as: cached.binding) == true { return cached }
        let root = URL(fileURLWithPath: request.rootPath).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path == request.rootPath, Bundle(url: root)?.bundleIdentifier == request.descriptor.root,
            Set(request.memberPaths.keys) == request.descriptor.members else { throw Failure.identity }
        let rootSigner = try signature(root, identifier: request.descriptor.root, strict: true)
        var members = [Group.Member]()
        for identifier in request.descriptor.members.sorted() {
            guard let path = request.memberPaths[identifier] else { throw Failure.identity }
            let member = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard contained(member, root: root), Bundle(url: member)?.bundleIdentifier == identifier,
                let executable = Bundle(url: member)?.executableURL,
                contained(executable.resolvingSymlinksInPath(), root: root) else { throw Failure.containment }
            let relative = identifier == request.descriptor.root ? "" : String(member.path.dropFirst(root.path.count + 1))
            guard identifier == request.descriptor.root ? member == root : validRelativePath(relative) else { throw Failure.containment }
            if identifier != request.descriptor.root {
                try validateLinks(member, root: root)
                let signer = try signature(member, identifier: identifier, strict: false)
                guard signer.0 == rootSigner.0, signer.1 == rootSigner.1 else { throw Failure.identity }
            }
            members.append(Group.Member(bundle: identifier, relativeBundlePath: relative))
        }
        let binding = Group.InstallationBinding(root: request.descriptor.root, rootPath: root.path, members: members, signerDigest: rootSigner.0, team: rootSigner.1)
        guard request.expected == nil || request.expected?.sameInstallation(as: binding) == true else { throw Failure.changed }
        guard try stamp(request) == before else { throw Failure.changed }
        return Receipt(binding: binding, stamp: before)
    }
}
