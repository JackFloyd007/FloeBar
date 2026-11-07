//
//  MacOS27MenuBarController.swift
//  Ice
//

import Cocoa
import OSLog

/// Persists section assignments and explicit Layout edits on macOS 27.
/// This controller never intercepts input or restricts system visibility.
@MainActor
final class MacOS27MenuBarController {
    private typealias LayoutOwners = MacOS27LayoutOwnerRegistry<MenuBarItemTag.Namespace>
    private struct StoredLayout: Codable, Equatable {
        var assignments = [String: MenuBarSection.Name]()
        var order = [MenuBarSection.Name: [String]]()
    }

    // v3 discards layouts that included Ice's own visible control item. The Ice
    // button is the permanent toggle and must never be assigned to a section.
    private static let defaultsKey = "MacOS27MenuBarController.layout.v3"

    private let logger = Logger(category: "MacOS27MenuBarController")
    private var layout: StoredLayout
    private var persistedLayout: StoredLayout?
    private static let displayLayoutsKey = "MacOS27MenuBarController.displayLayouts.v1"
    private var displayLayouts = [String: StoredLayout]()
    private var selectedDisplayKey: String?
    private var selectedDisplayID: CGDirectDisplayID?
    private let defaults: UserDefaults
    private let displayBounds: (CGDirectDisplayID) -> CGRect
    private let displayKey: (CGDirectDisplayID) -> String
    private var snapshots = [String: MenuBarItem]()
    private var missingItemGrace = MacOS27MissingItemGrace()
    private var layoutOwners = LayoutOwners()
    private var knownBundleIdentifiers = [String: String]()
    private var lastLiveItems = [MenuBarItem]()
    private var lastSourceItems = [MenuBarItem]()
    private var lastManagedItems = [MenuBarItem]()
    private var sectionsWithPendingMove = Set<MenuBarSection.Name>()
    /// The exact item identities whose live left-to-right order must converge
    /// before Layout stops displaying a verified move's projected order.
    private var pendingPhysicalOrders = [MenuBarSection.Name: [String]]()
    private var isLayoutEditorPresented = false
    private(set) var isReorderInProgress = false {
        didSet {
            if isReorderInProgress != oldValue {
                interactionGeneration &+= 1
                if isLayoutEditing { onEditingChanged?() }
            }
        }
    }
    /// Invalidates captures that span an editor or reorder lifecycle change.
    private(set) var interactionGeneration: UInt = 0

    /// Layout is the only context in which Ice may rearrange status items.
    private(set) var isLayoutEditing = false {
        didSet {
            if isLayoutEditing != oldValue {
                if isLayoutEditing {
                    layoutOwners.begin(
                        knownOwners: owners(of: knownItemsForReordering()),
                        runningOwners: runningOwners()
                    )
                } else {
                    layoutOwners.end()
                }
                interactionGeneration &+= 1
                onEditingChanged?()
            }
        }
    }

    var onEditingChanged: (() -> Void)?

    /// Concealed overflow items can report coincident AX frames. Retain the
    /// saved order until Layout has exposed their real positions again.
    var isPrivateConcealment = false
    var isConcealingItems = false

    init(
        defaults: UserDefaults = .standard,
        displayBounds: @escaping (CGDirectDisplayID) -> CGRect = CGDisplayBounds,
        displayKey: @escaping (CGDirectDisplayID) -> String = { displayID in
            CGDisplayCreateUUIDFromDisplayID(displayID).map {
                CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
            } ?? "display-\(displayID)"
        }
    ) {
        self.defaults = defaults
        self.displayBounds = displayBounds
        self.displayKey = displayKey
        if let data = defaults.data(forKey: Self.displayLayoutsKey),
            let stored = try? JSONDecoder().decode([String: StoredLayout].self, from: data) {
            displayLayouts = stored.mapValues { Self.removingRuntimeIdentities(from: $0) }
        }
        if
            let data = defaults.data(forKey: Self.defaultsKey),
            let stored = try? JSONDecoder().decode(StoredLayout.self, from: data)
        {
            self.layout = stored
            self.persistedLayout = stored
            layout = Self.removingRuntimeIdentities(from: layout)
        } else {
            self.layout = StoredLayout()
        }
    }

    private static func removingRuntimeIdentities(from stored: StoredLayout) -> StoredLayout {
        var result = stored
        result.assignments = result.assignments.filter {
            !MacOS27RuntimeItemIdentity.isStoredIdentifier($0.key)
        }
        for section in MenuBarSection.Name.allCases {
            result.order[section]?.removeAll(where: MacOS27RuntimeItemIdentity.isStoredIdentifier)
        }
        return result
    }

