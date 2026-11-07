//
//  MenuBarManager.swift
//  Ice
//

import Combine
import OSLog
import SwiftUI

/// Manager for the state of the menu bar.
@MainActor
final class MenuBarManager: ObservableObject {
    /// Information for the menu bar's average color.
    @Published private(set) var averageColorInfo: MenuBarAverageColorInfo?

    /// A Boolean value that indicates whether the menu bar is either always hidden
    /// by the system, or automatically hidden and shown by the system based on the
    /// location of the mouse.
    @Published private(set) var isMenuBarHiddenBySystem = false

    /// A Boolean value that indicates whether the menu bar is hidden by the system
    /// according to a value stored in UserDefaults.
    @Published private(set) var isMenuBarHiddenBySystemUserDefaults = false

    /// A Boolean value that indicates whether the "ShowOnHover" feature is allowed.
    @Published var showOnHoverAllowed = true

    /// Reference to the settings window.
    @Published private var settingsWindow: NSWindow?

    /// Logger for the menu bar manager.
    private let logger = Logger(category: "MenuBarManager")

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// A Boolean value that indicates whether the application menus are hidden.
    private var isHidingApplicationMenus = false

    /// The panel that contains the Ice Bar interface.
    let iceBarPanel = IceBarPanel()

    /// The panel that contains the menu bar search interface.
    let searchPanel = MenuBarSearchPanel()

    /// The panel that contains a portable version of the menu bar
    /// appearance editor interface
    let appearanceEditorPanel = MenuBarAppearanceEditorPanel()

    /// macOS 27's assignment-backed menu bar compatibility controller.
    let macOS27Controller = MacOS27MenuBarController()
    let experimentalHiding = ExperimentalPrivateHiding()
    private let nativeOverflow = NativeOverflowController()
    private var nativeOverflowTask: Task<Void, Never>?
    private var isExpandingOverflowForLayout = false
    private var hasVerifiedHiddenLayoutEdit = false
    @Published private(set) var nativeHidingFailed = false

    private let nativeHiding = MacOS27NativeMenuBarHiding()
    private var nativeDragVisibility = MacOS27NativeDragVisibilityState()

    let appVisibilityAccess = SystemAppVisibilityAccess()

    /// The managed sections in the menu bar.
    let sections = [
        MenuBarSection(name: .visible),
        MenuBarSection(name: .hidden),
        MenuBarSection(name: .alwaysHidden),
    ]

    /// A Boolean value that indicates whether at least one of the manager's
    /// sections is visible.
    var isSettingsWindowVisible: Bool { settingsWindow?.isVisible == true }

    var hasVisibleSection: Bool {
        sections.contains { !$0.isHidden }
    }

