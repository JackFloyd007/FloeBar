//
//  MacOS27MenuBarController.swift
//  Ice
//

import Cocoa
import OSLog

/// Assignment-backed menu bar section management for macOS 27.
///
/// Divider geometry can no longer hide items on macOS 27. This controller
/// persists logical section membership, places Ice at the section boundary,
/// and applies MenuBarAgent's process visibility restriction. Replacement
/// restrictions overlap briefly so the compositor never falls back to an
/// unrestricted bar between hide and reveal states.
@MainActor
final class MacOS27MenuBarController {
    private struct StoredLayout: Codable {
        var assignments = [String: MenuBarSection.Name]()
        var order = [MenuBarSection.Name: [String]]()
    }

    // v3 discards layouts that included Ice's own visible control item. The Ice
    // button is the permanent toggle and must never be assigned to a section.
    private static let defaultsKey = "MacOS27MenuBarController.layout.v3"
    private static let allSystemItemIdentifiers = Set(0 ... 8)
    private static let protectedBundleIdentifiers: Set<String> = [
        Constants.bundleIdentifier,
        // AppKit publishes NSStatusItem scenes through these clients on
        // macOS 27. Allow both hosts so Ice's sole user-facing toggle is not
        // removed when the visibility restriction is recomputed.
        "com.apple.appkit.status-items",
        "com.apple.MenuBarAgent.systemservices",
        "com.apple.MenuBarAgent",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.apple.TextInputMenuAgent",
    ]

    private let logger = Logger(category: "MacOS27MenuBarController")
    private var layout: StoredLayout
    private var snapshots = [String: MenuBarItem]()
    private var knownBundleIdentifiers = [String: String]()
    private var knownSystemItemIdentifiers = [String: Int]()
    private var lastLiveItems = [MenuBarItem]()
    private var lastSourceItems = [MenuBarItem]()
    private var revealedSection: MenuBarSection.Name?
    private var assertionHandle: UnsafeMutableRawPointer?
    private var retiringAssertionHandles = [UnsafeMutableRawPointer]()
    private var appliedAllowedBundleIdentifiers = Set<String>()
    private var appliedAllowedSystemItemIdentifiers = Set(0 ... 8)
    private var activationGeneration = 0

    /// Invalidates MenuBarAgent's cached ordering without republishing Ice.
    var positionRefreshHandler: (() -> Void)?

    init() {
        if
            let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
            let stored = try? JSONDecoder().decode(StoredLayout.self, from: data)
        {
            self.layout = stored
        } else {
            self.layout = StoredLayout()
        }
    }

