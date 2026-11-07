//
//  SystemAppVisibilityGroup.swift
//  FloeBar
//

import Foundation

/// A system declaration is only a candidate for installation verification. It
/// never authorizes a mutation by itself; the exact-bundle model stays strict.
enum SystemAppVisibilityGroup {
    enum Failure: Error { case unsupported, ambiguous, membership }

    struct Descriptor: Codable, Equatable, Sendable {
        let root: String
        let members: Set<String>
    }

    struct Member: Codable, Equatable, Sendable {
        let bundle: String
        let relativeBundlePath: String
    }

    struct InstallationBinding: Codable, Equatable, Sendable {
        let root: String
        let rootPath: String
        let members: [Member]
        let signerDigest: Data
        let team: String
        var descriptor: Descriptor { Descriptor(root: root, members: Set(members.map(\.bundle))) }
        func sameInstallation(as other: InstallationBinding) -> Bool {
            root == other.root && rootPath == other.rootPath && team == other.team &&
                members.sorted(by: { $0.bundle < $1.bundle }) == other.members.sorted(by: { $0.bundle < $1.bundle })
        }
    }

    static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && path.hasPrefix("Contents/") && path.hasSuffix(".app") &&
            !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    static func validate(_ binding: InstallationBinding, own: String) throws {
        guard SystemAppVisibilityModel.eligible(binding.root, own: own), binding.members.count > 1, binding.members.count <= 16,
            Set(binding.members.map(\.bundle)).count == binding.members.count,
            binding.members.contains(where: { $0.bundle == binding.root && $0.relativeBundlePath.isEmpty }),
            binding.rootPath.hasPrefix("/"), binding.rootPath.hasSuffix(".app"), URL(fileURLWithPath: binding.rootPath).standardizedFileURL.path == binding.rootPath,
            binding.signerDigest.count == 32, !binding.team.isEmpty, binding.team.count <= 32 else { throw Failure.unsupported }
        for member in binding.members {
            guard SystemAppVisibilityModel.eligible(member.bundle, own: own),
                member.bundle == binding.root ? member.relativeBundlePath.isEmpty : validRelativePath(member.relativeBundlePath) else { throw Failure.membership }
        }
    }

    private static func bundle(_ value: Any) -> String? {
        guard let key = value as? [String: Any], key.count == 1,
            let owner = key["bundle"] as? [String: Any], owner.count == 1 else { return nil }
        return owner["_0"] as? String
    }

    private static func references(_ value: Any, own: String, depth: Int = 0) throws -> Set<String> {
        guard depth < 10 else { throw Failure.unsupported }
        if let dictionary = value as? [String: Any] {
            if dictionary["bundle"] != nil {
                guard let identifier = bundle(dictionary), SystemAppVisibilityModel.eligible(identifier, own: own) else { throw Failure.membership }
                return [identifier]
            }
            var result = Set<String>()
            for (key, child) in dictionary {
                if key == "location" {
                    guard let identifier = bundle(child), SystemAppVisibilityModel.eligible(identifier, own: own) else { throw Failure.membership }
                    result.insert(identifier)
                } else { result.formUnion(try references(child, own: own, depth: depth + 1)) }
            }
            return result
        }
        var result = Set<String>()
        for child in value as? [Any] ?? [] { result.formUnion(try references(child, own: own, depth: depth + 1)) }
        return result
    }

    static func declaration(in array: [Any], root: String, own: String) throws -> Descriptor {
        guard array.count.isMultiple(of: 2), SystemAppVisibilityModel.eligible(root, own: own) else { throw Failure.unsupported }
        let indices = stride(from: 0, to: array.count, by: 2).filter { bundle(array[$0]) == root }
        guard indices.count == 1, let index = indices.first,
            let value = array[index + 1] as? [String: Any], value["location"].flatMap(bundle) == root,
            let locations = value["menuItemLocations"] as? [Any] else { throw Failure.ambiguous }
        _ = try SystemAppVisibilityModel.allowed(in: value)
        var members: Set<String> = [root]
        for location in locations {
            let declared = try references(location, own: own)
            guard !declared.isEmpty else { throw Failure.membership }
            members.formUnion(declared)
        }
        guard members.count > 1, members.count <= 16 else { throw Failure.unsupported }
        return Descriptor(root: root, members: members)
    }

    static func discover(daemon: [Any], disk: [Any], source: String, own: String) throws -> Descriptor? {
        guard daemon.count.isMultiple(of: 2), disk.count.isMultiple(of: 2),
            SystemAppVisibilityModel.eligible(source, own: own) else { throw Failure.unsupported }
        func candidates(_ array: [Any]) -> [Descriptor] {
            Set(stride(from: 0, to: array.count, by: 2).compactMap { bundle(array[$0]) }).compactMap { root -> Descriptor? in
                guard let declaration = try? declaration(in: array, root: root, own: own), declaration.members.contains(source) else { return nil }
                return declaration
            }
        }
        let live = candidates(daemon)
        let file = candidates(disk)
        guard live.count <= 1, file.count <= 1 else { throw Failure.ambiguous }
        guard let candidate = live.first else { return nil }
        guard file.first == candidate else { throw Failure.membership }
        if source != candidate.root {
            for array in [daemon, disk] {
                guard !stride(from: 0, to: array.count, by: 2).contains(where: { bundle(array[$0]) == source }) else { throw Failure.ambiguous }
            }
        }
        return candidate
    }

    static func validateDeclaration(daemon: [Any], disk: [Any], target: Descriptor, own: String) throws {
        for member in target.members {
            guard try discover(daemon: daemon, disk: disk, source: member, own: own) == target else { throw Failure.membership }
        }
    }

    /// Header-only read is used solely to clear an already restored journal.
    /// It cannot authorize a false-to-original write or claim group ownership.
    static func rootRecord(in array: [Any], root: String, own: String) throws -> SystemAppVisibilityModel.Record {
        guard array.count.isMultiple(of: 2), SystemAppVisibilityModel.eligible(root, own: own) else { throw Failure.unsupported }
        let indices = stride(from: 0, to: array.count, by: 2).filter { bundle(array[$0]) == root }
        guard indices.count == 1, let index = indices.first,
            let value = array[index + 1] as? [String: Any], value["location"].flatMap(bundle) == root else { throw Failure.ambiguous }
        return SystemAppVisibilityModel.Record(index: index + 1, value: value, allowed: try SystemAppVisibilityModel.allowed(in: value))
    }

    static func replacing(in array: [Any], target: Descriptor, own: String, expected: [String: Any], value: [String: Any]) throws -> Data {
        let current = try record(in: array, target: target, own: own)
        guard current.allowed == (try SystemAppVisibilityModel.allowed(in: expected)) else { throw Failure.membership }
        var updated = current.value
        updated["isAllowed"] = try SystemAppVisibilityModel.allowed(in: value)
        var output = array
        output[current.index] = updated
        _ = try record(in: output, target: target, own: own)
        return try SystemAppVisibilityModel.encoded(output)
    }

    static func record(in array: [Any], target: Descriptor, own: String) throws -> SystemAppVisibilityModel.Record {
        guard try declaration(in: array, root: target.root, own: own) == target,
            let index = stride(from: 0, to: array.count, by: 2).first(where: { bundle(array[$0]) == target.root }),
            let value = array[index + 1] as? [String: Any] else { throw Failure.membership }
        return SystemAppVisibilityModel.Record(index: index + 1, value: value, allowed: try SystemAppVisibilityModel.allowed(in: value))
    }
}
