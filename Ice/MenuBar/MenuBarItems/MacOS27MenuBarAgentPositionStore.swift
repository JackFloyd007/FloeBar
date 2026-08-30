//
//  MacOS27MenuBarAgentPositionStore.swift
//  Ice
//
//  Preference-key approach derived from Thaw's GPLv3 macOS 27 implementation.
//

import Cocoa
import OSLog

/// Reorders and prioritizes macOS 27 status items using MenuBarAgent's own
/// preferred-position dictionary. Elevated hidden items naturally overflow on
/// constrained menu bars; the visibility restriction handles wider layouts.
@available(macOS 27.0, *)
@MainActor
enum MacOS27MenuBarAgentPositionStore {
    private static let logger = Logger(category: "MacOS27MenuBarAgentPositionStore")
    private static let domain = "com.apple.MenuBarAgent" as CFString
    private static let positionsKey = "TrailingItemPreferredPositions" as CFString
    private static let savedWeightsKey = "MacOS27MenuBarAgentPositionStore.savedWeights.v1"
    private static let hiddenWeightBase = 50_000
    private static let alwaysHiddenWeightBase = 60_000

    /// Elevates only assigned third-party items into MenuBarAgent's overflow
    /// preference bands. Apple modules and Ice's control items are deliberately
    /// excluded so clicking Ice can never reorder unrelated parts of the bar.
    @discardableResult
    static func applyVisibility(
        assignments: [String: MenuBarSection.Name],
        order: [MenuBarSection.Name: [String]],
        revealing revealedSection: MenuBarSection.Name?,
        items: [MenuBarItem]
    ) -> Bool {
        var positions = readRawPositions()
        var savedWeights = readSavedWeights()
        let existingKeys = Array(positions.keys)
        let itemByIdentifier = Dictionary(
            items.map { ($0.tag.persistentIdentifier, $0) },
            uniquingKeysWith: { current, _ in current }
        )

        let concealedSections: Set<MenuBarSection.Name> = switch revealedSection {
        case .alwaysHidden: []
        case .hidden: [.alwaysHidden]
        case .visible, nil: [.hidden, .alwaysHidden]
        }

        var desiredHiddenKeys = [String: Int]()
        for section in [MenuBarSection.Name.hidden, .alwaysHidden]
        where concealedSections.contains(section) {
            let base = section == .hidden ? hiddenWeightBase : alwaysHiddenWeightBase
            for (offset, identifier) in order[section, default: []].enumerated() {
                guard
                    assignments[identifier] == section,
                    let item = itemByIdentifier[identifier],
                    isThirdPartyItem(item),
                    let key = resolveKey(for: item, existingKeys: existingKeys)
                else {
                    continue
                }
                desiredHiddenKeys[key] = base + offset * 10
            }
        }

        var changed = false
        for (key, hiddenWeight) in desiredHiddenKeys {
            guard let currentWeight = numericValue(positions[key]) else { continue }
            if savedWeights[key] == nil, currentWeight < Double(hiddenWeightBase) {
                savedWeights[key] = currentWeight
            }
            if numericValue(positions[key]) != Double(hiddenWeight) {
                positions[key] = NSNumber(value: hiddenWeight)
                changed = true
            }
        }

        for (key, originalWeight) in savedWeights where desiredHiddenKeys[key] == nil {
            guard positions[key] != nil else {
                savedWeights.removeValue(forKey: key)
                continue
            }
            if numericValue(positions[key]) != originalWeight {
                positions[key] = NSNumber(value: originalWeight)
                changed = true
            }
            savedWeights.removeValue(forKey: key)
        }

        writeSavedWeights(savedWeights)
        guard changed else { return false }
        writeRawPositions(positions)
        logger.notice(
            "Applied macOS 27 item visibility: hiddenKeys=\(desiredHiddenKeys.keys.sorted().joined(separator: ","), privacy: .public)"
        )
        return true
    }

    /// Restores every weight captured before Ice parked an item off-screen.
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
        logger.notice("Restored all macOS 27 menu bar item positions")
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
            case "Displays": ["Display", "Displays"]
            case "Volume": ["Sound", "Volume"]
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
