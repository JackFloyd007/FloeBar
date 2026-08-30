//
//  MenuBarLayoutSettingsPane.swift
//  Ice
//

import SwiftUI

struct MenuBarLayoutSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var itemManager: MenuBarItemManager

    private var hasItems: Bool {
        !itemManager.itemCache.managedItems.isEmpty
    }

    var body: some View {
        if appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            cannotArrange
        } else if !ScreenCapture.cachedCheckPermissions() {
            missingScreenRecordingPermissions
        } else {
            layoutContent
        }
    }

    private var layoutContent: some View {
        IceForm(spacing: 20) {
            header
            layoutBars
        }
        .onAppear {
            if #available(macOS 27.0, *) {
                // Concealed hosted items have no live AX element and cannot be
                // reordered reliably. Reveal them once for the whole editing
                // session instead of flashing the bar around every drag.
                appState.menuBarManager.macOS27Controller.beginLayoutEditing()
                appState.imageCache.removeSemanticReplicas()
                Task {
                    // Let MenuBarAgent finish exposing hosted scenes before
                    // refreshing AX geometry and taking exact display-strip
                    // crops for the Layout tiles.
                    try? await Task.sleep(for: .milliseconds(450))
                    await itemManager.cacheItemsRegardless()
                    await appState.imageCache.updateCacheWithoutChecks(
                        sections: MenuBarSection.Name.allCases
                    )
                }
            }
        }
        .onDisappear {
            if #available(macOS 27.0, *) {
                appState.menuBarManager.macOS27Controller.endLayoutEditing()
                appState.menuBarManager.syncMacOS27Visibility()
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        IceSection {
            VStack(spacing: 3) {
                Text("Drag to arrange your menu bar items into different sections.")
                    .font(.title3.bold())
                Text("Items can also be arranged by ⌘ Command + dragging them in the menu bar.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(15)
        }
    }

    @ViewBuilder
    private var layoutBars: some View {
        VStack(spacing: 20) {
            ForEach(MenuBarSection.Name.allCases, id: \.self) { section in
                layoutBar(for: section)
            }
        }
        .opacity(hasItems ? 1 : 0.75)
        .blur(radius: hasItems ? 0 : 5)
        .allowsHitTesting(hasItems)
        .overlay {
            if !hasItems {
                loadingMenuBarItems
            }
        }
    }

    @ViewBuilder
    private var cannotArrange: some View {
        Text("Ice cannot arrange menu bar items in automatically hidden menu bars.")
            .font(.title3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var missingScreenRecordingPermissions: some View {
        VStack {
            Text("Menu bar layout requires screen recording permissions.")
                .font(.title2)

            Button {
                appState.navigationState.settingsNavigationIdentifier = .advanced
            } label: {
                Text("Go to Advanced Settings")
            }
            .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private var loadingMenuBarItems: some View {
        VStack {
            Text("Loading menu bar items…")
            ProgressView()
        }
        .font(.title)
    }

    @ViewBuilder
    private func layoutBar(for name: MenuBarSection.Name) -> some View {
        if
            let section = appState.menuBarManager.section(withName: name),
            section.isEnabled
        {
            VStack(alignment: .leading) {
                Text(name.localized)
                    .font(.headline)
                    .padding(.leading, 8)

                LayoutBar(imageCache: appState.imageCache, section: name)
            }
        }
    }
}