    /// Performs the initial setup of the menu bar manager.
    func performSetup(with appState: AppState) {
        self.appState = appState
        appVisibilityAccess.discoveredMenuOwners = { [weak appState] in
            var owners = [String: Set<pid_t>]()
            for item in appState?.itemManager.itemCache.managedItems ?? [] {
                guard !item.isControlItem, case .string(let bundle) = item.tag.namespace,
                    SystemAppVisibilityModel.eligible(bundle, own: Constants.bundleIdentifier) else { continue }
                owners[bundle, default: []].insert(item.sourcePID ?? item.ownerPID)
            }
            return owners
        }
        appVisibilityAccess.canChangeVisibility = { [weak self] in
            guard let self else { return false }
            return !self.macOS27Controller.isReorderInProgress && !self.experimentalHiding.enabled
                && self.nativeOverflowTask == nil && !self.isExpandingOverflowForLayout
        }
        appVisibilityAccess.onAllowedChanged = { [weak self] allowed in
            self?.controlItem(withName: .visible)?.state = allowed ? .showSection : .hideSection
        }
        if let allowed = appVisibilityAccess.isAllowed { appVisibilityAccess.onAllowedChanged?(allowed) }
        experimentalHiding.onRecovery = { [weak self] in
            guard let self else { return }
            self.hasVerifiedHiddenLayoutEdit = false
            self.nativeOverflowTask?.cancel()
            self.nativeHidingFailed = false
            self.macOS27Controller.isPrivateConcealment = false
            self.macOS27Controller.isConcealingItems = false
            for section in self.sections { section.controlItem.state = .showSection }
        }
        macOS27Controller.onEditingChanged = { [weak self] in
            self?.syncNativeVisibility()
            self?.applyVerifiedHiddenLayoutEditIfReady()
        }
        configureCancellables()
        iceBarPanel.performSetup(with: appState)
        searchPanel.performSetup(with: appState)
        appearanceEditorPanel.performSetup(with: appState)
        for section in sections {
            section.performSetup(with: appState)
        }
        if #available(macOS 27.0, *) {
            nativeHiding.prepare(section: .hidden, anchorPosition: controlItem(withName: .visible)?.preferredPosition ?? 0)
        }
    }

    /// Applies only Ice-owned spacer state. Other status items receive native input.
    func syncNativeVisibility() {
        guard #available(macOS 27.0, *), let appState else { return }
        guard nativeDragVisibility.shouldApplyVisibilityUpdate() else { return }
        let cache = appState.itemManager.itemCache
        let controlPosition = controlItem(withName: .visible)?.preferredPosition ?? 0
        // Physical position, not the previous cache's membership, determines
        // what gets hidden. The first item can have just been dragged left.
        let hideHidden = section(withName: .hidden)?.isHidden == true
        let hideAlwaysHidden = !hideHidden && !cache[.alwaysHidden].isEmpty &&
            section(withName: .alwaysHidden)?.isEnabled == true &&
            section(withName: .alwaysHidden)?.isHidden == true
        let iceBounds = macOS27Controller.knownItemsForReordering()
            .first(matching: .visibleControlItem)?.bounds
        let alwaysAnchor = if let leftmostHidden = cache[.hidden].first, let iceBounds {
            controlPosition + max(0, iceBounds.minX - leftmostHidden.bounds.minX)
        } else {
            controlPosition
        }

        if macOS27Controller.isLayoutEditing {
            experimentalHiding.release()
            macOS27Controller.isPrivateConcealment = false
            if !usesSystemOverflow, macOS27Controller.isReorderInProgress {
                nativeHiding.showForLayout(
                    anchorPosition: controlPosition,
                    alwaysHiddenAnchor: section(withName: .alwaysHidden)?.isEnabled == true ? alwaysAnchor : nil
                )
            } else {
                nativeHiding.withdraw(section: .hidden)
                nativeHiding.withdraw(section: .alwaysHidden)
            }
            macOS27Controller.isConcealingItems = false
            return
        }

        if experimentalHiding.enabled {
            nativeHiding.withdraw(section: .hidden)
            nativeHiding.withdraw(section: .alwaysHidden)
            if !hideHidden && !hideAlwaysHidden {
                experimentalHiding.release()
                macOS27Controller.isPrivateConcealment = false
                macOS27Controller.isConcealingItems = false
                return
            }
            let hiddenItems = (hideHidden ? cache[.hidden] : []) +
                ((hideHidden || hideAlwaysHidden) && section(withName: .alwaysHidden)?.isEnabled == true ? cache[.alwaysHidden] : [])
            let visibleItems = cache[.visible] + (hideHidden ? [] : cache[.hidden])
            func bundle(_ item: MenuBarItem) -> String? {
                if case .string(let id) = item.tag.namespace { return id }
                return item.sourceApplication?.bundleIdentifier
            }
            // Freeze membership before invoking the asynchronous private API.
            macOS27Controller.isPrivateConcealment = true
            macOS27Controller.isConcealingItems = true
            experimentalHiding.conceal(PrivateHidingPlan.targets(
                hidden: hiddenItems.map(bundle).filter { id in
                    guard let id else { return true } // Unknown owners must still reject the plan.
                    return !id.hasPrefix("com.apple.") && id != Constants.bundleIdentifier
                },
                visible: visibleItems.map(bundle),
                own: Constants.bundleIdentifier
            ))
            return
        }

        // On macOS 27 the OS owns overflow. A wide spacer cannot prove that
        // any target is hidden and can strand icons behind a second control.
        nativeHiding.withdraw(section: .hidden)
        nativeHiding.withdraw(section: .alwaysHidden)
        macOS27Controller.isConcealingItems = false
    }

    var usesSystemOverflow: Bool {
        if #available(macOS 27.0, *) { return !experimentalHiding.enabled }
        return false
    }

    /// A verified assignment is applied after any Settings close path, including
    /// the native red close button, once the queued reorder has actually finished.
    func noteVerifiedHiddenLayoutEdit() {
        guard experimentalHiding.enabled else { return }
        hasVerifiedHiddenLayoutEdit = true
        applyVerifiedHiddenLayoutEditIfReady()
    }

    private func applyVerifiedHiddenLayoutEditIfReady() {
        guard hasVerifiedHiddenLayoutEdit, experimentalHiding.enabled,
            !macOS27Controller.isLayoutEditing, !macOS27Controller.isReorderInProgress else { return }
        hasVerifiedHiddenLayoutEdit = false
        section(withName: .hidden)?.hide()
    }

    func requestSystemOverflow(expanded: Bool? = nil) {
        if usesSystemOverflow, appVisibilityAccess.shouldRouteToApplicationVisibility {
            appVisibilityAccess.changeSelected(expanded: expanded)
            return
        }
        guard #available(macOS 27.0, *), nativeOverflowTask == nil, !isExpandingOverflowForLayout,
              let screen = controlItem(withName: .visible)?.screen ?? NSScreen.main else { return }
        macOS27Controller.endLayoutEditing()
        syncNativeVisibility()
        nativeOverflowTask = Task { [weak self] in
            guard let self else { return }
            let observed = await nativeOverflow.change(expanded: expanded, on: screen.displayID)
            nativeOverflowTask = nil
            guard !Task.isCancelled else { return }
            nativeHidingFailed = observed == nil
            if let observed, usesSystemOverflow {
                for section in sections { section.controlItem.state = observed ? .showSection : .hideSection }
            }
            if observed == nil { controlItem(withName: .visible)?.showNativeOverflowUnavailableMenu() }
        }
    }

    /// Explicit recovery from a Layout error. It never ends editing, toggles
    /// the current state, or resubmits the rejected reorder intent.
    func expandSystemOverflowForLayout(on displayID: CGDirectDisplayID) async -> Bool {
        guard #available(macOS 27.0, *), usesSystemOverflow,
            macOS27Controller.isLayoutEditing,
            nativeOverflowTask == nil, !isExpandingOverflowForLayout,
            Bridging.getActiveMenuBarDisplayID() == displayID else { return false }
        isExpandingOverflowForLayout = true
        defer { isExpandingOverflowForLayout = false }
        let interactionGeneration = macOS27Controller.interactionGeneration
        let observed = await nativeOverflow.change(expanded: true, on: displayID)
        guard !Task.isCancelled, usesSystemOverflow,
            macOS27Controller.isLayoutEditing,
            macOS27Controller.interactionGeneration == interactionGeneration,
            Bridging.getActiveMenuBarDisplayID() == displayID else { return false }
        nativeHidingFailed = observed != true
        return observed == true
    }

    func prepareNativeBoundaryForDragging(section: MenuBarSection.Name) {
        nativeHiding.prepareForDragging(section: section)
    }

    /// Even a third-party-to-third-party drag depends on the current native
    /// row: withdrawing or resizing Ice's boundary would move its endpoints.
    /// Pin only the event sequence, not the asynchronous result verification.
    func beginNativeDrag() {
        nativeDragVisibility.beginDrag()
    }

    func endNativeDrag() {
        if nativeDragVisibility.endDrag() {
            syncNativeVisibility()
        }
    }

    /// A click after Layout toggles the actual, currently expanded bar.
    func prepareForControlToggle() {
        guard #available(macOS 27.0, *), macOS27Controller.isLayoutEditing else { return }
        for section in sections { section.controlItem.state = .showSection }
        macOS27Controller.endLayoutEditing()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()
        experimentalHiding.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &c)
        appState?.navigationState.$isSettingsPresented
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presented in
                if presented { self?.experimentalHiding.recover() }
            }
            .store(in: &c)

        NSApp.publisher(for: \.currentSystemPresentationOptions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] options in
                guard let self else {
                    return
                }
                let hidden = options.contains(.hideMenuBar) || options.contains(.autoHideMenuBar)
                isMenuBarHiddenBySystem = hidden
            }
            .store(in: &c)

        if
            let hiddenSection = section(withName: .alwaysHidden),
            let window = hiddenSection.controlItem.window
        {
            window.publisher(for: \.frame)
                .map { $0.origin.y }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard
                        let self,
                        let isMenuBarHidden = Defaults.globalDomain["_HIHideMenuBar"] as? Bool
                    else {
                        return
                    }
                    isMenuBarHiddenBySystemUserDefaults = isMenuBarHidden
                }
                .store(in: &c)
        }

        // Handle the `focusedApp` rehide strategy.
        NSWorkspace.shared.publisher(for: \.frontmostApplication)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard #unavailable(macOS 27.0) else { return }
                if
                    let self,
                    let appState,
                    case .focusedApp = appState.settings.general.rehideStrategy,
                    let hiddenSection = section(withName: .hidden),
                    let screen = appState.hidEventManager.bestScreen(appState: appState),
                    !appState.hidEventManager.isMouseInsideMenuBar(appState: appState, screen: screen)
                {
                    Task {
                        do { try await Task.sleep(for: .seconds(0.1)) } catch { return }
                        hiddenSection.hide()
                    }
                }
            }
            .store(in: &c)

        appState?.publisherForWindow(.settings)
            .sink { [weak self] window in
                self?.settingsWindow = window
            }
            .store(in: &c)

        // SwiftUI does not reliably send `onDisappear` when the Settings
        // window is merely ordered out. End Layout's temporary reveal from the
        // window lifecycle as well, so closing Layout cannot leave every item
        // exposed and consume the next Ice click as a state correction.
        $settingsWindow
            .removeNil()
            .flatMap { $0.publisher(for: \.isVisible) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                guard let self, !isVisible else { return }
                if #available(macOS 27.0, *) {
                    appState?.itemManager.cancelLayoutReads()
                    if macOS27Controller.isLayoutEditing { macOS27Controller.endLayoutEditing() }
                }
            }
            .store(in: &c)

        $settingsWindow
            .removeNil()
            .flatMap { $0.publisher(for: \.isVisible) }
            .discardMerge(Timer.publish(every: 5, on: .main, in: .default).autoconnect())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.updateAverageColorInfo()
            }
            .store(in: &c)

        // Hide application menus when a section is shown (if applicable).
        Publishers.MergeMany(sections.map { $0.controlItem.$state })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard #unavailable(macOS 27.0) else { return }
                guard let self, let appState else {
                    return
                }

                // Don't continue if:
                //   * The "HideApplicationMenus" setting isn't enabled.
                //   * Using the Ice Bar.
                //   * The menu bar is hidden by the system.
                //   * The active space is fullscreen.
                //   * The settings window is visible.
                guard
                    appState.settings.advanced.hideApplicationMenus,
                    !appState.settings.general.useIceBar,
                    !isMenuBarHiddenBySystem,
                    !appState.activeSpace.isFullscreen,
                    !appState.navigationState.isSettingsPresented
                else {
                    return
                }

                if sections.contains(where: { $0.controlItem.state == .showSection }) {
                    guard let screen = NSScreen.main else {
                        return
                    }

                    // Get the application menu frame for the display.
                    guard let applicationMenuFrame = screen.getApplicationMenuFrame() else {
                        return
                    }

                    Task {
                        // Get all items.
                        var items = await MenuBarItem.getMenuBarItems(on: screen.displayID, option: .activeSpace)

                        // Filter the items down according to the currently enabled/shown sections.
                        if
                            let alwaysHiddenSection = self.section(withName: .alwaysHidden),
                            alwaysHiddenSection.isEnabled
                        {
                            if alwaysHiddenSection.controlItem.state == .hideSection {
                                if let alwaysHiddenControlItem = items.firstIndex(matching: .alwaysHiddenControlItem).map({ items.remove(at: $0) }) {
                                    items.trimPrefix { $0.bounds.maxX <= alwaysHiddenControlItem.bounds.minX }
                                }
                            }
                        } else {
                            if let hiddenControlItem = items.firstIndex(matching: .hiddenControlItem).map({ items.remove(at: $0) }) {
                                items.trimPrefix { $0.bounds.maxX <= hiddenControlItem.bounds.minX }
                            }
                        }

                        // Get the leftmost item on the screen.
                        guard let leftmostItem = items.min(by: { $0.bounds.minX < $1.bounds.minX }) else {
                            return
                        }

                        // If the minX of the item is less than or equal to the maxX of the
                        // application menu frame, activate the app to hide the menu.
                        if leftmostItem.bounds.minX <= applicationMenuFrame.maxX {
                            self.hideApplicationMenus()
                        }
                    }
                } else if isHidingApplicationMenus {
                    showApplicationMenus()
                }
            }
            .store(in: &c)

        cancellables = c
    }

    /// Updates the ``averageColorInfo`` property with the current average color
    /// of the menu bar.
    func updateAverageColorInfo() {
        guard
            let settingsWindow,
            settingsWindow.isVisible,
            let screen = settingsWindow.screen
        else {
            return
        }

        let windows = WindowInfo.createWindows(option: .onScreen)
        let displayID = screen.displayID

        guard
            let menuBarWindow = WindowInfo.menuBarWindow(from: windows, for: displayID),
            let wallpaperWindow = WindowInfo.wallpaperWindow(from: windows, for: displayID)
        else {
            return
        }

        guard
            let image = ScreenCapture.captureWindows(
                with: [menuBarWindow.windowID, wallpaperWindow.windowID],
                screenBounds: withMutableCopy(of: wallpaperWindow.bounds) { $0.size.height = 1 },
                option: .nominalResolution
            ),
            let color = image.averageColor(option: .ignoreAlpha)
        else {
            return
        }

        let info = MenuBarAverageColorInfo(color: color, source: .menuBarWindow)

        if averageColorInfo != info {
            averageColorInfo = info
        }
    }

    /// Returns a Boolean value that indicates whether the given display
    /// has a valid menu bar.
    func hasValidMenuBar(in windows: [WindowInfo], for display: CGDirectDisplayID) -> Bool {
        guard
            let window = WindowInfo.menuBarWindow(from: windows, for: display),
            let element = AXHelpers.element(at: window.bounds.origin)
        else {
            return false
        }
        return AXHelpers.role(for: element) == .menuBar
    }

    /// Shows the secondary context menu.
    func showSecondaryContextMenu(at point: CGPoint) {
        let menu = NSMenu(title: "FloeBar")

        let editAppearanceItem = NSMenuItem(
            title: String(localized: "Edit Menu Bar Appearance…"),
            action: #selector(showAppearanceEditorPanel),
            keyEquivalent: ""
        )
        editAppearanceItem.target = self
        menu.addItem(editAppearanceItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: String(localized: "FloeBar Settings…"),
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        menu.addItem(settingsItem)

        menu.popUp(positioning: nil, at: point, in: nil)
    }

    /// Hides the application menus.
    func hideApplicationMenus() {
        guard let appState else {
            logger.error("Error hiding application menus: Missing app state")
            return
        }
        logger.info("Hiding application menus")
        appState.activate(withPolicy: .regular)
        isHidingApplicationMenus = true
    }

    /// Shows the application menus.
    func showApplicationMenus() {
        guard let appState else {
            logger.error("Error showing application menus: Missing app state")
            return
        }
        logger.info("Showing application menus")
        appState.deactivate(withPolicy: .accessory)
        isHidingApplicationMenus = false
    }

    /// Toggles the visibility of the application menus.
    func toggleApplicationMenus() {
        if isHidingApplicationMenus {
            showApplicationMenus()
        } else {
            hideApplicationMenus()
        }
    }

    /// Shows the appearance editor panel.
    @objc private func showAppearanceEditorPanel() {
        guard let screen = MenuBarAppearanceEditorPanel.defaultScreen else {
            return
        }
        appearanceEditorPanel.show(on: screen)
    }

    /// Returns the menu bar section with the given name.
    func section(withName name: MenuBarSection.Name) -> MenuBarSection? {
        sections.first { $0.name == name }
    }

    /// Returns the control item for the menu bar section with the given name.
    func controlItem(withName name: MenuBarSection.Name) -> ControlItem? {
        section(withName: name)?.controlItem
    }
}

// MARK: - MenuBarAverageColorInfo

/// Information for the average color of the menu bar.
struct MenuBarAverageColorInfo: Hashable {
    /// Sources used to compute the average color of the menu bar.
    enum Source: Hashable {
        case menuBarWindow
        case desktopWallpaper
    }

    /// The average color of the menu bar
    var color: CGColor

    /// The source used to compute the color.
    var source: Source

    /// The brightness of the menu bar's color.
    var brightness: CGFloat { color.brightness ?? 0 }

    /// A Boolean value that indicates whether the menu bar has a
    /// bright color.
    ///
    /// This value is `true` if ``brightness`` is above `0.67`. At
    /// the time of writing, if this value is `true`, the menu bar
    /// draws its items with a darker appearance.
    var isBright: Bool { brightness > 0.67 }
}
