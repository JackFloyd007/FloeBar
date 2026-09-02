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
/// and applies MenuBarAgent's process visibility restriction.
@MainActor
final class MacOS27MenuBarController {
    private struct StoredLayout: Codable {
        var assignments = [String: MenuBarSection.Name]()
        var order = [MenuBarSection.Name: [String]]()
    }

    struct MoveTransaction {
        fileprivate let encodedLayout: Data
        fileprivate let sectionsWithPendingMove: Set<MenuBarSection.Name>
        fileprivate let pendingPhysicalOrders: [MenuBarSection.Name: [String]]
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
    private var lastManagedItems = [MenuBarItem]()
    private var revealedSection: MenuBarSection.Name?
    private var sectionsWithPendingMove = Set<MenuBarSection.Name>()
    /// The exact item identities whose live left-to-right order must converge
    /// before Layout stops displaying a verified move's projected order.
    private var pendingPhysicalOrders = [MenuBarSection.Name: [String]]()
    private var assertionHandle: UnsafeMutableRawPointer?
    private var retiringAssertionHandles = [UnsafeMutableRawPointer]()
    private var appliedAllowedBundleIdentifiers = Set<String>()
    private var appliedAllowedSystemItemIdentifiers = Set(0 ... 8)
    private var activationGeneration = 0
    private var hasInitializedSectionBoundary = false
    private var isLayoutEditorPresented = false
    private var isReorderInProgress = false
    private let baselineAllowedBundleIdentifiers: Set<String>

    /// Keeps every managed item exposed while the Layout editor is open. This
    /// gives both native drag verification and exact icon capture live bounds.
    private(set) var isLayoutEditing = false

    init() {
        baselineAllowedBundleIdentifiers = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
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

        // Apply the requested state in the click's run-loop turn. Delaying this
        // update made the menu bar settle once and then visibly recompose a
        // second time 140 ms later.
        revealedSection = section
        applyVisibility(liveItems: lastLiveItems)
    }

