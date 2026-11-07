import Foundation

@main
struct SystemMenuBarFilePolicyTests {
    static func main() throws {
        let file = SystemMenuBarFilePolicy.expectedURL
        precondition(SystemMenuBarFilePolicy.accepts(file))
        precondition(!SystemMenuBarFilePolicy.accepts(file.deletingLastPathComponent()))
        precondition(!SystemMenuBarFilePolicy.accepts(file.deletingLastPathComponent().appendingPathComponent("other.plist")))
        enum AccessError: Error { case denied }
        let grantFixture = try PropertyListSerialization.data(fromPropertyList: ["trackedApplications": Data()], format: .binary, options: 0)
        var renewals = 0
        _ = try SystemMenuBarFilePolicy.validateAccess(url: file, stale: true, read: { grantFixture }, renew: { renewals += 1 })
        precondition(renewals == 1)
        _ = try SystemMenuBarFilePolicy.validateAccess(url: file, stale: false, read: { grantFixture }, renew: { renewals += 1 })
        precondition(renewals == 1)
        do {
            _ = try SystemMenuBarFilePolicy.validateAccess(url: file, stale: true, read: { throw AccessError.denied }, renew: { renewals += 1 })
            preconditionFailure("Unreadable stale target renewed")
        } catch {}
        precondition(renewals == 1)
        var readWrongTarget = false
        do {
            _ = try SystemMenuBarFilePolicy.validateAccess(url: file.deletingLastPathComponent(), stale: true, read: { readWrongTarget = true; return grantFixture }, renew: { renewals += 1 })
            preconditionFailure("Wrong target authorized")
        } catch {}
        precondition(!readWrongTarget && renewals == 1)
        let fixture: [String: Any] = ["Tracked": [
            ["bundle": "com.figma.Desktop", "allowed": true],
            ["bundle": "org.unrelated.app", "privateValue": "MUST_NOT_LOG"],
            ["bundle": "io.github.jackfloyd007.IceEric", "allowed": true],
        ], "unknown": ["nested": [1, 2, 3]]]
        let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
        let lines = try SystemMenuBarFilePolicy.inspect(data, own: "io.github.jackfloyd007.IceEric")
        let summary = lines.joined(separator: "\n")
        precondition(lines.count <= 6)
        precondition(summary.contains("com.figma.Desktop") && summary.contains("io.github.jackfloyd007.IceEric"))
        precondition(!summary.contains("MUST_NOT_LOG") && !summary.contains("org.unrelated.app"))
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let nested = try PropertyListSerialization.data(fromPropertyList: fixture["Tracked"] as Any, format: format, options: 0)
            let outer = try PropertyListSerialization.data(fromPropertyList: ["trackedApplications": nested], format: .binary, options: 0)
            let summary = try SystemMenuBarFilePolicy.inspect(outer, own: "io.github.jackfloyd007.IceEric").joined(separator: "\n")
            precondition(summary.contains("format=plist") && summary.contains("com.figma.Desktop"))
            precondition(!summary.contains("MUST_NOT_LOG"))
        }
        let nestedJSON = try JSONSerialization.data(withJSONObject: fixture["Tracked"] as Any)
        let outerJSON = try PropertyListSerialization.data(fromPropertyList: ["trackedApplications": nestedJSON], format: .binary, options: 0)
        let jsonSummary = try SystemMenuBarFilePolicy.inspect(outerJSON, own: "io.github.jackfloyd007.IceEric").joined(separator: "\n")
        precondition(jsonSummary.contains("format=json") && jsonSummary.contains("com.figma.Desktop"))
        let archive = try NSKeyedArchiver.archivedData(withRootObject: ["bundle": "com.figma.Desktop", "allowed": true], requiringSecureCoding: false)
        let outerArchive = try PropertyListSerialization.data(fromPropertyList: ["trackedApplications": archive], format: .binary, options: 0)
        let archiveSummary = try SystemMenuBarFilePolicy.inspect(outerArchive, own: "own").joined(separator: "\n")
        precondition(archiveSummary.contains("archive target index="))
        do {
            let invalid = try PropertyListSerialization.data(fromPropertyList: ["wrong-root"], format: .binary, options: 0)
            _ = try SystemMenuBarFilePolicy.inspect(invalid, own: "own")
            preconditionFailure("Invalid root accepted")
        } catch {}
        let permission = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EPERM.rawValue))])
        var reads = 0
        var reopens = 0
        let fresh = Data("fresh scoped data".utf8)
        let reopened = try SystemMenuBarFilePolicy.readSnapshot(url: SystemMenuBarFilePolicy.expectedURL, read: { reads += 1; throw permission }, reopen: { reopens += 1; return fresh })
        precondition(reopened == fresh && reads == 1 && reopens == 1)
        do { _ = try SystemMenuBarFilePolicy.readSnapshot(url: SystemMenuBarFilePolicy.expectedURL, read: { reads += 1; throw permission }, reopen: { reopens += 1; throw permission }); preconditionFailure() } catch {}
        precondition(reads == 2 && reopens == 2)
        let before = reopens
        for error in [NSError(domain: NSCocoaErrorDomain, code: NSPropertyListReadCorruptError), NSError(domain: NSPOSIXErrorDomain, code: 1), NSError(domain: NSCocoaErrorDomain, code: 257)] {
            do { _ = try SystemMenuBarFilePolicy.readSnapshot(url: SystemMenuBarFilePolicy.expectedURL, read: { throw error }, reopen: { reopens += 1; return fresh }); preconditionFailure() } catch {}
        }
        do { _ = try SystemMenuBarFilePolicy.readSnapshot(url: URL(fileURLWithPath: "/tmp/wrong.plist"), read: { throw permission }, reopen: { reopens += 1; return fresh }); preconditionFailure() } catch {}
        precondition(reopens == before)
        print("PASS: exact file authorization, bounded target-only inspection, invalid root rejection")
    }
}
