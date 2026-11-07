//
//  AppDelegate.swift
//  Ice
//

import OSLog
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// The shared app state.
    private var launchLifecycle = ApplicationLaunchLifecycle()
    private var didScheduleLaunchResolution = false
    private var isWaitingForVisibilityRecovery = false
    private var pendingAppState: AppState?
    private var startupRecoveryTask: Task<Void, Never>?
    @Published private(set) var appState: AppState?

    // MARK: NSApplicationDelegate Methods

    private func authorizeStartup() {
        guard !launchLifecycle.isAuthorized else { return }
        performLaunchEffects(launchLifecycle.authorize())
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        performLaunchEffects(launchLifecycle.willFinish())
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        performLaunchEffects(launchLifecycle.didFinish())
        guard !didScheduleLaunchResolution else { return }
        didScheduleLaunchResolution = true
        // Finish the AppKit/LaunchServices launch before running a native modal
        // dialog. All scene content stays empty until AppState is published.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard ApplicationLaunchGate.mayStart() else {
                NSApp.terminate(nil)
                return
            }
            authorizeStartup()
        }
    }

    private func performLaunchEffects(_ effects: [ApplicationLaunchLifecycle.Effect]) {
        guard launchLifecycle.isAuthorized, !effects.isEmpty else { return }
        let state = appState ?? pendingAppState ?? AppState()
        for effect in effects {
            switch effect {
            case .migrate:
                NSSplitViewItem.swizzle()
                MigrationManager(appState: state).migrateAll()
            case .setup:
                guard startupRecoveryTask == nil, appState == nil else { continue }
                pendingAppState = state
                startupRecoveryTask = Task { [weak self] in
                    await state.menuBarManager.appVisibilityAccess.checkSavedAccess()
                    guard let self else { return }
                    defer { startupRecoveryTask = nil }
                    // A quit waiting on startup owns the pending state. Never
                    // expose work views or start scans during that wait.
                    guard !isWaitingForVisibilityRecovery else { return }
                    completeAuthorizedStartup(state)
                }
            }
        }
    }

    private func completeAuthorizedStartup(_ state: AppState) {
        guard appState == nil else { return }
        finishAuthorizedLaunch(appState: state)
        appState = state
        pendingAppState = nil
    }

    private func finishAuthorizedLaunch(appState: AppState) {
        // Hide the main menu's items to add additional space to the
        // menu bar when we are the focused app.
        for item in NSApp.mainMenu?.items ?? [] {
            item.isHidden = true
        }

        // Allow hiding the mouse while the app is in the background
        // to make menu bar item movement less jarring.
        Bridging.setConnectionProperty(true, forKey: "SetsCursorInBackground")

        #if DEBUG
        // Don't perform setup if running as a preview.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return
        }
        #endif

        // Depending on the permissions state, either perform setup
        // or prompt to grant permissions.
        switch appState.permissions.permissionsState {
        case .hasAll:
            appState.permissions.logger.debug("Passed all permissions checks")
            appState.performSetup(hasPermissions: true)
        case .hasRequired:
            appState.permissions.logger.debug("Passed required permissions checks")
            appState.performSetup(hasPermissions: true)
        case .missing:
            appState.permissions.logger.debug("Failed required permissions checks")
            appState.performSetup(hasPermissions: false)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = appState ?? pendingAppState else { return .terminateNow }
        let access = state.menuBarManager.appVisibilityAccess
        guard access.needsTerminationRecovery || startupRecoveryTask != nil else { return .terminateNow }
        guard !isWaitingForVisibilityRecovery else { return .terminateLater }
        isWaitingForVisibilityRecovery = true
        access.beginTermination()
        let pendingStartup = startupRecoveryTask
        Task { [weak self] in
            if let pendingStartup { await pendingStartup.value }
            let restored = await access.prepareForTermination()
            self?.isWaitingForVisibilityRecovery = false
            if !restored {
                self?.completeAuthorizedStartup(state)
                let alert = NSAlert()
                alert.messageText = String(localized: "Application visibility could not be restored.")
                alert.informativeText = String(localized: "FloeBar is still running and kept its recovery record. Check file access, then try quitting again.")
                alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: restored)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard launchLifecycle.isAuthorized, appState != nil else { return true }
        Logger.default.debug("Handling reopen")
        openSettingsWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard launchLifecycle.isAuthorized, let appState else { return false }
        if
            sender.isActive,
            sender.activationPolicy() != .accessory,
            appState.navigationState.isAppFrontmost
        {
            Logger.default.debug("All windows closed - deactivating with accessory activation policy")
            appState.deactivate(withPolicy: .accessory)
        }
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: Other Methods

    /// Opens the settings window and activates the app.
    @objc func openSettingsWindow() {
        guard launchLifecycle.isAuthorized, let appState else { return }
        // Delay makes this more reliable for some reason.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [appState] in
            appState.activate(withPolicy: .regular)
            appState.openWindow(.settings)
        }
    }
}