    func makeCache(
        liveItems: [MenuBarItem],
        sourceItems: [MenuBarItem],
        displayID: CGDirectDisplayID?
    ) -> MenuBarItemManager.ItemCache {
        precondition(Thread.isMainThread)
        migrateTextInputIdentityIfNeeded(in: liveItems)
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
        // editor remains stable and can move them back to Visible. The same
        // owner check is important for visible items: a disabled system extra
        // such as Spotlight exits its publishing process, and retaining that
        // stale tile gives a subsequent drop a target that no longer exists.
        // While the owner is alive, retain the tile for the entire Layout
        // session because MenuBarAgent can omit a hosted child during reflow.
        for (identifier, item) in snapshots where itemsByIdentifier[identifier] == nil {
            guard let section = layout.assignments[identifier] else { continue }

            let ownerIsAvailable = if let bundleIdentifier = knownBundleIdentifiers[identifier] {
                runningBundleIdentifiers.contains(bundleIdentifier)
            } else {
                knownSystemItemIdentifiers[identifier] != nil
            }

            if section == .visible {
                guard isLayoutEditing, ownerIsAvailable else { continue }
                itemsByIdentifier[identifier] = item
                continue
            }

            guard ownerIsAvailable else { continue }
            itemsByIdentifier[identifier] = item
        }
        lastManagedItems = Array(itemsByIdentifier.values)

        var cache = MenuBarItemManager.ItemCache(displayID: displayID)
        let liveIdentifiers = Set(liveItems.map { $0.tag.persistentIdentifier })
        for section in MenuBarSection.Name.allCases {
            let savedOrder = layout.order[section, default: []]
            let unorderedItems = itemsByIdentifier.values.filter { item in
                layout.assignments[item.tag.persistentIdentifier, default: .visible] == section
            }
            let sectionItems: [MenuBarItem]

            if sectionsWithPendingMove.contains(section) {
                let savedIndices = Dictionary(
                    uniqueKeysWithValues: savedOrder.enumerated().map { ($0.element, $0.offset) }
                )
                sectionItems = unorderedItems.sorted { lhs, rhs in
                    let lhsIndex = savedIndices[lhs.tag.persistentIdentifier]
                    let rhsIndex = savedIndices[rhs.tag.persistentIdentifier]
                    switch (lhsIndex, rhsIndex) {
                    case let (lhsIndex?, rhsIndex?): return lhsIndex < rhsIndex
                    case (_?, nil): return true
                    case (nil, _?): return false
                    case (nil, nil): return Self.isOrderedLeftToRight(lhs, rhs)
                    }
                }
            } else if unorderedItems.allSatisfy({ liveIdentifiers.contains($0.tag.persistentIdentifier) }) {
                // AX bounds are the source of truth for anything the user can
                // currently see in the real menu bar.
                sectionItems = unorderedItems.sorted(by: Self.isOrderedLeftToRight)
            } else if
                #available(macOS 27.0, *),
                let preferredOrder = MacOS27MenuBarAgentPositionStore.itemsInMenuBarOrder(
                    Array(unorderedItems)
                )
            {
                // Concealed items have no live AX element. MenuBarAgent's own
                // preferred positions are the authoritative equivalent.
                sectionItems = preferredOrder
            } else {
                // Preserve the last explicit drag order for an item whose
                // private MenuBarAgent key cannot be resolved.
                let savedIndices = Dictionary(
                    uniqueKeysWithValues: savedOrder.enumerated().map { ($0.element, $0.offset) }
                )
                sectionItems = unorderedItems.sorted { lhs, rhs in
                    let lhsIndex = savedIndices[lhs.tag.persistentIdentifier]
                    let rhsIndex = savedIndices[rhs.tag.persistentIdentifier]
                    switch (lhsIndex, rhsIndex) {
                    case let (lhsIndex?, rhsIndex?): return lhsIndex < rhsIndex
                    case (_?, nil): return true
                    case (nil, _?): return false
                    case (nil, nil): return Self.isOrderedLeftToRight(lhs, rhs)
                    }
                }
            }
            cache[section] = sectionItems

            // Preserve absent identifiers in their saved slots. A running app
            // can temporarily withdraw or republish a status item, and one
            // incomplete AX snapshot must not erase the user's order. Explicit
            // moves already remove an identifier from every old section before
            // inserting it into the destination, so this cannot undo a drag.
            var updatedOrder = sectionItems.map { $0.tag.persistentIdentifier }
            for (savedIndex, identifier) in savedOrder.enumerated()
            where layout.assignments[identifier] == section && !updatedOrder.contains(identifier) {
                updatedOrder.insert(identifier, at: min(savedIndex, updatedOrder.endIndex))
            }
            layout.order[section] = updatedOrder
        }

        persist()
        if !hasInitializedSectionBoundary {
            updateSectionBoundary()
            hasInitializedSectionBoundary = true
        }
        applyVisibility(liveItems: liveItems)
        return cache
    }

    /// Captures the persistent and pending-order state touched by a projected
    /// Layout move. The manager uses this only while WindowServer updates are
    /// suspended, so a failed physical reorder can restore the exact prior
    /// section and slot without publishing an intermediate layout.
    func makeMoveTransaction() -> MoveTransaction? {
        guard let encodedLayout = try? JSONEncoder().encode(layout) else {
            return nil
        }
        return MoveTransaction(
            encodedLayout: encodedLayout,
            sectionsWithPendingMove: sectionsWithPendingMove,
            pendingPhysicalOrders: pendingPhysicalOrders
        )
    }

    func rollback(_ transaction: MoveTransaction) {
        guard
            let restoredLayout = try? JSONDecoder().decode(
                StoredLayout.self,
                from: transaction.encodedLayout
            )
        else {
            logger.error("Could not restore the macOS 27 Layout move transaction")
            return
        }

        layout = restoredLayout
        sectionsWithPendingMove = transaction.sectionsWithPendingMove
        pendingPhysicalOrders = transaction.pendingPhysicalOrders
        persist()
        updateSectionBoundary()
        applyVisibility(liveItems: lastLiveItems)
    }

