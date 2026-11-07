import Foundation
@main enum Tests {
    static func main() {
        func plan(_ hidden: [String?], _ visible: [String?] = []) -> Set<String>? {
            PrivateHidingPlan.targets(hidden: hidden, visible: visible, own: "floe")
        }
        precondition(plan(["app.a", "app.a"]) == ["app.a"])
        precondition(plan(["app.a"], ["app.a"]) == nil)
        precondition(plan(["com.apple.MenuBarAgent"]) == nil)
        precondition(plan(["com.apple.Passwords"]) == nil)
        precondition(!PrivateHidingPlan.supports(bundle: "com.apple.Passwords.MenuBarExtra", own: "floe"))
        precondition(!PrivateHidingPlan.supports(bundle: nil, own: "floe"))
        precondition(!PrivateHidingPlan.supports(bundle: "", own: "floe"))
        precondition(!PrivateHidingPlan.supports(bundle: "floe", own: "floe"))
        precondition(PrivateHidingPlan.supports(bundle: "org.example.app", own: "floe"))
        precondition(plan(["floe"]) == nil)
        precondition(plan([nil, "app.a"]) == nil)
        precondition(plan([]) == [], "removing the last target is an empty plan, not an invalid owner")
        precondition(plan([""]) == nil)
        precondition(plan(["app.a"], ["app.b"]) == ["app.a"])
        print("PASS: private hiding rejects mixed ownership, unknown owners and protected hosts; empty plans release")
    }
}
