//
//  SystemAppVisibilityModel.swift
//  FloeBar
//

import CoreFoundation
import Foundation

/// Protocol facts verified against the user-authorized system file. This is an
/// independent parser; no closed-source backend or archived class is loaded.
enum SystemAppVisibilityModel {
    enum Failure: Error { case unsupported, protectedBundle, ambiguous, ownership, conflict, missingJournal }

    struct Record {
        let index: Int
        let value: [String: Any]
        let allowed: Bool
    }

    struct Journal: Codable {
        let version: Int
        let bundle: String
        let original: Data
        let lastWritten: Data
        var group: SystemAppVisibilityGroup.InstallationBinding?
    }

    struct JournalSet: Codable {
        let version: Int
        var entries: [Journal]
    }

    static func journals(from data: Data, own: String) throws -> [Journal] {
        guard data.count <= 1_048_576 else { throw Failure.unsupported }
        let decoder = PropertyListDecoder()
        let entries: [Journal]
        if let set = try? decoder.decode(JournalSet.self, from: data) {
            guard set.version == 2, set.entries.count <= 128 else { throw Failure.unsupported }
            entries = set.entries
        } else {
            entries = [try decoder.decode(Journal.self, from: data)]
        }
        guard Set(entries.map(\.bundle)).count == entries.count else { throw Failure.ambiguous }
        for journal in entries {
            guard eligible(journal.bundle, own: own) else { throw Failure.protectedBundle }
            let key: [String: Any] = ["bundle": ["_0": journal.bundle]]
            let original: Record
            let written: Record
            if let group = journal.group {
                guard journal.version == 2, group.root == journal.bundle else { throw Failure.unsupported }
                try SystemAppVisibilityGroup.validate(group, own: own)
                original = try SystemAppVisibilityGroup.record(in: [key, dictionary(journal.original)], target: group.descriptor, own: own)
                written = try SystemAppVisibilityGroup.record(in: [key, dictionary(journal.lastWritten)], target: group.descriptor, own: own)
            } else {
                guard journal.version == 1 else { throw Failure.unsupported }
                original = try record(in: [key, dictionary(journal.original)], bundle: journal.bundle, own: own)
                written = try record(in: [key, dictionary(journal.lastWritten)], bundle: journal.bundle, own: own)
            }
            guard original.allowed, !written.allowed else { throw Failure.unsupported }
        }
        return entries
    }

    /// Only exact, uniquely owned targets in both sources can be offered.
    static func candidates(daemon: [Any], disk: [Any], own: String) -> [String] {
        guard daemon.count.isMultiple(of: 2), disk.count.isMultiple(of: 2) else { return [] }
        return Set(stride(from: 0, to: daemon.count, by: 2).compactMap { bundleKey(daemon[$0]) })
            .filter { (try? ownedReadback(daemon: daemon, disk: disk, bundle: $0, own: own)) != nil }.sorted()
    }

    /// Metadata-only explanation for a real discovered owner rejected by the
    /// existing strict parser. This never creates or repairs a system record.
    static func candidateRejections(daemon: [Any], disk: [Any], bundles: Set<String>, own: String) -> [String: String] {
        var failures = [String: String]()
        func reason(_ array: [Any], bundle: String, source: String, error: Error) -> String {
            if case Failure.ambiguous = error, array.count.isMultiple(of: 2) {
                let count = stride(from: 0, to: array.count, by: 2).filter { bundleKey(array[$0]) == bundle }.count
                return source + (count == 0 ? "-missing" : "-duplicate(count=\(count))")
            }
            return source + "-" + String(describing: error)
        }
        for bundle in bundles.sorted().prefix(64) where eligible(bundle, own: own) {
            var reasons = [String]()
            do { _ = try record(in: daemon, bundle: bundle, own: own) } catch {
                reasons.append(reason(daemon, bundle: bundle, source: "live", error: error))
            }
            do { _ = try record(in: disk, bundle: bundle, own: own) } catch {
                reasons.append(reason(disk, bundle: bundle, source: "file", error: error))
            }
            if !reasons.isEmpty { failures[bundle] = reasons.joined(separator: ";") }
        }
        return failures
    }

