import AppKit
import OSLog

// Permission checks are injected; no system permission request is made.
enum AXHelpers {
    static var granted = false
    @discardableResult static func isProcessTrusted(prompt: Bool = false) -> Bool { granted }
}
enum ScreenCapture {
    static var granted = false
    static var cached: Bool?
    static func cachedCheckPermissions(reset: Bool = false) -> Bool {
        if reset { cached = nil }
        if let cached { return cached }
        cached = granted
        return granted
    }
    static func requestPermissions() { }
}
extension Logger {
    init(category: String) { self.init(subsystem: "FloeBar.Tests", category: category) }
}

@main
enum PermissionRecoveryTests {
    @MainActor static func pump(_ duration: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    @MainActor static func main() {
        var granted = false
        var checks = 0
        var requests = 0
        let permission = Permission(title: "Test", details: [], isRequired: true, settingsURL: nil,
            check: { checks += 1; return granted }, request: { requests += 1 })
        permission.stopCheck()
        granted = true
        permission.performRequest()
        precondition(permission.hasPermission && requests == 1, "request must recover a stopped observer immediately")
        permission.performRequest()
        permission.performRequest(openSettings: false)
        precondition(requests == 3, "Only explicit requests invoke the request closure")
        let baseline = checks
        granted = false
        pump(1.15)
        precondition(!permission.hasPermission && checks == baseline + 1, "repeated requests must keep exactly one timer")
        permission.stopCheck()
        let stoppedChecks = checks
        pump(1.1)
        precondition(checks == stoppedChecks && requests == 3)

        let manager = AppPermissions()
        manager.stopAllChecks()
        var recordingUpdates = 0
        let recordingObservation = manager.screenRecording.$hasPermission.dropFirst().sink { _ in recordingUpdates += 1 }
        precondition(manager.permissionsState == .missing)
        precondition(ScreenCapture.cached == false)
        AXHelpers.granted = true
        ScreenCapture.granted = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        pump()
        precondition(manager.permissionsState == .hasAll && ScreenCapture.cached == true && recordingUpdates == 1)
        ScreenCapture.granted = false
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        pump()
        precondition(manager.permissionsState == .hasRequired && ScreenCapture.cached == false && recordingUpdates == 2)
        AXHelpers.granted = false
        manager.refreshAll()
        precondition(manager.permissionsState == .missing)
        withExtendedLifetime(recordingObservation) {}
        print("PASS: permission request recovery, timer replacement, foreground grant/revoke and capture cache refresh")
    }
}
