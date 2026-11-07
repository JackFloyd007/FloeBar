//
//  SystemMenuBarFilePolicy.swift
//  FloeBar
//

import Foundation

/// Exact-file authorization and bounded, value-minimizing schema inspection.
/// There is intentionally no system write operation in this access phase.
enum SystemMenuBarFilePolicy {
    static var expectedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist"
        )
    }

    static func accepts(_ url: URL) -> Bool {
        url.standardizedFileURL.resolvingSymlinksInPath() == expectedURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Reopen only the exact, already-authorized file after the observed file
    /// permission transition. No parse/readback/write operation is replayed.
    static func readSnapshot(url: URL, read: () throws -> Data, reopen: () throws -> Data) throws -> Data {
        guard accepts(url) else { throw CocoaError(.fileReadNoPermission) }
        do { return try read() } catch let original {
            let cocoa = original as NSError
            let underlying = cocoa.userInfo[NSUnderlyingErrorKey] as? NSError
            guard cocoa.domain == NSCocoaErrorDomain, cocoa.code == NSFileReadNoPermissionError,
                underlying?.domain == NSPOSIXErrorDomain, underlying?.code == Int(POSIXErrorCode.EPERM.rawValue) else { throw original }
            do { return try reopen() } catch { throw original }
        }
    }

    /// A stale bookmark may be renewed only after its exact target is actually
    /// readable. Failed scope access never grants or broadens file access.
    static func validateAccess(url: URL, stale: Bool, read: () throws -> Data, renew: () throws -> Void) throws -> Data {
        guard accepts(url) else { throw CocoaError(.fileReadNoPermission) }
        let data = try read()
        guard data.count <= 262_144,
            let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            root["trackedApplications"] is Data else { throw CocoaError(.propertyListReadCorrupt) }
        if stale { try renew() }
        return data
    }

    static func inspect(_ data: Data, own: String) throws -> [String] {
        guard data.count <= 262_144 else { throw CocoaError(.propertyListReadCorrupt) }
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let root = plist as? [String: Any] else { throw CocoaError(.propertyListReadCorrupt) }
        var shapes = Set<String>()
        var targets = Set<String>()
        var formats = Set<String>()
        var decodedBytes = 0
        func isTarget(_ text: String) -> Bool { text == "com.figma.Desktop" || text == own }
        func safeDescription(_ value: Any, depth: Int = 0) -> String {
            guard depth < 4 else { return "<nested>" }
            if let data = value as? Data { return "<Data bytes=\(data.count)>" }
            if let dict = value as? [String: Any] {
                return dict.keys.sorted().prefix(16).map { key in
                    "\(key)=\(dict[key].map { safeDescription($0, depth: depth + 1) } ?? "missing")"
                }.joined(separator: ";").prefix(1600).description
            }
            if let array = value as? [Any] { return "<Array count=\(array.count)>" }
            return String(describing: value).prefix(256).description
        }
        func visit(_ value: Any, path: String, depth: Int, mayDecode: Bool) {
            guard depth < 10 else { return }
            if let data = value as? Data, mayDecode {
                guard data.count <= 262_144, decodedBytes + data.count <= 524_288 else {
                    formats.insert("data path=\(path) over-budget")
                    return
                }
                decodedBytes += data.count
                if let nested = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                    formats.insert("data path=\(path) format=plist bytes=\(data.count)")
                    // Convert archive UIDs to ordinary plist XML structure only;
                    // never instantiate classes or invoke NSKeyedUnarchiver.
                    let normalized = (try? PropertyListSerialization.data(fromPropertyList: nested, format: .xml, options: 0))
                        .flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) } ?? nested
                    visit(normalized, path: path + "/plist", depth: depth + 1, mayDecode: true)
                } else if let nested = try? JSONSerialization.jsonObject(with: data) {
                    formats.insert("data path=\(path) format=json bytes=\(data.count)")
                    visit(nested, path: path + "/json", depth: depth + 1, mayDecode: true)
                } else {
                    formats.insert("data path=\(path) format=unsupported bytes=\(data.count)")
                }
            } else if let dict = value as? [String: Any] {
                let fields = dict.keys.filter { !$0.contains(".") }.sorted().prefix(16).map { key in
                    "\(key):\(dict[key].map { String(describing: type(of: $0)) } ?? "missing")"
                }.joined(separator: ",")
                if shapes.count < 4 { shapes.insert("path=\(path) fields=\(fields)") }
                if dict.values.contains(where: { ($0 as? String).map(isTarget) == true }), targets.count < 4 {
                    targets.insert("path=\(path) " + safeDescription(dict))
                }
                if let objects = dict["$objects"] as? [Any] {
                    let indices = objects.indices.filter { (objects[$0] as? String).map(isTarget) == true }
                    for index in indices.prefix(2) {
                        targets.insert("archive target index=\(index) value=\(objects[index])")
                        for (refIndex, object) in objects.enumerated() {
                            guard let entry = object as? [String: Any] else { continue }
                            func references(_ value: Any, depth: Int = 0) -> Bool {
                                guard depth < 10 else { return false }
                                if let ref = value as? [String: Any] {
                                    if let number = ref["CF$UID"] as? NSNumber, number.intValue == index { return true }
                                    return ref.values.contains { references($0, depth: depth + 1) }
                                }
                                return (value as? [Any])?.contains { references($0, depth: depth + 1) } == true
                            }
                            if references(entry), targets.count < 6 {
                                targets.insert("archive referring index=\(refIndex) " + safeDescription(entry))
                            }
                        }
                    }
                }
                for key in dict.keys.sorted() {
                    guard let entry = dict[key] else { continue }
                    if isTarget(key), targets.count < 4 {
                        targets.insert("path=\(path)/\(key) \(safeDescription(entry))")
                    } else {
                        let component = key.contains(".") ? "<application-key>" : key
                        visit(entry, path: path + "/" + component, depth: depth + 1, mayDecode: mayDecode || key == "trackedApplications")
                    }
                }
            } else if let array = value as? [Any] {
                for (index, entry) in array.enumerated() {
                    visit(entry, path: path + "/[\(index)]", depth: depth + 1, mayDecode: mayDecode)
                }
            }
        }
        visit(root, path: "root", depth: 0, mayDecode: false)
        return Array(formats.sorted().prefix(4)) + shapes.sorted().map { "schema " + $0 } + targets.sorted().prefix(6).map { "target " + $0 }
    }
}
