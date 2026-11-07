//
//  PermissionsWindow.swift
//  Ice
//

import SwiftUI

struct PermissionsWindow: Scene {
    @ObservedObject var appDelegate: AppDelegate

    var body: some Scene {
        IceWindow(id: .permissions) {
            if let appState = appDelegate.appState {
                PermissionsView()
                    .onWindowChange { window in
                        guard let window else {
                            return
                        }
                        window.standardWindowButton(.closeButton)?.isHidden = true
                        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                        window.standardWindowButton(.zoomButton)?.isHidden = true
                        if let contentView = window.contentView {
                            withMutableCopy(of: contentView.safeAreaInsets) { insets in
                                insets.bottom = -insets.bottom
                                insets.left = -insets.left
                                insets.right = -insets.right
                                insets.top = -insets.top
                                contentView.additionalSafeAreaInsets = insets
                            }
                        }
                    }
                    .environmentObject(appState)
                    .environmentObject(appState.permissions)
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
