//
//  MacOS27MenuBarAgentPositionStore.swift
//  Ice
//
//  Preference-key approach derived from Thaw's GPLv3 macOS 27 implementation.
//

import Cocoa
import OSLog

/// Reorders macOS 27 status items using MenuBarAgent's own preferred-position
/// dictionary. Visibility is handled by ``MacOS27MenuBarController``; this
/// store keeps Ice's single control item at the boundary between the visible
/// and concealed sections without rewriting positions on every toggle.
@available(macOS 27.0, *)
@MainActor
enum MacOS27MenuBarAgentPositionStore {
    private static let logger = Logger(category: "MacOS27MenuBarAgentPositionStore")
    private static let domain = "com.apple.MenuBarAgent" as CFString
    private static let positionsKey = "TrailingItemPreferredPositions" as CFString
    private static let savedWeightsKey = "MacOS27MenuBarAgentPositionStore.savedWeights.v1"
    // MenuBarAgent weights are ordering ranks, not pixel distances. Keep Ice
    // almost adjacent to the visible edge; newly reintroduced items without
    // an autosave key are then laid out on the concealed side of the boundary.
    private static let boundaryInset = 0.001
    // AppKit republishes hosted NSStatusItems from an owner-local preferred
    // position and rounds away sub-point ordering differences. Native menu bar
    // ranks are normally spaced by roughly 10 or more, so use the same scale
    // to keep the order stable after hide/reveal recompositions.
    private static let sectionStep = 10.0
    private static let visibleControlKey =
        "status:\(Constants.bundleIdentifier)::\(ControlItem.Identifier.visible.rawValue)"

    /// Places the visible Ice control after every visible item and before every
    /// resolvable hidden item. The resulting weights stay stable while a
    /// section is toggled, preventing MenuBarAgent from making icons "dance".
    @discardableResult
    static func applySectionBoundary(
        assignments: [String: MenuBarSection.Name],
        order: [MenuBarSection.Name: [String]],
        items: [MenuBarItem]
    ) -> Bool {
        var positions = readRawPositions()
        var changed = restoreLegacyParkedWeights(in: &positions)
        let numericPositions = positions.compactMapValues(numericValue)
        let existingKeys = Array(numericPositions.keys)
        let itemByIdentifier = Dictionary(
            items.map { ($0.tag.persistentIdentifier, $0) },
            uniquingKeysWith: { current, _ in current }
        )

        let weightsIncreaseRight = observedWeightsIncreaseRight(
            liveItems: items,
            positions: numericPositions,
            keys: existingKeys
        )
        // Hidden items are visually to the left of the Ice control. On the
        // observed macOS 27 store, weights normally increase toward the left.
        let hiddenDirection = weightsIncreaseRight ? -1.0 : 1.0

        let visibleWeights = order[.visible, default: []].compactMap { identifier -> Double? in
            guard
                assignments[identifier] == .visible,
                let item = itemByIdentifier[identifier],
                let key = resolveKey(for: item, existingKeys: existingKeys)
            else {
                return nil
            }
            return numericPositions[key]
        }

        let currentControlWeight = numericPositions[visibleControlKey]
        let visibleEdge = if hiddenDirection > 0 {
            visibleWeights.max()
        } else {
            visibleWeights.min()
        }
        guard let boundaryWeight = visibleEdge.map({ $0 + hiddenDirection * boundaryInset })
            ?? currentControlWeight
        else {
            if changed { writeRawPositions(positions) }
            return changed
        }

        if numericValue(positions[visibleControlKey]) != boundaryWeight {
            positions[visibleControlKey] = NSNumber(value: boundaryWeight)
            changed = true
        }
        ControlItemDefaults[.preferredPosition, ControlItem.Identifier.visible.rawValue] =
            CGFloat(boundaryWeight)

        // The stored layout is left-to-right. Starting at its right edge puts
        // the closest hidden item immediately to the left of Ice, followed by
        // the rest of Hidden and then Always-Hidden.
        var offset = 1.0
        for section in [MenuBarSection.Name.hidden, .alwaysHidden] {
            for identifier in order[section, default: []].reversed() {
                guard
                    assignments[identifier] == section,
                    let item = itemByIdentifier[identifier],
                    isThirdPartyItem(item),
                    let key = resolveKey(for: item, existingKeys: existingKeys)
                else {
                    continue
                }
                let targetWeight = boundaryWeight + hiddenDirection * sectionStep * offset
                if numericValue(positions[key]) != targetWeight {
                    positions[key] = NSNumber(value: targetWeight)
                    changed = true
                }
                offset += 1
            }
        }

        guard changed else { return false }
        writeRawPositions(positions)
        logger.notice(
            "Placed macOS 27 Ice boundary at weight \(boundaryWeight, privacy: .public)"
        )
        return true
    }

