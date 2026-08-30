//
//  MacOS27MenuBarAgentPositionStore.swift
//  Ice
//
//  Preference-key approach derived from Thaw's GPLv3 macOS 27 implementation.
//

import Cocoa
import OSLog

/// Reorders macOS 27 status items using MenuBarAgent's own preferred-position
/// dictionary. Items no longer have draggable independent windows on this OS.
@available(macOS 27.0, *)
@MainActor
enum MacOS27MenuBarAgentPositionStore {
    private static let logger = Logger(category: "MacOS27MenuBarAgentPositionStore")
    private static let domain = "com.apple.MenuBarAgent" as CFString
    private static let positionsKey = "TrailingItemPreferredPositions" as CFString

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
        guard
            let dictionary = CFPreferencesCopyAppValue(positionsKey, domain) as? [String: Any]
        else {
            return [:]
        }
        return dictionary.compactMapValues { value in
            if let number = value as? NSNumber { return number.doubleValue }
            if let string = value as? String { return Double(string) }
            return nil
        }
    }

    private static func writePositions(_ positions: [String: Double]) {
        let dictionary = positions.mapValues(NSNumber.init(value:)) as CFDictionary
        CFPreferencesSetAppValue(positionsKey, dictionary, domain)
        CFPreferencesAppSynchronize(domain)
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
