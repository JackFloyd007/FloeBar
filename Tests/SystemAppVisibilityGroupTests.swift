import Foundation

@main
struct SystemAppVisibilityGroupTests {
    typealias G = SystemAppVisibilityGroup
    typealias M = SystemAppVisibilityModel
    static let root = "io.test.root"
    static let helper = "io.test.helper"
    static let own = "io.test.floebar"
    static func key(_ bundle: String) -> [String: Any] { ["bundle": ["_0": bundle]] }
    static func array(root: String = root, member: String = helper, allowed: Any = true) -> [Any] {
        [key(root), ["isAllowed": allowed, "location": key(root), "menuItemLocations": [["location": key(member), "order": 4]]]]
    }
    static func main() throws {
        let live = array()
        let descriptor = try G.discover(daemon: live, disk: array(allowed: false), source: helper, own: own)!
        precondition(descriptor.root == root && descriptor.members == [root, helper])
        precondition(tryRecord(live, descriptor))
        do { _ = try M.record(in: live, bundle: root, own: own); preconditionFailure("exact root policy was weakened") } catch {}
        do { _ = try G.discover(daemon: live + array(root: "io.other.root"), disk: live, source: helper, own: own); preconditionFailure() } catch {}
        do { _ = try G.discover(daemon: live, disk: array(member: "io.foreign.helper"), source: helper, own: own); preconditionFailure() } catch {}
        do { _ = try G.discover(daemon: live, disk: live + array(root: "io.other.root"), source: helper, own: own); preconditionFailure() } catch {}
        let duplicateRoot = try? G.discover(daemon: live + live, disk: live, source: helper, own: own)
        precondition(duplicateRoot == nil)
        do { _ = try G.declaration(in: array(member: "com.apple.helper"), root: root, own: own); preconditionFailure() } catch {}
        do { _ = try G.declaration(in: array(allowed: 1), root: root, own: own); preconditionFailure() } catch {}
        let absent = try G.discover(daemon: live, disk: live, source: "io.same.team.other", own: own)
        precondition(absent == nil, "names, team or nearby apps cannot create a system group")
        let foreign = try G.declaration(in: array(member: "io.foreign.helper"), root: root, own: own)
        do { _ = try G.record(in: live, target: foreign, own: own); preconditionFailure() } catch {}
        print("PASS: typed system group declarations only, double-source membership, exact policy retained, duplicate/protected/foreign groups rejected")
    }
    static func tryRecord(_ array: [Any], _ descriptor: G.Descriptor) -> Bool { (try? G.record(in: array, target: descriptor, own: own).allowed) == true }
}