    func move(
        item: MenuBarItem,
        to destination: MenuBarItemManager.MoveDestination,
        currentCache: MenuBarItemManager.ItemCache,
        requiredSection: MenuBarSection.Name? = nil
    ) -> MenuBarSection.Name {
        guard #available(macOS 27.0, *) else { return .visible }

        let identifier = item.tag.persistentIdentifier
        let target = destination.targetItem
        let targetIdentifier = target.tag.persistentIdentifier
        let targetSection: MenuBarSection.Name
        let previousSection = layout.assignments[identifier, default: .visible]

        if let requiredSection {
            // A Layout drop already carries the destination container. Do
            // not infer it again from the target item: an empty Hidden section
            // is represented physically by the visible Ice control item, so
            // geometry alone would incorrectly persist the moved item as
            // Visible after a successful cross-boundary drag.
            targetSection = requiredSection
        } else if target.tag == .hiddenControlItem {
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
        sectionsWithPendingMove.formUnion([previousSection, targetSection])
        for section in Set([previousSection, targetSection]) {
            var relevantIdentifiers = Set(
                currentCache[section].map { $0.tag.persistentIdentifier }
            )
            if section == previousSection {
                relevantIdentifiers.remove(identifier)
            }
            if section == targetSection {
                relevantIdentifiers.insert(identifier)
            }
            pendingPhysicalOrders[section] = layout.order[section, default: []].filter(
                relevantIdentifiers.contains
            )
        }
        persist()
        if previousSection != targetSection {
            updateSectionBoundary()
            applyVisibility(liveItems: lastLiveItems)
        }
        return targetSection
    }

    func move(
        item: MenuBarItem,
        to section: MenuBarSection.Name,
        currentCache: MenuBarItemManager.ItemCache
    ) {
        guard #available(macOS 27.0, *) else { return }

        let identifier = item.tag.persistentIdentifier
        let previousSection = layout.assignments[identifier, default: .visible]
        for existingSection in MenuBarSection.Name.allCases {
            layout.order[existingSection, default: []].removeAll { $0 == identifier }
        }
        layout.assignments[identifier] = section
        if section == .visible {
            // A section-only move targets the first slot immediately to the
            // right of Ice. Persist that same slot so the projected Layout
            // order agrees with the native position and can converge without
            // a multi-second refresh loop.
            layout.order[section, default: []].insert(identifier, at: 0)
        } else {
            // Hidden section-only moves target the last slot immediately to
            // the left of Ice.
            layout.order[section, default: []].append(identifier)
        }
        snapshots[identifier] = item
        sectionsWithPendingMove.formUnion([previousSection, section])
        for pendingSection in Set([previousSection, section]) {
            var relevantIdentifiers = Set(
                currentCache[pendingSection].map { $0.tag.persistentIdentifier }
            )
            if pendingSection == previousSection {
                relevantIdentifiers.remove(identifier)
            }
            if pendingSection == section {
                relevantIdentifiers.insert(identifier)
            }
            pendingPhysicalOrders[pendingSection] = layout.order[pendingSection, default: []].filter(
                relevantIdentifiers.contains
            )
        }
        persist()
        if previousSection != section {
            updateSectionBoundary()
            applyVisibility(liveItems: lastLiveItems)
        }
    }

    func completePendingMove() {
        sectionsWithPendingMove.removeAll()
        pendingPhysicalOrders.removeAll()
    }

    /// Returns true only after one complete live AX snapshot contains every
    /// item involved in the move and their physical order matches the saved
    /// target. Until then Layout keeps the verified projected order, avoiding
    /// an old/new/old visual oscillation while MenuBarAgent republishes scenes.
    func pendingMoveHasConverged() -> Bool {
        guard !pendingPhysicalOrders.isEmpty else { return true }

        for expectedOrder in pendingPhysicalOrders.values {
            let expectedIdentifiers = Set(expectedOrder)
            let liveOrder = lastLiveItems
                .filter { expectedIdentifiers.contains($0.tag.persistentIdentifier) }
                .sorted(by: Self.isOrderedLeftToRight)
                .map { $0.tag.persistentIdentifier }
            guard liveOrder == expectedOrder else { return false }
        }
        return true
    }

    func temporarilyRevealAll() {
        guard #available(macOS 27.0, *) else { return }
        revealedSection = .alwaysHidden
        applyVisibility(liveItems: lastLiveItems)
    }

    func beginLayoutEditing() {
        guard #available(macOS 27.0, *) else { return }
        isLayoutEditorPresented = true
        isLayoutEditing = true
        temporarilyRevealAll()
    }

    func endLayoutEditing() {
        guard #available(macOS 27.0, *) else { return }
        isLayoutEditorPresented = false
        guard !isReorderInProgress else { return }
        isLayoutEditing = false
        completePendingMove()
    }

    /// Keeps every physical endpoint published if the user closes Layout while
    /// its final desired order is still being reconciled.
    func beginReordering() {
        guard #available(macOS 27.0, *) else { return }
        isReorderInProgress = true
        isLayoutEditing = true
        temporarilyRevealAll()
    }

    /// Releases the reorder hold. Returns true when Layout itself is no longer
    /// open and the caller should restore the normal visible/hidden state.
    @discardableResult
    func endReordering() -> Bool {
        guard #available(macOS 27.0, *) else { return false }
        isReorderInProgress = false
        guard !isLayoutEditorPresented else { return false }
        isLayoutEditing = false
        completePendingMove()
        return true
    }

    /// Returns the latest live AX snapshot without starting another complete
    /// menu-bar walk. Layout reordering uses this to keep its fast path local.
    func liveItemsForReordering() -> [MenuBarItem] {
        lastLiveItems
    }

    /// Includes retained concealed-item snapshots so their preferred ranks can
    /// be updated even while MenuBarAgent has removed them from AX.
    func knownItemsForReordering() -> [MenuBarItem] {
        Array(
            Dictionary(
                (Array(snapshots.values) + lastSourceItems + lastManagedItems + lastLiveItems).map {
                    ($0.tag.persistentIdentifier, $0)
                },
                // Later arrays are progressively fresher. Never let a retained
                // concealed snapshot overwrite a newly published AX frame.
                uniquingKeysWith: { _, newer in newer }
            ).values
        )
    }

    private func updateSectionBoundary() {
        guard #available(macOS 27.0, *) else { return }
        let knownItems = knownItemsForReordering()
        let didWritePositions = MacOS27MenuBarAgentPositionStore.applySectionBoundary(
            assignments: layout.assignments,
            order: layout.order,
            items: knownItems
        )
        guard didWritePositions else { return }
        logger.notice("Updated macOS 27 visible/hidden section boundary")
    }

    func applyVisibility(liveItems: [MenuBarItem]) {
        guard #available(macOS 27.0, *), IceAssessmentModeHidingAvailable() else {
            return
        }
        if !liveItems.isEmpty { lastLiveItems = liveItems }

        let visibilityItems = lastSourceItems.isEmpty ? lastLiveItems : lastSourceItems

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
        var allowedBundleIdentifiers = baselineAllowedBundleIdentifiers
            .union(knownBundleIdentifiers.values)
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
            allowedSystemIdentifiers.sorted().map(NSNumber.init(value:)),
            { [weak self] in
                Task { @MainActor in
                    self?.completeVisibilityActivation(generation: generation)
                }
            },
            { [weak self] in
                Task { @MainActor in
                    guard let self, generation == self.activationGeneration else { return }
                    self.logger.error("macOS 27 visibility restriction activation failed")
                    self.invalidateAssertion()
                }
            }
        )
        guard let replacementHandle else {
            logger.error("macOS 27 visibility restriction is unavailable")
            return
        }

