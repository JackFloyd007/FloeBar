//
//  MenuBarLayoutSettingsPane.swift
//  Ice
//

import SwiftUI

struct MenuBarLayoutSettingsPane: View {
    private enum WorkspacePage: Hashable { case order, applications }

    @EnvironmentObject var appState: AppState
    @ObservedObject var itemManager: MenuBarItemManager
    @State private var page = WorkspacePage.applications

    var body: some View {
        if #available(macOS 27.0, *), appState.menuBarManager.usesSystemOverflow {
            VStack(spacing: 0) {
                Picker("Menu Bar Layout", selection: $page) {
                    Text("Icon Order").tag(WorkspacePage.order)
                    Text("Application hiding").tag(WorkspacePage.applications)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                Divider()

                switch page {
                case .order:
                    MenuBarOrderSettingsPane(itemManager: itemManager, screenRecording: appState.permissions.screenRecording)
                case .applications:
                    SystemAppVisibilityAccessView(access: appState.menuBarManager.appVisibilityAccess)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            MenuBarOrderSettingsPane(itemManager: itemManager, screenRecording: appState.permissions.screenRecording)
        }
    }
}

/// The original ordering surface owns its AX/image tasks only while mounted.
private struct MenuBarOrderSettingsPane: View {
    private enum LoadState {
        case loading, finished, timedOut
    }

    @EnvironmentObject var appState: AppState
    @ObservedObject var itemManager: MenuBarItemManager
    @ObservedObject var screenRecording: ScreenRecordingPermission
    @State private var loadState = LoadState.loading
    @State private var refreshID = 0
    @State private var previewRequest = MenuBarPreviewRequest()
    @State private var previewFeedback: String?
    @State private var isLoadingPreviews = false

    private var hasItems: Bool {
        !itemManager.itemCache.managedItems.isEmpty
    }

    var body: some View {
        if appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            cannotArrange
        } else if #available(macOS 27.0, *) {
            layoutContent
        } else if !ScreenCapture.cachedCheckPermissions() {
            missingScreenRecordingPermissions
        } else {
            layoutContent
        }
    }