    /// Restores weights left by macOS27.3's temporary overflow parking. This
    /// one-time migration removes the position rewrite that caused toggles to
    /// flash and then clears the legacy bookkeeping.
    private static func restoreLegacyParkedWeights(in positions: inout [String: Any]) -> Bool {
        let savedWeights = readSavedWeights()
        guard !savedWeights.isEmpty else { return false }

        var changed = false
        for (key, originalWeight) in savedWeights where positions[key] != nil {
            if numericValue(positions[key]) != originalWeight {
                positions[key] = NSNumber(value: originalWeight)
                changed = true
            }
        }
        writeSavedWeights([:])
        return changed
    }

    /// Restores any legacy weights captured before Ice parked an item off-screen.
    @discardableResult
    static func revealAll() -> Bool {
        let savedWeights = readSavedWeights()
        guard !savedWeights.isEmpty else { return false }

        var positions = readRawPositions()
        var changed = false
        for (key, originalWeight) in savedWeights where positions[key] != nil {
            if numericValue(positions[key]) != originalWeight {
                positions[key] = NSNumber(value: originalWeight)
                changed = true
            }
        }
        if changed {
            writeRawPositions(positions)
        }
        writeSavedWeights([:])
        logger.notice("Restored legacy macOS 27 parked menu bar positions")
        return changed
    }

    @discardableResult
    static func move(
        item: MenuBarItem,
        to destination: MenuBarItemManager.MoveDestination,
        liveItems: [MenuBarItem]
    ) -> Bool {
        var positions = readPositions()
        let keys = Array(positions.keys)
        let currentOrder = liveItems.sorted { lhs, rhs in
            if lhs.bounds.minX == rhs.bounds.minX {
                return lhs.bounds.minY < rhs.bounds.minY
            }
            return lhs.bounds.minX < rhs.bounds.minX
        }
        guard
            let sourceIndex = currentOrder.firstIndex(where: { $0.tag == item.tag })
        else {
            return false
        }

        var desiredOrder = currentOrder
        let movedItem = desiredOrder.remove(at: sourceIndex)
        guard let targetIndex = desiredOrder.firstIndex(where: {
            $0.tag == destination.targetItem.tag
        }) else {
            return false
        }
        let insertionIndex = switch destination {
        case .leftOfItem: targetIndex
        case .rightOfItem: targetIndex + 1
        }
        desiredOrder.insert(movedItem, at: insertionIndex)
        guard desiredOrder.map(\.tag) != currentOrder.map(\.tag) else { return true }

        // Treat the existing weights as physical slots and rotate the item
        // identities through those slots. Midpoint insertion eventually runs
        // out of precision and can also cross an unrelated owner-specific
        // rank; permuting the already accepted weights works for adjacent and
        // multi-icon moves without inventing any new rank.
        let lowerBound = min(sourceIndex, insertionIndex)
        let upperBound = max(sourceIndex, insertionIndex)
        let currentSegment = currentOrder[lowerBound ... upperBound]
        let desiredSegment = desiredOrder[lowerBound ... upperBound]

        var slotWeights = [Double]()
        var resolvedKeys = [String]()
        for currentItem in currentSegment {
            guard
                let key = resolveKey(for: currentItem, existingKeys: keys),
                let weight = positions[key]
            else {
                return false
            }
            resolvedKeys.append(key)
            slotWeights.append(weight)
        }
        guard Set(resolvedKeys).count == resolvedKeys.count else { return false }

        var changedKeys = [String]()
        for (desiredItem, slotWeight) in zip(desiredSegment, slotWeights) {
            guard let key = resolveKey(for: desiredItem, existingKeys: keys) else {
                return false
            }
            if positions[key] != slotWeight {
                positions[key] = slotWeight
                changedKeys.append(key)
            }
        }
        guard !changedKeys.isEmpty else { return true }
        writePositions(positions)
        logger.info(
            "Reordered \(item.logString, privacy: .public) across \(changedKeys.count, privacy: .public) preferred-position slots"
        )
        return true
    }

    /// Returns the items in MenuBarAgent's current physical left-to-right
    /// order. This is used for concealed items, whose AX frames disappear
    /// while the visibility restriction is active.
    static func itemsInMenuBarOrder(_ items: [MenuBarItem]) -> [MenuBarItem]? {
        guard items.count > 1 else { return items }

        let positions = readPositions()
        let keys = Array(positions.keys)
        let weightedItems = items.compactMap { item -> (MenuBarItem, Double)? in
            guard
                let key = resolveKey(for: item, existingKeys: keys),
                let weight = positions[key]
            else {
                return nil
            }
            return (item, weight)
        }
        guard weightedItems.count == items.count else { return nil }

        let weightsIncreaseRight = observedWeightsIncreaseRight(
            liveItems: items,
            positions: positions,
            keys: keys
        )
        return weightedItems.sorted { lhs, rhs in
            if lhs.1 == rhs.1 {
                return lhs.0.bounds.minX < rhs.0.bounds.minX
            }
            return weightsIncreaseRight ? lhs.1 < rhs.1 : lhs.1 > rhs.1
        }.map(\.0)
    }