    private func selectDisplay(_ displayID: CGDirectDisplayID) {
        guard selectedDisplayID != displayID else { return }
        persist()
        let key = displayKey(displayID)
        // Import the legacy single-display layout once; preserve its original key.
        let imported = selectedDisplayKey == nil && displayLayouts.isEmpty ? layout : StoredLayout()
        layout = displayLayouts[key] ?? imported
        persistedLayout = displayLayouts[key]
        selectedDisplayKey = key
        selectedDisplayID = displayID
        snapshots.removeAll()
        lastSourceItems.removeAll()
        lastLiveItems.removeAll()
        lastManagedItems.removeAll()
        knownBundleIdentifiers.removeAll()
        missingItemGrace = MacOS27MissingItemGrace()
        completePendingMove()
        interactionGeneration &+= 1
    }

    func absenceCandidates(
        liveItems: [MenuBarItem], sourceItems: [MenuBarItem], displayID: CGDirectDisplayID
    ) -> [MenuBarItem] {
        guard selectedDisplayID == displayID else { return [] }
        let live = Set(liveItems.map { $0.tag.persistentIdentifier })
        let canObserve = !isConcealingItems && !isReorderInProgress && sourceItems.first(matching: .visibleControlItem) != nil
        let now = ProcessInfo.processInfo.systemUptime
        return snapshots.compactMap { identifier, item in
            guard !live.contains(identifier), missingItemGrace.needsVerification(identifier, canObserve: canObserve, now: now) else { return nil }
            return item
        }
    }

