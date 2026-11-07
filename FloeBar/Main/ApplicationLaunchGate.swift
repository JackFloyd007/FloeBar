//
//  ApplicationLaunchGate.swift
//  FloeBar
//

import AppKit
import OSLog

/// Runs after AppKit finishes launching. The delegate keeps AppState nil and
/// all working scene content absent until the user resolves this native gate.
@MainActor
enum ApplicationLaunchGate {
    private static let logger = Logger(category: "ApplicationLaunchGate")

    private static func identity(_ app: NSRunningApplication) -> ApplicationLaunchPolicy.Instance {
        ApplicationLaunchPolicy.Instance(
            pid: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier ?? "",
            launchedAt: app.launchDate
        )
    }

    private static func predecessors() -> [NSRunningApplication] {
        let applications = NSWorkspace.shared.runningApplications
        let earlier = ApplicationLaunchPolicy.predecessors(
            of: identity(.current), among: applications.map(identity)
        )
        return earlier.compactMap { candidate in
            applications.first { $0.processIdentifier == candidate.pid && !$0.isTerminated }
        }
    }

    private static func details(_ app: NSRunningApplication, current: Bool) -> String {
        let bundle = app.bundleURL.flatMap(Bundle.init(url:))
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let path = app.bundleURL?.path ?? app.localizedName ?? "FloeBar"
        let format = current
            ? String(localized: "This version: %@ (%@)\n%@")
            : String(localized: "Running version: %@ (%@)\n%@")
        return String(format: format, version, build, path)
    }

    static func mayStart() -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return true }
        #endif
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == NSRunningApplication.current.bundleIdentifier &&
                $0.processIdentifier != NSRunningApplication.current.processIdentifier && !$0.isTerminated
        }
        if ApplicationLaunchPolicy.hasUnverifiedStartOrder(
            current: identity(.current), among: applications.map(identity)
        ) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Another version of FloeBar is running")
            alert.informativeText = String(localized: "The start order could not be verified. Close the other version, then open this version again.") +
                "\n\n" + ([details(.current, current: true)] + applications.map { details($0, current: false) }).joined(separator: "\n\n")
            alert.addButton(withTitle: String(localized: "Keep Running Version"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            NSApplication.shared.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { applications.first?.activate() }
            return false
        }
        let earlier = predecessors()
        guard !earlier.isEmpty else { return true }
        logger.notice("Launch conflict with \(earlier.count, privacy: .public) earlier FloeBar process(es)")
        let alert = NSAlert()
        alert.messageText = String(localized: "Another version of FloeBar is running")
        alert.informativeText = String(localized: "Choose which version to use. This version will not start menu bar controls until the other version has quit.") +
            "\n\n" + ([details(.current, current: true)] + earlier.map { details($0, current: false) }).joined(separator: "\n\n")
        alert.addButton(withTitle: String(localized: "Keep Running Version"))
        alert.addButton(withTitle: String(localized: "Use This Version"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else {
            if response == .alertFirstButtonReturn { earlier.first?.activate() }
            return false
        }
        // One normal request per process; pumping the run loop lets AppKit
        // deliver lifecycle events without blocking a MainActor Task/semaphore.
        for app in earlier where !app.isTerminated {
            let result = ApplicationLaunchPolicy.requestExit(
                request: app.terminate,
                isTerminated: { app.isTerminated },
                now: { ProcessInfo.processInfo.systemUptime },
                waitStep: { _ = RunLoop.current.run(mode: .default, before: Date.now.addingTimeInterval(0.05)) }
            )
            guard result == .exited else { return reportRefusal() }
        }
        guard predecessors().isEmpty else { return reportRefusal() }
        return true
    }

    private static func reportRefusal() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "The running version did not quit")
        alert.informativeText = String(localized: "This version will close without starting. Close the other version and try again. No application will be force quit.")
        alert.runModal()
        return false
    }
}