        logger.debug(
            "Applying macOS 27 visibility for section \(String(describing: self.revealedSection), privacy: .public) with \(allowedBundleIdentifiers.count, privacy: .public) application identifiers"
        )

        assertionHandle = replacementHandle
        appliedAllowedBundleIdentifiers = allowedBundleIdentifiers
        appliedAllowedSystemItemIdentifiers = allowedSystemIdentifiers

        if let previousAssertionHandle {
            // Activation completes asynchronously. Keep the old restriction
            // alive until MenuBarClientCore confirms its replacement, so a
            // rapid section change cannot leave an unprotected gap while the
            // controller already believes the new allowlist is applied.
            retiringAssertionHandles.append(previousAssertionHandle)
        }
    }

    private func completeVisibilityActivation(generation: Int) {
        guard generation == activationGeneration else { return }
        let handles = retiringAssertionHandles
        retiringAssertionHandles.removeAll()
        for handle in handles {
            IceAssessmentModeHidingInvalidate(handle)
        }
    }

    private func invalidateAssertion() {
        if let assertionHandle {
            IceAssessmentModeHidingInvalidate(assertionHandle)
        }
        for handle in retiringAssertionHandles {
            IceAssessmentModeHidingInvalidate(handle)
        }
        assertionHandle = nil
        retiringAssertionHandles.removeAll()
        appliedAllowedBundleIdentifiers.removeAll()
        appliedAllowedSystemItemIdentifiers = Self.allSystemItemIdentifiers
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    /// Collapses legacy input-source labels into TextInputMenuAgent's stable
    /// Item-N identity without changing the user's section or position.
    private func migrateTextInputIdentityIfNeeded(in items: [MenuBarItem]) {
        for item in items where item.tag.namespace == .textInputMenuAgent {
            let canonicalIdentifier = item.tag.persistentIdentifier
            let namespacePrefix = "\(item.tag.namespace):"
            let instanceSuffix = "#\(item.tag.instanceIndex)"
            let aliases = Set(layout.assignments.keys.filter {
                $0.hasPrefix(namespacePrefix) && $0.hasSuffix(instanceSuffix)
            }).union([canonicalIdentifier])
            guard aliases.contains(where: { $0 != canonicalIdentifier }) else { continue }

            var savedLocation: (section: MenuBarSection.Name, index: Int)?
            for section in MenuBarSection.Name.allCases {
                if let index = layout.order[section, default: []].firstIndex(where: aliases.contains) {
                    savedLocation = (section, index)
                    break
                }
            }
            let section = savedLocation?.section
                ?? layout.assignments[canonicalIdentifier]
                ?? aliases.compactMap { layout.assignments[$0] }.first
                ?? .visible

            for alias in aliases {
                layout.assignments.removeValue(forKey: alias)
            }
            layout.assignments[canonicalIdentifier] = section

            for existingSection in MenuBarSection.Name.allCases {
                layout.order[existingSection, default: []].removeAll(where: aliases.contains)
            }
            let insertionIndex = min(
                savedLocation?.index ?? layout.order[section, default: []].endIndex,
                layout.order[section, default: []].endIndex
            )
            layout.order[section, default: []].insert(canonicalIdentifier, at: insertionIndex)
            logger.notice("Migrated Text Input menu bar identity to \(canonicalIdentifier, privacy: .public)")
        }
    }

    private static func isOrderedLeftToRight(_ lhs: MenuBarItem, _ rhs: MenuBarItem) -> Bool {
        if lhs.bounds.minX == rhs.bounds.minX {
            return lhs.bounds.minY < rhs.bounds.minY
        }
        return lhs.bounds.minX < rhs.bounds.minX
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
        if case .string(let bundleIdentifier) = item.tag.namespace {
            return bundleIdentifier
        }
        return item.sourceApplication?.bundleIdentifier ?? item.owningApplication?.bundleIdentifier
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