    /// A final bounded, value-free schema diagnostic. Exact known identifiers
    /// only; a match is never an ownership or mutation authorization.
    static func catalogShape(in array: [Any], bundle: String, exactValues: Set<String>) -> [String] {
        var budget = 16_384
        var complete = array.count.isMultiple(of: 2) && array.count <= 256
        var opaqueData = 0
        var kinds = [String: Int]()
        var matches = [String]()
        func fields(_ value: Any) -> String {
            guard let dictionary = value as? [String: Any] else { return String(describing: type(of: value)) }
            let known: Set<String> = ["bundle", "_0", "isAllowed", "location", "menuItemLocations"]
            return dictionary.keys.map { known.contains($0) ? $0 : "<opaque-key>" }
                .sorted().prefix(12).joined(separator: ",")
        }
        func inspect(_ value: Any, depth: Int = 0) -> (hits: Int, same: Int, foreign: Int) {
            guard depth < 10, budget > 0 else { complete = false; return (0, 0, 0) }
            budget -= 1
            if let text = value as? String { return (exactValues.contains(text) ? 1 : 0, 0, 0) }
            if value is Data { opaqueData += 1; return (0, 0, 0) }
            if let dictionary = value as? [String: Any] {
                var result = (hits: 0, same: 0, foreign: 0)
                if let owner = bundleKey(dictionary) {
                    if owner == bundle { result.same += 1 } else { result.foreign += 1 }
                }
                for child in dictionary.values {
                    let next = inspect(child, depth: depth + 1)
                    result.hits += next.hits; result.same += next.same; result.foreign += next.foreign
                }
                return result
            }
            var result = (hits: 0, same: 0, foreign: 0)
            for child in value as? [Any] ?? [] {
                let next = inspect(child, depth: depth + 1)
                result.hits += next.hits; result.same += next.same; result.foreign += next.foreign
            }
            return result
        }
        func safeBundle(_ value: String?) -> String {
            guard let value, value.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$", options: .regularExpression) != nil else { return "<unresolved>" }
            return value
        }
        func bundleReferences(_ value: Any, path: String, depth: Int = 0) -> [String] {
            guard depth < 10, budget > 0 else { complete = false; return [] }
            budget -= 1
            if let identifier = bundleKey(value) { return [path + "=" + safeBundle(identifier)] }
            if let dictionary = value as? [String: Any] {
                return dictionary.keys.sorted().flatMap { key in
                    let field = ["bundle", "_0", "isAllowed", "location", "menuItemLocations"].contains(key) ? key : "<opaque-key>"
                    return bundleReferences(dictionary[key] ?? NSNull(), path: path + "." + field, depth: depth + 1)
                }
            }
            return (value as? [Any] ?? []).enumerated().flatMap { index, child in
                bundleReferences(child, path: path + "[\(index)]", depth: depth + 1)
            }
        }
        for index in stride(from: 0, to: min(array.count - array.count % 2, 256), by: 2) {
            let kind = fields(array[index]); kinds[kind, default: 0] += 1
            let key = inspect(array[index]); let value = inspect(array[index + 1])
            if key.hits + value.hits > 0, matches.count < 8 {
                let dictionary = array[index + 1] as? [String: Any] ?? [:]
                let bool = (try? allowed(in: dictionary)).map(String.init) ?? "invalid"
                matches.append("pair=\(index / 2) key_fields=\(kind) value_fields=\(fields(dictionary)) exact_key_hits=\(key.hits) exact_value_hits=\(value.hits) allowed=\(bool) location_fields=\(fields(dictionary["location"] ?? NSNull())) same_refs=\(key.same + value.same) foreign_refs=\(key.foreign + value.foreign)")
                let references = bundleReferences(dictionary["menuItemLocations"] ?? [], path: "menuItemLocations")
                matches.append("matched_group pair=\(index / 2) root_bundle=\(safeBundle(bundleKey(array[index]))) root_location=\(safeBundle(dictionary["location"].flatMap(bundleKey))) references=\(references.prefix(32).joined(separator: ";")) reference_count=\(references.count)")
            }
        }
        let shape = kinds.sorted(by: { $0.key < $1.key }).map { "\($0.key):\($0.value)" }.joined(separator: ";")
        return ["pairs=\(array.count / 2) complete=\(complete) opaque_data=\(opaqueData) key_kinds=\(shape) exact_pairs=\(matches.count / 2)"] + matches
    }

