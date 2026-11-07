import AppKit

enum Constants { static let bundleIdentifier = "FloeBar.Tests" }

@main
enum PrivateLeaseCallbackTests {
    @MainActor static func main() {
        var screens = 1
        let model = ExperimentalPrivateHiding(screenCount: { screens })
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        model.conceal(["test.one"])
        precondition(FBTestLeaseCount() == 0, "disabled mode never creates a lease")
        model.setEnabled(true)
        model.conceal(["test.one"])
        precondition(FBTestLeaseCount() == 1 && !model.active)
        model.release()
        model.conceal(["test.two"])
        FBTestCompleteLease(0, true)
        settle()
        precondition(!model.active && FBTestInvalidations(0) == 2, "late success releases its old lease and cannot mark a replacement active")
        FBTestCompleteLease(1, true)
        settle()
        precondition(model.active)
        FBTestCompleteLease(0, true)
        settle()
        precondition(model.active && FBTestInvalidations(1) == 0, "old completion cannot release an active replacement")
        model.conceal(["test.two"])
        precondition(FBTestLeaseCount() == 2, "an unchanged live plan reuses its lease")
        screens = 2
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        precondition(!model.enabled && !model.active && FBTestInvalidations(1) == 1)
        model.setEnabled(true)
        precondition(!model.enabled && model.failed)
        screens = 1
        model.setEnabled(true)
        model.conceal(["test.three"])
        FBTestCompleteLease(2, false)
        settle()
        precondition(!model.active && model.failed && FBTestInvalidations(2) == 1)
        model.conceal([])
        precondition(!model.active && !model.failed && FBTestLeaseCount() == 3, "undoing the last hidden assignment never starts a lease or reports failure")
        var recoveries = 0
        model.onRecovery = { recoveries += 1 }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.post(name: name, object: nil)
        }
        precondition(recoveries == 4, "recovery clears deferred edits even while editing has no active lease")
        print("PASS: main-actor bridge, late completion isolation, failed activation and multi-display recovery")
    }
}
