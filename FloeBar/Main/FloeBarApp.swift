//
//  FloeBarApp.swift
//  FloeBar
//

import SwiftUI

@main
struct FloeBarApp: App {
    @NSApplicationDelegateAdaptor var appDelegate: AppDelegate

    var body: some Scene {
        SettingsWindow(appDelegate: appDelegate)
        PermissionsWindow(appDelegate: appDelegate)
    }
}