    func makeCache(
        liveItems: [MenuBarItem],
        sourceItems: [MenuBarItem],
        displayID: CGDirectDisplayID?,
        usesSystemOverflow: Bool = false,
        confirmedAbsentIdentifiers: Set<String> = []
    ) -> MenuBarItemManager.ItemCache {
        precondition(Thread.isMainThread)
        guard let displayID else { return MenuBarItemManager.ItemCache(displayID: nil) }
        selectDisplay(displayID)
        let display = displayBounds(displayID)
        let strip = CGRect(x: display.minX, y: display.minY, width: display.width, height: 40)
        let sourceItems = sourceItems.filter { strip.contains($0.bounds) }
        let liveItems = liveItems.filter { strip.contains($0.bounds) }
        migrateTextInputIdentityIfNeeded(in: liveItems)
        seedUnassignedItems(liveItems, using: sourceItems)
        // Existing assignments are explicit user preferences. Native overflow
        // and backend switches can move an item across FloeBar without a
        // section edit; only seed new items or commit an explicit section move.
        lastLiveItems = liveItems
        lastSourceItems = sourceItems
        layoutOwners.observe(owners(of: sourceItems))

        for item in sourceItems {
            let identifier = item.tag.persistentIdentifier
            if let bundleIdentifier = bundleIdentifier(for: item) {
                knownBundleIdentifiers[identifier] = bundleIdentifier
            }
        }
        for item in liveItems {
            let identifier = item.tag.persistentIdentifier
            snapshots[identifier] = item
            missingItemGrace.saw(identifier)
            if let bundleIdentifier = bundleIdentifier(for: item) {
                knownBundleIdentifiers[identifier] = bundleIdentifier
            }
        }

        let runningBundleIdentifiers = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        var itemsByIdentifier = Dictionary(
            liveItems.map { ($0.tag.persistentIdentifier, $0) },
            uniquingKeysWith: { current, _ in current }
        )

        // Concealment and AX reflow can omit a live item. Conversely, a running
        // plugin host can intentionally withdraw only one item. Retain through
        // concealment/reorder; while expanded, give omissions a grace period
        // and then require a successful owner reread before retiring a tile.
        let canObserveMissing = !isConcealingItems && !isReorderInProgress &&
            sourceItems.first(matching: .visibleControlItem) != nil
        let now = ProcessInfo.processInfo.systemUptime
        var candidates = [MenuBarItem]()
        var retiredIdentifiers = Set<String>()
        for (identifier, item) in snapshots where itemsByIdentifier[identifier] == nil {
            let ownerIsAvailable = if let bundleIdentifier = knownBundleIdentifiers[identifier] {
                runningBundleIdentifiers.contains(bundleIdentifier)
            } else {
                false
            }
            guard ownerIsAvailable else {
                retiredIdentifiers.insert(identifier)
                continue
            }
            if missingItemGrace.needsVerification(identifier, canObserve: canObserveMissing, now: now) {
                candidates.append(item)
            }
            itemsByIdentifier[identifier] = item
        }
        // The caller's same-generation, budgeted reread is the only absence
        // evidence. No synchronous AX walk may run from this cache mutation.
        retiredIdentifiers.formUnion(confirmedAbsentIdentifiers.intersection(candidates.map { $0.tag.persistentIdentifier }))
        for identifier in retiredIdentifiers {
            snapshots.removeValue(forKey: identifier)
            itemsByIdentifier.removeValue(forKey: identifier)
            knownBundleIdentifiers.removeValue(forKey: identifier)
            missingItemGrace.saw(identifier)
            if MacOS27RuntimeItemIdentity.isStoredIdentifier(identifier) {
                layout.assignments.removeValue(forKey: identifier)
                for section in MenuBarSection.Name.allCases {
                    layout.order[section]?.removeAll { $0 == identifier }
                }
            }
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
            } else if !isConcealingItems,
                unorderedItems.allSatisfy({ liveIdentifiers.contains($0.tag.persistentIdentifier) }) {
                // AX bounds are the source of truth for anything the user can
                // currently see in the real menu bar.
                sectionItems = unorderedItems.sorted(by: Self.isOrderedLeftToRight)
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
        if usesSystemOverflow {
            // Presentation is one physical row. Stored experimental assignments
            // remain in `layout` and are never flattened into preferences.
            var physicalCache = MenuBarItemManager.ItemCache(displayID: displayID)
            physicalCache[.visible] = MenuBarSection.Name.allCases
                .flatMap { cache[$0] }.sorted(by: Self.isOrderedLeftToRight)
            return physicalCache
        }
        return cache
    }

    func savedSection(for tag: MenuBarItemTag) -> MenuBarSection.Name {
        layout.assignments[tag.persistentIdentifier, default: .visible]
    }

    func move(
        item: MenuBarItem,
        to destination: MenuBarItemManager.MoveDestination,
        currentCache: MenuBarItemManager.ItemCache,
        requiredSection: MenuBarSection.Name? = nil,
        preservingAssignment: Bool = false
    ) -> MenuBarSection.Name {
        guard #available(macOS 27.0, *) else { return .visible }

        let identifier = item.tag.persistentIdentifier
        let target = destination.targetItem
        let targetIdentifier = target.tag.persistentIdentifier
        let targetSection: MenuBarSection.Name
        let previousSection = layout.assignments[identifier, default: .visible]

        if preservingAssignment {
            // Native overflow owns visibility. Reordering across an old saved
            // boundary must not reassign that item's experimental section.
            snapshots[identifier] = item
            return previousSection
        }
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

    func beginLayoutEditing() {
        guard #available(macOS 27.0, *) else { return }
        isLayoutEditorPresented = true
        isLayoutEditing = true
    }

    func endLayoutEditing() {
        guard #available(macOS 27.0, *) else { return }
        isLayoutEditorPresented = false
        guard !isReorderInProgress else { return }
        isLayoutEditing = false
        completePendingMove()
    }

    /// Keeps the editing session active until the requested order is reconciled.
    func beginReordering() {
        guard #available(macOS 27.0, *) else { return }
        isReorderInProgress = true
        isLayoutEditing = true
    }

    /// Ends the reorder session without changing visibility or system input.
    func endReordering() {
        guard #available(macOS 27.0, *) else { return }
        isReorderInProgress = false
        guard !isLayoutEditorPresented else { return }
        isLayoutEditing = false
        completePendingMove()
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

    /// Called by the existing workspace publisher, before its cache trigger.
    /// New app lifetimes join only this Layout session's targeted AX reads.
    func runningApplicationsChanged(_ applications: [NSRunningApplication]) {
        guard isLayoutEditing else { return }
        layoutOwners.runningApplicationsChanged(Set(applications.compactMap { owner(for: $0) }))
    }

    func ownersForLayoutRefresh() -> (sourcePIDs: Set<pid_t>, namespaces: Set<MenuBarItemTag.Namespace>) {
        layoutOwners.targets(runningOwners: runningOwners())
    }

    private func runningOwners() -> Set<LayoutOwners.Owner> {
        Set(NSWorkspace.shared.runningApplications.compactMap { owner(for: $0) })
    }

    private func owners(of items: [MenuBarItem]) -> Set<LayoutOwners.Owner> {
        Set(items.compactMap { item in
            guard let app = NSRunningApplication(processIdentifier: item.sourcePID ?? item.ownerPID),
                let owner = owner(for: app), owner.namespace == item.tag.namespace else { return nil }
            return owner
        })
    }

    private func owner(for app: NSRunningApplication) -> LayoutOwners.Owner? {
        guard !app.isTerminated else { return nil }
        let namespace: MenuBarItemTag.Namespace = switch app.bundleIdentifier {
        case "com.apple.MenuBarAgent": .controlCenter
        case Constants.bundleIdentifier: .ice
        case let bundleIdentifier?: .string(bundleIdentifier)
        case nil: .optional(app.localizedName)
        }
        return LayoutOwners.Owner(
            pid: app.processIdentifier,
            namespace: namespace,
            launchTime: app.launchDate?.timeIntervalSinceReferenceDate
        )
    }

    private func persist() {
        guard let selectedDisplayKey, layout != persistedLayout else { return }
        displayLayouts[selectedDisplayKey] = layout
        guard let data = try? JSONEncoder().encode(displayLayouts) else { return }
        defaults.set(data, forKey: Self.displayLayoutsKey)
        persistedLayout = layout
    }

    /// Only a single known legacy input-source label can identify a single
    /// current child. Item-N records are distinct identities, never aliases.
    private func migrateTextInputIdentityIfNeeded(in items: [MenuBarItem]) {
        let current = items.filter { $0.tag.namespace == .textInputMenuAgent }
        let prefix = "\(MenuBarItemTag.Namespace.textInputMenuAgent):"
        let legacyTitles: Set<String> = [
            "ABC", "U.S.", "Unicode Hex Input", "简体拼音", "拼音",
            "繁體拼音", "注音", "倉頡", "仓颉", "双拼", "雙拼",
        ]
        let recorded = Set(layout.assignments.keys).union(layout.order.values.flatMap { $0 })
        for item in current {
            let canonical = item.tag.persistentIdentifier
            let suffix = "#\(item.tag.instanceIndex)"
            guard item.tag.title.hasPrefix("Item-"),
                Int(item.tag.title.dropFirst(5)) != nil,
                current.filter({ $0.tag.instanceIndex == item.tag.instanceIndex }).count == 1 else { continue }
            let aliases = recorded.filter { identifier in
                guard identifier.hasPrefix(prefix), identifier.hasSuffix(suffix) else { return false }
                let title = String(identifier.dropFirst(prefix.count).dropLast(suffix.count))
                return legacyTitles.contains(title)
            }
            // An existing canonical record or multiple legacy labels is
            // ambiguous. Preserve every preference rather than guessing.
            guard !recorded.contains(canonical), aliases.count == 1,
                let alias = aliases.first else { continue }
            let locations = MenuBarSection.Name.allCases.flatMap { section in
                layout.order[section, default: []].enumerated().compactMap { index, identifier in
                    identifier == alias ? (section, index) : nil
                }
            }
            guard locations.count <= 1 else { continue }
            let savedSection = layout.assignments[alias]
            guard savedSection == nil || locations.first == nil || savedSection == locations.first?.0,
                let section = savedSection ?? locations.first?.0 else { continue }
            layout.assignments.removeValue(forKey: alias)
            layout.assignments[canonical] = section
            for name in MenuBarSection.Name.allCases {
                layout.order[name, default: []].removeAll { $0 == alias }
            }
            let index = min(
                locations.first?.1 ?? layout.order[section, default: []].count,
                layout.order[section, default: []].count
            )
            layout.order[section, default: []].insert(canonical, at: index)
            logger.notice("Migrated Text Input menu bar identity to \(canonical, privacy: .public)")
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
        let hiddenDivider = sourceItems.first(matching: .visibleControlItem)
            ?? sourceItems.first(matching: .hiddenControlItem)
        let alwaysHiddenDivider = sourceItems.first(matching: .nativeBoundary(for: .alwaysHidden))
            ?? sourceItems.first(matching: .alwaysHiddenControlItem)

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
        if item.tag.namespace == .controlCenter {
            return "com.apple.MenuBarAgent"
        }
        if case .string(let bundleIdentifier) = item.tag.namespace {
            return bundleIdentifier
        }
        return item.sourceApplication?.bundleIdentifier ?? item.owningApplication?.bundleIdentifier
    }
}