    static func manageableSelection(_ selected: Set<String>, available: [String: Bool]) -> [String] {
        selected.filter { available[$0] == true }.sorted()
    }

    static func sameIdentitySet<Element>(_ lhs: [Element], _ rhs: [Element], equals: (Element, Element) -> Bool) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.allSatisfy { item in lhs.filter { equals(item, $0) }.count == 1 && rhs.filter { equals(item, $0) }.count == 1 }
    }

    /// A positive retained child excluded by the standard visible subset is
    /// different from a missing old proxy. Require an unchanged complete child
    /// set and a previously visible, unaffected witness to reject host rebuilds.
    static func hiddenInVisibleSubset<Element>(
        target: Element,
        baselineChildren: [Element],
        baselineVisible: [Element],
        currentChildren: [Element],
        currentVisible: [Element],
        equals: (Element, Element) -> Bool
    ) -> Bool {
        guard sameIdentitySet(baselineChildren, currentChildren, equals: equals),
            baselineChildren.filter({ equals(target, $0) }).count == 1,
            baselineVisible.filter({ equals(target, $0) }).count == 1,
            !currentVisible.contains(where: { equals(target, $0) }),
            sameIdentitySet(baselineVisible, baselineVisible.filter { node in baselineChildren.contains { equals(node, $0) } }, equals: equals),
            sameIdentitySet(currentVisible, currentVisible.filter { node in currentChildren.contains { equals(node, $0) } }, equals: equals),
            currentVisible.contains(where: { node in !equals(node, target) && baselineVisible.contains { equals(node, $0) } }) else { return false }
        return true
    }

    /// The host can delete only the already bound batch union. All unrelated
    /// first-order objects and a visible sentinel must survive unchanged.
    static func hiddenInHostSubset<Element>(
        targets: [Element],
        baselineChildren: [Element],
        baselineVisible: [Element],
        currentChildren: [Element],
        currentVisible: [Element],
        equals: (Element, Element) -> Bool
    ) -> Bool {
        func isTarget(_ element: Element) -> Bool { targets.contains { equals(element, $0) } }
        guard !targets.isEmpty, sameIdentitySet(targets, targets, equals: equals),
            sameIdentitySet(baselineChildren, baselineChildren, equals: equals),
            sameIdentitySet(currentChildren, currentChildren, equals: equals),
            targets.allSatisfy({ target in baselineChildren.contains { equals(target, $0) } && baselineVisible.contains { equals(target, $0) } }),
            sameIdentitySet(baselineChildren.filter { !isTarget($0) }, currentChildren.filter { !isTarget($0) }, equals: equals),
            sameIdentitySet(baselineVisible, baselineVisible.filter { node in baselineChildren.contains { equals(node, $0) } }, equals: equals),
            sameIdentitySet(currentVisible, currentVisible.filter { node in currentChildren.contains { equals(node, $0) } }, equals: equals),
            !currentVisible.contains(where: isTarget),
            currentVisible.contains(where: { node in !isTarget(node) && baselineVisible.contains { equals(node, $0) } }) else { return false }
        return true
    }

    /// A missing hit or missing name never establishes physical invisibility.
    static func visibilityConfirmed(allowed: Bool, exactHits: Int) -> Bool {
        allowed && exactHits > 0
    }

    static func eligible(_ bundle: String, own: String) -> Bool {
        bundle.contains(".") && !bundle.hasPrefix("com.apple.") && bundle != own
    }

    static func decode(_ data: Data) throws -> [Any] {
        guard data.count <= 262_144,
            let array = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [Any],
            array.count.isMultiple(of: 2) else { throw Failure.unsupported }
        return array
    }

    static func encoded(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { throw Failure.unsupported }
        return value
    }

    static func same(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }

    private static func bundleKey(_ value: Any) -> String? {
        guard let key = value as? [String: Any], key.count == 1,
            let bundle = key["bundle"] as? [String: Any], bundle.count == 1 else { return nil }
        return bundle["_0"] as? String
    }

    private static func verifyLocations(_ value: Any, target: String, depth: Int = 0) throws -> Bool {
        guard depth < 10 else { throw Failure.unsupported }
        if let dict = value as? [String: Any] {
            if dict["bundle"] != nil {
                guard bundleKey(dict) == target else { throw Failure.ownership }
                return true
            }
            var found = false
            for (key, child) in dict {
                if key == "location" {
                    guard bundleKey(child) == target else { throw Failure.ownership }
                    found = true
                } else {
                    found = try verifyLocations(child, target: target, depth: depth + 1) || found
                }
            }
            return found
        }
        if let array = value as? [Any] {
            var found = false
            for child in array { found = try verifyLocations(child, target: target, depth: depth + 1) || found }
            return found
        }
        return false
    }

    static func allowed(in value: [String: Any]) throws -> Bool {
        guard let number = value["isAllowed"] as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Failure.unsupported }
        return number.boolValue
    }

    static func record(in array: [Any], bundle: String, own: String) throws -> Record {
        guard array.count.isMultiple(of: 2) else { throw Failure.unsupported }
        guard eligible(bundle, own: own) else { throw Failure.protectedBundle }
        var indices = [Int]()
        for index in stride(from: 0, to: array.count, by: 2) where bundleKey(array[index]) == bundle {
            indices.append(index + 1)
        }
        guard indices.count == 1, let index = indices.first else { throw Failure.ambiguous }
        guard let value = array[index] as? [String: Any],
            let number = value["isAllowed"] as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID(),
            let location = value["location"], bundleKey(location) == bundle,
            let locations = value["menuItemLocations"] as? [Any] else { throw Failure.unsupported }
        for entry in locations {
            guard try verifyLocations(entry, target: bundle) else { throw Failure.ownership }
        }
        return Record(index: index, value: value, allowed: number.boolValue)
    }

    static func replacing(in array: [Any], bundle: String, own: String, expected: [String: Any], value: [String: Any]) throws -> Data {
        let current = try record(in: array, bundle: bundle, own: own)
        guard current.allowed == (try allowed(in: expected)) else { throw Failure.conflict }
        var updated = current.value
        updated["isAllowed"] = try allowed(in: value)
        var output = array
        output[current.index] = updated
        // Validate the replacement too, including locations and true Bool type.
        _ = try record(in: output, bundle: bundle, own: own)
        return try encoded(output)
    }

    struct LiveReadback {
        let record: Record
        let diskSnapshotMatchesOwnedValue: Bool
    }

    static func ownedReadback(daemon: [Any], disk: [Any], bundle: String, own: String) throws -> LiveReadback {
        let live = try record(in: daemon, bundle: bundle, own: own)
        let file = try record(in: disk, bundle: bundle, own: own)
        // The authorized file snapshot can remain older than the live daemon.
        // Keep both identity/ownership checks, but do not turn a stale snapshot
        // into a failed live operation or copy it over the daemon's new data.
        return LiveReadback(record: live, diskSnapshotMatchesOwnedValue: live.allowed == file.allowed)
    }

    static func targetDiagnostics(in array: [Any], bundle: String) -> [String] {
        guard array.count.isMultiple(of: 2) else { return ["unsupported-array"] }
        func structure(_ value: Any, depth: Int = 0) -> String {
            guard depth < 5 else { return "<nested>" }
            if let owner = bundleKey(value) { return "bundle(\(owner))" }
            if let dictionary = value as? [String: Any] {
                return "{" + dictionary.keys.sorted().prefix(8).map { key in
                    "\(key):\(dictionary[key].map { structure($0, depth: depth + 1) } ?? "missing")"
                }.joined(separator: ",") + "}"
            }
            if let array = value as? [Any] {
                return "[" + array.prefix(4).map { structure($0, depth: depth + 1) }.joined(separator: ",") + "]count=\(array.count)"
            }
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return String(number.boolValue) }
            return "<\(String(describing: type(of: value)))>"
        }
        var lines = [String]()
        for index in stride(from: 0, to: array.count, by: 2) where bundleKey(array[index]) == bundle {
            guard let value = array[index + 1] as? [String: Any] else { continue }
            let allowedValue = (try? allowed(in: value)).map { String($0) } ?? "invalid-type"
            let location = value["location"].map { structure($0) } ?? "missing"
            let locations = value["menuItemLocations"].map { structure($0) } ?? "missing"
            lines.append("pair=\(index)/\(index + 1) allowed=\(allowedValue) location=\(location) menuItemLocations=\(locations)".prefix(1600).description)
            if lines.count == 2 { break }
        }
        return lines
    }

    /// Diagnostic only: never repair or modify another parent's locations.
    static func referencingParents(in array: [Any], target: String) -> [String] {
        guard array.count.isMultiple(of: 2) else { return ["unsupported-array"] }
        func references(_ value: Any, depth: Int = 0) -> Bool {
            guard depth < 10 else { return false }
            if bundleKey(value) == target { return true }
            if let dictionary = value as? [String: Any] {
                return dictionary.values.contains { references($0, depth: depth + 1) }
            }
            return (value as? [Any])?.contains { references($0, depth: depth + 1) } == true
        }
        var matches = [String]()
        for index in stride(from: 0, to: array.count, by: 2) {
            guard let value = array[index + 1] as? [String: Any],
                let locations = value["menuItemLocations"] as? [Any], references(locations) else { continue }
            let parent = bundleKey(array[index]) ?? "<unresolved>"
            let allowedValue = (try? allowed(in: value)).map { String($0) } ?? "invalid-type"
            matches.append("parent=\(parent) allowed=\(allowedValue) pair=\(index)/\(index + 1)")
            if matches.count == 8 { break }
        }
        return matches
    }

    static func hideJournal(record: Record, bundle: String, group: SystemAppVisibilityGroup.InstallationBinding? = nil) throws -> Journal {
        var hidden = record.value
        hidden["isAllowed"] = false
        return Journal(version: group == nil ? 1 : 2, bundle: bundle, original: try encoded(record.value), lastWritten: try encoded(hidden), group: group)
    }

    @MainActor
    static func hide(record: Record, bundle: String, group: SystemAppVisibilityGroup.InstallationBinding? = nil, persist: (Journal) throws -> Void, write: ([String: Any], [String: Any]) async throws -> Bool) async throws -> Bool {
        let journal = try hideJournal(record: record, bundle: bundle, group: group)
        try persist(journal)
        try Task.checkCancellation()
        return try await write(dictionary(journal.lastWritten), record.value)
    }

    @MainActor
    static func restore(journal: Journal, current: Record, write: ([String: Any], [String: Any]) async throws -> Bool, clear: () throws -> Void) async throws -> Bool {
        switch try recovery(journal: journal, current: current) {
        case .alreadyRestored:
            try clear()
            return current.allowed
        case .restore(let value):
            let allowed = try await write(value, current.value)
            try clear()
            return allowed
        case .conflict:
            throw Failure.conflict
        }
    }

    enum Recovery { case alreadyRestored, restore([String: Any]), conflict }

    static func recovery(journal: Journal, current: Record) throws -> Recovery {
        guard journal.version == 1 && journal.group == nil || journal.version == 2 && journal.group != nil else { throw Failure.unsupported }
        let original = try dictionary(journal.original)
        let originalAllowed = try allowed(in: original)
        if current.allowed == originalAllowed { return .alreadyRestored }
        let writtenAllowed = try allowed(in: dictionary(journal.lastWritten))
        guard current.allowed == writtenAllowed else { return .conflict }
        var restored = current.value
        restored["isAllowed"] = originalAllowed
        return .restore(restored)
    }
}