    /// Mirrors MenuBarAgent's desired weights into each owner's AppKit
    /// `NSStatusItem` preference. Hosted macOS 27 items read that owner-local
    /// value when their scene is published; updating MenuBarAgent alone is not
    /// enough to move them.
    static func synchronizeOwnerPreferredPositions(
        for items: [MenuBarItem],
        among liveItems: [MenuBarItem]
    ) -> Bool {
        let positions = readPositions()
        let positionKeys = Array(positions.keys)
        var didSynchronize = false

        // AppKit stores an NSStatusItem's preferred position as the slot on
        // its right, while MenuBarAgent stores a weight for the item itself.
        // Resolve the complete desired order and mirror the right neighbor's
        // weight so the owner republishes into the same physical slot.
        let weightsIncreaseRight = observedWeightsIncreaseRight(
            liveItems: liveItems,
            positions: positions,
            keys: positionKeys
        )
        let weightedLiveItems = liveItems.compactMap { item -> (MenuBarItem, Double)? in
            guard
                let key = resolveKey(for: item, existingKeys: positionKeys),
                let weight = positions[key]
            else {
                return nil
            }
            return (item, weight)
        }.sorted { lhs, rhs in
            if lhs.1 == rhs.1 {
                return lhs.0.bounds.minX < rhs.0.bounds.minX
            }
            return weightsIncreaseRight ? lhs.1 < rhs.1 : lhs.1 > rhs.1
        }

        for item in items {
            guard
                !item.isControlItem,
                let itemIndex = weightedLiveItems.firstIndex(where: { $0.0.tag == item.tag }),
                let application = item.sourceApplication ?? item.owningApplication,
                let bundleIdentifier = application.bundleIdentifier,
                !bundleIdentifier.hasPrefix("com.apple."),
                application.bundleURL?.path.hasPrefix("/System/") != true
            else {
                continue
            }

            let itemWeight = weightedLiveItems[itemIndex].1
            let ownerWeight = if itemIndex + 1 < weightedLiveItems.endIndex {
                weightedLiveItems[itemIndex + 1].1
            } else {
                itemWeight + (weightsIncreaseRight ? 10.0 : -10.0)
            }
            guard
                writeOwnerPreferredPosition(
                    ownerWeight,
                    item: item,
                    domain: bundleIdentifier as CFString
                )
            else {
                continue
            }
            didSynchronize = true
        }
        return didSynchronize
    }

    private static func writeOwnerPreferredPosition(
        _ weight: Double,
        item: MenuBarItem,
        domain: CFString
    ) -> Bool {
        let prefix = "NSStatusItem Preferred Position "
        let keys = (CFPreferencesCopyKeyList(
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String] ?? []).filter { $0.hasPrefix(prefix) }
        guard !keys.isEmpty else { return false }

        let identityCandidates = [item.tag.title, item.title, item.displayName]
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }
        let matchedKeys = keys.filter { key in
            let normalized = key.lowercased()
            return identityCandidates.contains { normalized.contains($0) }
        }
        guard let key = matchedKeys.count == 1 ? matchedKeys[0] : (keys.count == 1 ? keys[0] : nil) else {
            return false
        }

        let existing = CFPreferencesCopyValue(
            key as CFString,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        // The running scene may still be using the value it read at launch,
        // but a matching preference is already durable. The caller handles a
        // live placement with a short native drag and never restarts the app.
        guard numericValue(existing) != weight else { return true }

        CFPreferencesSetValue(
            key as CFString,
            NSNumber(value: weight),
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            logger.error("Could not synchronize owner status-item position for \(item.logString, privacy: .public)")
            return false
        }
        logger.info("Updated owner status-item position for \(item.logString, privacy: .public)")
        return true
    }

    private static func readPositions() -> [String: Double] {
        readRawPositions().compactMapValues(numericValue)
    }

    private static func writePositions(_ positions: [String: Double]) {
        writeRawPositions(positions.mapValues(NSNumber.init(value:)))
    }

    private static func readRawPositions() -> [String: Any] {
        CFPreferencesCopyValue(
            positionsKey,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String: Any] ?? [:]
    }