    private var layoutContent: some View {
        IceForm(alignment: .leading, spacing: 24) {
            if #unavailable(macOS 27.0) { header }
            if #available(macOS 27.0, *) {
                Label("Drag to reorder.", systemImage: "hand.draw")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if #available(macOS 27.0, *) { previewControls }
            layoutBars
            if #available(macOS 27.0, *) {
                // IceForm is top-aligned. Feedback grows below the fixed item
                // region so progress/results cannot move the next drag target.
                reorderStatus
            }
        }
        .task(id: refreshID) {
            loadState = .loading
            if #available(macOS 27.0, *) {
                appState.menuBarManager.macOS27Controller.beginLayoutEditing()
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            await itemManager.cacheItemsRegardless(
                ignoringRecentMovement: true,
                refreshingAllOwners: true
            )
            guard !Task.isCancelled else { return }
            loadState = .finished
            if #unavailable(macOS 27.0) {
                await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
            }
        }
        .task(id: previewRequest.id) {
            guard previewRequest.consume(in: appState.menuBarManager.macOS27Controller.interactionGeneration) else { return }
            isLoadingPreviews = true
            defer { isLoadingPreviews = false }
            let loaded = await appState.imageCache.updateCacheWithoutChecks(
                sections: MenuBarSection.Name.allCases,
                userInitiatedPreview: true
            )
            guard !Task.isCancelled else { return }
            screenRecording.refresh()
            if !screenRecording.hasPermission {
                previewFeedback = String(localized: "Screen Recording permission is required only for icon previews.")
            } else {
                previewFeedback = loaded
                    ? String(localized: "Icon previews loaded.")
                    : String(localized: "No icon preview was produced. You can still reorder using application icons.")
            }
        }
        .task(id: refreshID) {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            // A nonresponsive AX owner must not leave an endless spinner.
            if loadState == .loading { loadState = .timedOut }
        }
        .onDisappear {
            previewRequest.discard()
            itemManager.cancelLayoutReads()
            itemManager.endLayoutOverflowRecovery()
            if #available(macOS 27.0, *) {
                appState.menuBarManager.macOS27Controller.endLayoutEditing()
            }
        }
    }

    private var previewControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if screenRecording.hasPermission {
                    Button("Load / Refresh Icon Previews") {
                        previewFeedback = nil
                        appState.menuBarManager.macOS27Controller.beginLayoutEditing()
                        previewRequest.issue(in: appState.menuBarManager.macOS27Controller.interactionGeneration)
                    }
                } else {
                    Text("Screen Recording permission is required only for icon previews.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Request Screen Recording") {
                        let permission = screenRecording
                        permission.refresh()
                        if !permission.hasPermission { permission.performRequest(openSettings: false) }
                    }
                }
                if isLoadingPreviews { ProgressView().controlSize(.small) }
            }
            .disabled(isLoadingPreviews || loadState != .finished)
            if let previewFeedback {
                Text(verbatim: previewFeedback).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

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
        if hasItems {
            VStack(alignment: .leading, spacing: 22) {
                if appState.menuBarManager.usesSystemOverflow {
                    VStack(alignment: .leading, spacing: 10) {
                        LayoutBar(
                            imageCache: appState.imageCache,
                            section: .visible,
                            isEmpty: itemManager.itemCache.managedItems.isEmpty
                        )
                    }
                } else {
                    ForEach(MenuBarSection.Name.allCases, id: \.self) { section in
                        layoutBar(for: section)
                    }
                }
            }
        } else {
            loadingMenuBarItems
                .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    @ViewBuilder
    private var reorderStatus: some View {
        switch itemManager.reorderFeedback {
        case .idle:
            EmptyView()
        case .arranging:
            statusLine("Arranging menu bar…", busy: true)
        case .readingActualOrder:
            statusLine("Reading the current menu bar order…", busy: true)
        case .confirmed:
            statusLine("Menu bar order confirmed.", symbol: "checkmark.circle")
        case .stopped(let reason):
            statusLine(statusMessage(for: reason), symbol: "info.circle")
            if reason == .endpointUnavailable { overflowRecoveryButton }
        case .readbackUnavailable(let reason):
            statusLine("Order unavailable. Check the menu bar before dragging again.", symbol: "exclamationmark.circle")
            if reason == .endpointUnavailable { overflowRecoveryButton }
        case .expandingOverflow:
            statusLine("Expanding macOS overflow…", busy: true)
        case .overflowExpanded:
            statusLine("macOS overflow is expanded. Drag again to choose a new order.", symbol: "checkmark.circle")
        case .overflowExpansionFailed:
            statusLine("Overflow unavailable. Refresh the list, then drag a visible item.", symbol: "info.circle")
            Button("Refresh List") {
                guard itemManager.prepareLayoutRefreshAfterOverflowFailure() else { return }
                loadState = .loading
                refreshID += 1
            }
        }
    }

    @ViewBuilder
    private var overflowRecoveryButton: some View {
        if appState.menuBarManager.usesSystemOverflow {
            Button("Expand macOS Overflow") {
                Task { await itemManager.expandSystemOverflowForLayout() }
            }
        }
    }

    private func statusLine(_ message: LocalizedStringKey, symbol: String = "info.circle", busy: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if busy { ProgressView().controlSize(.small) } else { Image(systemName: symbol) }
            Text(message).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func statusMessage(for reason: NativeReorderFailure) -> LocalizedStringKey {
        switch reason {
        case .inputInterrupted:
            "Input interrupted the move. Release the mouse and modifier keys, then drag again."
        case .displayChanged:
            "Display changed. Drag again on the current display."
        case .modeChanged:
            "Hiding mode changed. Drag again."
        case .visibilityChanging:
            "Application visibility is changing. Try again after it finishes."
        case .endpointUnavailable:
            "Item unavailable. Show it in the menu bar, then drag again."
        case .applicationHidden:
            "Show the hidden applications before reordering."
        case .verificationUnconfirmed:
            "Order not confirmed. Check the menu bar, then drag again."
        case .eventDeliveryFailed:
            "Move not confirmed. Drag again when ready."
        }
    }

    @ViewBuilder
    private var cannotArrange: some View {
        Text("FloeBar cannot arrange menu bar items in automatically hidden menu bars.")
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
        VStack(spacing: 12) {
            switch loadState {
            case .loading:
                Text("Loading menu bar items…")
                ProgressView()
            case .finished, .timedOut:
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                Text(loadState == .timedOut ? LocalizedStringKey("Menu bar items are taking longer than expected.") : LocalizedStringKey("No movable menu bar items found."))
                    .font(.headline)
                Text("Try again once your menu bar apps are ready. You can check permissions in Advanced Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button("Try Again") {
                    loadState = .loading
                    refreshID += 1
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private func layoutBar(for name: MenuBarSection.Name) -> some View {
        if
            let section = appState.menuBarManager.section(withName: name),
            section.isEnabled
        {
            VStack(alignment: .leading, spacing: 10) {
                if #available(macOS 27.0, *) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: name == .visible ? "eye" : "eye.slash")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name.localized).font(.system(size: 13, weight: .semibold))
                            if !appState.menuBarManager.usesSystemOverflow {
                                Text(sectionDescription(name))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(itemManager.itemCache[name].count.formatted())
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.primary.opacity(0.045), in: Capsule())
                    }
                    .padding(.horizontal, 4)
                } else {
                    Text(name.localized).font(.headline).padding(.leading, 8)
                }

                LayoutBar(
                    imageCache: appState.imageCache,
                    section: name,
                    isEmpty: itemManager.itemCache[name].isEmpty
                )
            }
        }
    }

    private func sectionDescription(_ section: MenuBarSection.Name) -> LocalizedStringKey {
        switch section {
        case .visible: "Always within reach, to the right of FloeBar."
        case .hidden: "Click FloeBar to show or hide these items."
        case .alwaysHidden: "Kept out of the way until you choose to reveal them."
        }
    }
}