    isolated deinit {
        if #available(macOS 27.0, *) {
            MacOS27MenuBarAgentPositionStore.revealAll()
        }
        IceAssessmentModeHidingInvalidate(assertionHandle)
        for handle in retiringAssertionHandles {
            IceAssessmentModeHidingInvalidate(handle)
        }
    }

    var isHidingAvailable: Bool {
        guard #available(macOS 27.0, *) else { return false }
        return IceAssessmentModeHidingAvailable()
    }

    func setRevealedSection(_ section: MenuBarSection.Name?) {
        guard #available(macOS 27.0, *) else { return }
        guard revealedSection != section else { return }
        revealedSection = section
        applyVisibility(liveItems: lastLiveItems)
    }

    func makeCache(
        liveItems: [MenuBarItem],
        sourceItems: [MenuBarItem],
        displayID: CGDirectDisplayID?
    ) -> MenuBarItemManager.ItemCache {
        precondition(Thread.isMainThread)
        seedUnassignedItems(liveItems, using: sourceItems)
        lastLiveItems = liveItems
        lastSourceItems = sourceItems

        for item in sourceItems {
            let identifier = item.tag.persistentIdentifier
            if let bundleIdentifier = bundleIdentifier(for: item) {
                knownBundleIdentifiers[identifier] = bundleIdentifier
            }
            if let systemIdentifier = systemItemIdentifier(for: item.tag) {
                knownSystemItemIdentifiers[identifier] = systemIdentifier
            }
        }
        for item in liveItems {
            let identifier = item.tag.persistentIdentifier
            snapshots[identifier] = item
            if let bundleIdentifier = bundleIdentifier(for: item) {
                knownBundleIdentifiers[identifier] = bundleIdentifier
            }
            if let systemIdentifier = systemItemIdentifier(for: item.tag) {
                knownSystemItemIdentifiers[identifier] = systemIdentifier
            }
        }

        let runningBundleIdentifiers = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        var itemsByIdentifier = Dictionary(
            liveItems.map { ($0.tag.persistentIdentifier, $0) },
            uniquingKeysWith: { current, _ in current }
        )

        // Concealed items disappear from AX enumeration. Retain their last live
        // snapshot while the owning application is still running so the layout
        // editor remains stable and can move them back to Visible.
        for (identifier, item) in snapshots where itemsByIdentifier[identifier] == nil {
            guard
                let section = layout.assignments[identifier],
                section != .visible,
                let bundleIdentifier = knownBundleIdentifiers[identifier],
                runningBundleIdentifiers.contains(bundleIdentifier)
            else {
                continue
            }
            itemsByIdentifier[identifier] = item
        }

        var cache = MenuBarItemManager.ItemCache(displayID: displayID)
        for section in MenuBarSection.Name.allCases {
            let savedOrder = layout.order[section, default: []]
            var seen = Set<String>()
            var sectionItems = [MenuBarItem]()

            for identifier in savedOrder {
                guard
                    layout.assignments[identifier, default: .visible] == section,
                    let item = itemsByIdentifier[identifier]
                else {
                    continue
                }
                sectionItems.append(item)
                seen.insert(identifier)
            }

            let newItems = itemsByIdentifier.values
                .filter { item in
                    let identifier = item.tag.persistentIdentifier
                    return !seen.contains(identifier) &&
                        layout.assignments[identifier, default: .visible] == section
                }
                .sorted { $0.bounds.minX < $1.bounds.minX }
            sectionItems.append(contentsOf: newItems)
            cache[section] = sectionItems
            layout.order[section] = sectionItems.map { $0.tag.persistentIdentifier }
        }

        persist()
        applyVisibility(liveItems: liveItems)
        return cache
    }

    func move(
        item: MenuBarItem,
        to destination: MenuBarItemManager.MoveDestination,
        currentCache: MenuBarItemManager.ItemCache
    ) {
        guard #available(macOS 27.0, *) else { return }

        let identifier = item.tag.persistentIdentifier
        let target = destination.targetItem
        let targetIdentifier = target.tag.persistentIdentifier
        let targetSection: MenuBarSection.Name

        if target.tag == .hiddenControlItem {
            targetSection = switch destination {
            case .leftOfItem: .hidden
            case .rightOfItem: .visible
            }
        } else if target.tag == .alwaysHiddenControlItem {
            targetSection = switch destination {
            case .leftOfItem: .alwaysHidden
            case .rightOfItem: .hidden
            }
        } else if let address = currentCache.address(for: target.tag) {
            targetSection = address.section
        } else {
            targetSection = .visible
        }

        for section in MenuBarSection.Name.allCases {
            layout.order[section, default: []].removeAll { $0 == identifier }
        }
        layout.assignments[identifier] = targetSection

        if target.isControlItem {
            switch destination {
            case .leftOfItem:
                layout.order[targetSection, default: []].append(identifier)
            case .rightOfItem:
                layout.order[targetSection, default: []].insert(identifier, at: 0)
            }
        } else {
            var order = layout.order[targetSection, default: []]
            let targetIndex = order.firstIndex(of: targetIdentifier) ?? order.endIndex
            let insertionIndex = switch destination {
            case .leftOfItem: targetIndex
            case .rightOfItem: min(targetIndex + 1, order.endIndex)
            }
            order.insert(identifier, at: insertionIndex)
            layout.order[targetSection] = order
        }

        snapshots[identifier] = item
        persist()
        applyVisibility(liveItems: lastLiveItems)
    }

    func temporarilyRevealAll() {
        guard #available(macOS 27.0, *) else { return }
        revealedSection = .alwaysHidden
        applyVisibility(liveItems: lastLiveItems)
    }

    func applyVisibility(liveItems: [MenuBarItem]) {
        guard #available(macOS 27.0, *), IceAssessmentModeHidingAvailable() else {
            return
        }
        if !liveItems.isEmpty { lastLiveItems = liveItems }

        let visibilityItems = lastSourceItems.isEmpty ? lastLiveItems : lastSourceItems
        let didWritePositions = MacOS27MenuBarAgentPositionStore.applySectionBoundary(
            assignments: layout.assignments,
            order: layout.order,
            items: visibilityItems
        )
        if didWritePositions {
            logger.notice(
                "Updated macOS 27 visible/hidden section boundary"
            )
        }

        let concealedSections: Set<MenuBarSection.Name> = switch revealedSection {
        case .alwaysHidden: []
        case .hidden: [.alwaysHidden]
        case .visible, nil: [.hidden, .alwaysHidden]
        }
        let concealedIdentifiers = Set(layout.assignments.compactMap { identifier, section in
            concealedSections.contains(section) ? identifier : nil
        })

        // The restriction is bundle-scoped for third-party items. If one app
        // contributes both a visible and hidden item, fail open for the whole
        // app instead of unexpectedly hiding its visible sibling.
        var bundlesWithVisibleItems = Set<String>()
        for item in visibilityItems {
            let identifier = item.tag.persistentIdentifier
            guard
                !item.isControlItem,
                !concealedIdentifiers.contains(identifier),
                let bundleIdentifier = knownBundleIdentifiers[identifier] ?? bundleIdentifier(for: item)
            else {
                continue
            }
            bundlesWithVisibleItems.insert(bundleIdentifier)
        }

        var concealedBundleIdentifiers = Set(concealedIdentifiers.compactMap {
            knownBundleIdentifiers[$0]
        })
        concealedBundleIdentifiers.subtract(bundlesWithVisibleItems)
        concealedBundleIdentifiers.subtract(Self.protectedBundleIdentifiers)

        let concealedSystemIdentifiers = Set(concealedIdentifiers.compactMap {
            knownSystemItemIdentifiers[$0]
        })
        let allowedSystemIdentifiers = Self.allSystemItemIdentifiers
            .subtracting(concealedSystemIdentifiers)

        // Restrict the allowlist to applications that have actually published
        // a menu bar item. Using every running application made transient
        // helpers change this set continuously, which rebuilt the assertion
        // and caused a visible re-composition storm.
        var allowedBundleIdentifiers = Set(knownBundleIdentifiers.values)
            .subtracting(concealedBundleIdentifiers)
        allowedBundleIdentifiers.formUnion(Self.protectedBundleIdentifiers)
        allowedBundleIdentifiers.formUnion(bundlesWithVisibleItems)

        guard
            assertionHandle == nil ||
                allowedBundleIdentifiers != appliedAllowedBundleIdentifiers ||
                allowedSystemIdentifiers != appliedAllowedSystemItemIdentifiers
        else {
            return
        }

        activationGeneration += 1
        let generation = activationGeneration
        let previousAssertionHandle = assertionHandle
        let replacementHandle = IceAssessmentModeHidingActivate(
            allowedBundleIdentifiers.sorted(),
            allowedSystemIdentifiers.sorted().map(NSNumber.init(value:))
        ) { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.activationGeneration else { return }
                self.logger.error("macOS 27 visibility restriction activation failed")
                self.invalidateAssertion()
            }
        }
        guard let replacementHandle else {
            logger.error("macOS 27 visibility restriction is unavailable")
            return
        }

        assertionHandle = replacementHandle
        appliedAllowedBundleIdentifiers = allowedBundleIdentifiers
        appliedAllowedSystemItemIdentifiers = allowedSystemIdentifiers

        if let previousAssertionHandle {
            // Keep the old assertion alive until the replacement has had time
            // to activate. Overlapping restrictions prevents the menu bar from
            // briefly revealing every status item between two configurations.
            retiringAssertionHandles.append(previousAssertionHandle)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else {
                    IceAssessmentModeHidingInvalidate(previousAssertionHandle)
                    return
                }
                if let index = retiringAssertionHandles.firstIndex(of: previousAssertionHandle) {
                    retiringAssertionHandles.remove(at: index)
                    IceAssessmentModeHidingInvalidate(previousAssertionHandle)
                    // Unkeyed third-party items are inserted only after the
                    // previous restriction retires. Refresh Ice in place at
                    // that point so it stays between concealed and visible.
                    positionRefreshHandler?()
                }
            }
        } else if didWritePositions {
            positionRefreshHandler?()
        }
    }

    private func invalidateAssertion() {
        if let assertionHandle {
            IceAssessmentModeHidingInvalidate(assertionHandle)
        }
        assertionHandle = nil
        for handle in retiringAssertionHandles {
            IceAssessmentModeHidingInvalidate(handle)
        }
        retiringAssertionHandles.removeAll()
        appliedAllowedBundleIdentifiers.removeAll()
        appliedAllowedSystemItemIdentifiers = Self.allSystemItemIdentifiers
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    /// Migrates Ice's physical divider layout into macOS 27's explicit section
    /// assignments. Without this, a first launch treats every existing item as
    /// visible until the user manually rebuilds the entire layout.
    private func seedUnassignedItems(
        _ items: [MenuBarItem],
        using sourceItems: [MenuBarItem]
    ) {
        let hiddenDivider = sourceItems.first { $0.tag == .hiddenControlItem }
        let alwaysHiddenDivider = sourceItems.first { $0.tag == .alwaysHiddenControlItem }

        var seededAnyItem = false
        for item in items {
            let identifier = item.tag.persistentIdentifier
            guard layout.assignments[identifier] == nil else { continue }

            let section: MenuBarSection.Name
            if let hiddenDivider, item.bounds.minX >= hiddenDivider.bounds.maxX {
                section = .visible
            } else if
                let hiddenDivider,
                let alwaysHiddenDivider,
                item.bounds.maxX <= hiddenDivider.bounds.minX,
                item.bounds.minX >= alwaysHiddenDivider.bounds.maxX
            {
                section = .hidden
            } else if
                let alwaysHiddenDivider,
                item.bounds.maxX <= alwaysHiddenDivider.bounds.minX
            {
                section = .alwaysHidden
            } else if let hiddenDivider, item.bounds.maxX <= hiddenDivider.bounds.minX {
                section = .hidden
            } else {
                section = .visible
            }

            layout.assignments[identifier] = section
            layout.order[section, default: []].append(identifier)
            seededAnyItem = true
        }

        guard seededAnyItem else { return }
        let visibleCount = layout.assignments.values.count { $0 == .visible }
        let hiddenCount = layout.assignments.values.count { $0 == .hidden }
        let alwaysHiddenCount = layout.assignments.values.count { $0 == .alwaysHidden }
        logger.notice(
            "Seeded macOS 27 layout: visible=\(visibleCount, privacy: .public), hidden=\(hiddenCount, privacy: .public), alwaysHidden=\(alwaysHiddenCount, privacy: .public)"
        )
    }

    private func bundleIdentifier(for item: MenuBarItem) -> String? {
        item.sourceApplication?.bundleIdentifier ?? item.owningApplication?.bundleIdentifier
    }

    private func systemItemIdentifier(for tag: MenuBarItemTag) -> Int? {
        tag.macOS27SystemItemIdentifier
    }

    func revealAllBeforeTermination() {
        guard #available(macOS 27.0, *) else { return }
        invalidateAssertion()
        _ = MacOS27MenuBarAgentPositionStore.revealAll()
    }
}