    private static func writeRawPositions(_ positions: [String: Any]) {
        CFPreferencesSetValue(
            positionsKey,
            positions as CFDictionary,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        if !CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) {
            logger.error("Could not synchronize MenuBarAgent preferred positions")
        }
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func readSavedWeights() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: savedWeightsKey)?.compactMapValues(numericValue) ?? [:]
    }

    private static func writeSavedWeights(_ weights: [String: Double]) {
        if weights.isEmpty {
            UserDefaults.standard.removeObject(forKey: savedWeightsKey)
        } else {
            UserDefaults.standard.set(weights, forKey: savedWeightsKey)
        }
    }

    private static func isThirdPartyItem(_ item: MenuBarItem) -> Bool {
        guard !item.isControlItem else { return false }
        guard let bundleIdentifier = item.sourceApplication?.bundleIdentifier
            ?? item.owningApplication?.bundleIdentifier
        else {
            return false
        }
        return bundleIdentifier != Constants.bundleIdentifier &&
            !bundleIdentifier.hasPrefix("com.apple.")
    }

    private static func resolveKey(
        for item: MenuBarItem,
        existingKeys: [String]
    ) -> String? {
        if item.tag.namespace == .controlCenter {
            let aliases: [String] = switch item.tag.title {
            case "Battery", "com.apple.menuextra.battery": ["Battery"]
            case "Bluetooth", "com.apple.menuextra.bluetooth": ["Bluetooth"]
            case "Clock", "com.apple.menuextra.clock": ["Clock"]
            case "Displays", "Display", "com.apple.menuextra.displays": ["Display", "Displays"]
            case "Keyboard", "com.apple.menuextra.keyboard": ["Keyboard"]
            case "Sound", "Volume", "com.apple.menuextra.volume": ["Sound", "Volume"]
            case "WiFi", "Wi-Fi", "com.apple.menuextra.wifi": ["WiFi"]
            case "ScreenMirroring", "Screen Mirroring", "com.apple.menuextra.screenmirroring":
                ["ScreenMirroring"]
            case "BentoBox-0", "ControlCenter", "com.apple.menuextra.controlcenter": ["BentoBox-0"]
            default: [item.tag.title]
            }
            for alias in aliases {
                let key = "module:\(alias)"
                if existingKeys.contains(key) { return key }
            }
        }

        let bundleIdentifier = item.sourceApplication?.bundleIdentifier
            ?? item.owningApplication?.bundleIdentifier
            ?? item.tag.namespace.description

        // Golden Gate's Spotlight/Siri host publishes localized AX names but
        // persists opaque Item-N keys. `搜索` is the visible Spotlight control
        // on the tested macOS 27 builds; resolving it explicitly avoids the
        // three same-owner candidates left behind by older system revisions.
        if bundleIdentifier == "com.apple.campo" {
            let identity = [item.tag.title, item.title]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            let aliases: [String]
            if identity.contains("spotlight") || identity.contains("search") || identity.contains("搜索") {
                aliases = ["Item-0"]
            } else if identity.contains("siri") {
                aliases = ["Item-1"]
            } else {
                aliases = []
            }
            for alias in aliases {
                let key = "status:\(bundleIdentifier)::\(alias)"
                if existingKeys.contains(key) { return key }
            }
        }

        let exact = "status:\(bundleIdentifier)::\(item.tag.title)"
        if existingKeys.contains(exact) { return exact }

        // AX often exposes a generic Item-0 title while AppKit persists the
        // status item's autosave name (for example MacsFanControlMenuBarIcon).
        // A single key for the owning bundle is therefore an unambiguous match.
        let ownerPrefix = "status:\(bundleIdentifier)::"
        let ownerCandidates = existingKeys.filter { $0.hasPrefix(ownerPrefix) }
        if ownerCandidates.count == 1 { return ownerCandidates[0] }

        let suffix = "::\(item.tag.title)"
        let candidates = existingKeys.filter { $0.hasPrefix("status:") && $0.hasSuffix(suffix) }
        if candidates.count == 1 { return candidates[0] }

        if let localizedName = item.sourceApplication?.localizedName {
            let displayNameKey = "status:\(localizedName)::\(item.tag.title)"
            if existingKeys.contains(displayNameKey) { return displayNameKey }
        }

        // Status items without an autosave name do not appear in the position
        // dictionary until they are moved. MenuBarAgent accepts the canonical
        // bundle/title key and persists it from that point forward.
        if isThirdPartyItem(item) { return exact }
        return nil
    }

    private static func observedWeightsIncreaseRight(
        liveItems: [MenuBarItem],
        positions: [String: Double],
        keys: [String]
    ) -> Bool {
        let resolved = liveItems.compactMap { item -> (CGFloat, Double)? in
            guard
                let key = resolveKey(for: item, existingKeys: keys),
                let weight = positions[key]
            else {
                return nil
            }
            return (item.bounds.midX, weight)
        }.sorted { $0.0 < $1.0 }

        guard let left = resolved.first, let right = resolved.last, left.1 != right.1 else {
            // The observed macOS 27 default has Clock at weight 0 on the right.
            return false
        }
        return left.1 < right.1
    }

}
