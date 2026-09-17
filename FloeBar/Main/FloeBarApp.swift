//
//  FloeBarApp.swift
//  FloeBar
//

import SwiftUI

@main
struct FloeBarApp: App {
    @NSApplicationDelegateAdaptor var appDelegate: AppDelegate

    var body: some Scene {
        SettingsWindow(appState: appDelegate.appState)
        PermissionsWindow(appState: appDelegate.appState)
    }
}
