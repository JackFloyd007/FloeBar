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
    private static let sectionStep = 0.1
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
        guard
            let itemKey = resolveKey(for: item, existingKeys: keys),
            let targetKey = resolveKey(for: destination.targetItem, existingKeys: keys),
            let targetWeight = positions[targetKey]
        else {
            return false
        }

        let ordered = liveItems
            .filter { $0.tag != item.tag }
            .sorted { $0.bounds.minX < $1.bounds.minX }
        guard let targetIndex = ordered.firstIndex(where: { $0.tag == destination.targetItem.tag }) else {
            return false
        }

        let farItem: MenuBarItem? = switch destination {
        case .leftOfItem:
            targetIndex > ordered.startIndex ? ordered[targetIndex - 1] : nil
        case .rightOfItem:
            targetIndex + 1 < ordered.endIndex ? ordered[targetIndex + 1] : nil
        }

        let newWeight: Double
        if
            let farItem,
            let farKey = resolveKey(for: farItem, existingKeys: keys),
            let farWeight = positions[farKey],
            farWeight != targetWeight
        {
            newWeight = targetWeight + (farWeight - targetWeight) / 2
        } else {
            let weightsIncreaseRight = observedWeightsIncreaseRight(
                liveItems: liveItems,
                positions: positions,
                keys: keys
            )
            let rightward = if case .rightOfItem = destination { true } else { false }
            let delta = rightward == weightsIncreaseRight ? 10.0 : -10.0
            newWeight = targetWeight + delta
        }

        guard positions[itemKey] != newWeight else { return true }
        positions[itemKey] = newWeight
        writePositions(positions)
        nudgeMenuBarAgent()
        logger.info("Reordered \(item.logString, privacy: .public) using \(itemKey, privacy: .public)")
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

        // A plausible key is not necessarily the internal key MenuBarAgent
        // sorts. Fabricating it makes the preference write appear successful
        // while leaving the icon on the wrong side of Ice.
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

    private static func nudgeMenuBarAgent() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent") {
            kill(app.processIdentifier, SIGTERM)
        }
    }
}
