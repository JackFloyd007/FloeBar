//
//  MacOS27MenuBarItemProvider.swift
//  Ice
//
//  macOS 27 compatibility implementation derived from the GPLv3 Thaw project.
//

@preconcurrency import AXSwift
import Cocoa
import OSLog

/// Enumerates macOS 27 menu bar items through Accessibility.
///
/// macOS 27 no longer exposes each status item as an independent WindowServer
/// window. Every application still publishes its status items below
/// `AXExtrasMenuBar`, which also gives us direct process attribution.
@available(macOS 27.0, *)
enum MacOS27MenuBarItemProvider {
    private static let logger = Logger(category: "MacOS27MenuBarItemProvider")
    private static let maxItemHeight: CGFloat = 40
    /// AXSwift's Core Foundation value conversion is not safe when multiple
    /// complete `AXExtrasMenuBar` walks overlap on macOS 27. Keep each walk
    /// atomic; callers already run this work away from the main actor.
    private static let operationLock = NSLock()

    static func menuBarItems(
        on display: CGDirectDisplayID? = nil,
        option _: MenuBarItem.ListOption
    ) -> [MenuBarItem] {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard AXHelpers.isProcessTrusted() else {
            logger.warning("Accessibility permission is missing; cannot enumerate macOS 27 menu bar items")
            return []
        }

        let displayBounds = display.map(CGDisplayBounds)
        var rawItems = [RawItem]()

        for runningApp in NSWorkspace.shared.runningApplications {
            guard
                let application = AXHelpers.application(for: runningApp),
                let extrasMenuBar = AXHelpers.extrasMenuBar(for: application)
            else {
                continue
            }

            let namespace = namespace(for: runningApp)
            var fallbackIndex = 0

            for child in AXHelpers.children(for: extrasMenuBar) {
                guard
                    let frame = AXHelpers.frame(for: child),
                    frame.height > 0,
                    frame.height <= maxItemHeight
                else {
                    continue
                }

                if let displayBounds, !displayBounds.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                    continue
                }

                let descendants = AXHelpers.children(for: child)
                let identifier = nonEmpty(AXHelpers.identifier(for: child))
                    ?? descendants.lazy.compactMap { nonEmpty(AXHelpers.identifier(for: $0)) }.first
                let accessibilityDescription = nonEmpty(AXHelpers.description(for: child))
                    ?? descendants.lazy.compactMap { nonEmpty(AXHelpers.description(for: $0)) }.first
                let accessibilityTitle = nonEmpty(AXHelpers.title(for: child))
                let fallbackTitle = "Item-\(fallbackIndex)"
                let displayTitle = accessibilityTitle ?? accessibilityDescription ?? identifier ?? fallbackTitle
                if accessibilityTitle == nil, accessibilityDescription == nil, identifier == nil {
                    fallbackIndex += 1
                }

                let identityTitle = identifier ?? accessibilityDescription ?? displayTitle
                let ownerPID = AXHelpers.pid(for: child) ?? runningApp.processIdentifier
                rawItems.append(
                    RawItem(
                        namespace: namespace,
                        identityTitle: identityTitle,
                        displayTitle: displayTitle,
                        bounds: frame,
                        ownerPID: ownerPID
                    )
                )
            }
        }

        return assemble(rawItems)
    }

    /// Performs the semantic accessibility press action for an item.
    /// This is more reliable than targeting a synthetic WindowServer ID.
    static func press(_ item: MenuBarItem) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard AXHelpers.isProcessTrusted() else { return false }

        for runningApp in NSWorkspace.shared.runningApplications
        where namespace(for: runningApp) == item.tag.namespace {
            guard
                let application = AXHelpers.application(for: runningApp),
                let extrasMenuBar = AXHelpers.extrasMenuBar(for: application)
            else {
                continue
            }

            let candidates = AXHelpers.children(for: extrasMenuBar).compactMap { child -> (UIElement, String, CGRect)? in
                guard let frame = AXHelpers.frame(for: child), frame.height > 0, frame.height <= maxItemHeight else {
                    return nil
                }
                let descendants = AXHelpers.children(for: child)
                let identifier = nonEmpty(AXHelpers.identifier(for: child))
                    ?? descendants.lazy.compactMap { nonEmpty(AXHelpers.identifier(for: $0)) }.first
                let accessibilityDescription = nonEmpty(AXHelpers.description(for: child))
                    ?? descendants.lazy.compactMap { nonEmpty(AXHelpers.description(for: $0)) }.first
                let title = identifier
                    ?? accessibilityDescription
                    ?? nonEmpty(AXHelpers.title(for: child))
                    ?? "Item-0"
                return (child, title, frame)
            }.sorted { $0.2.minX < $1.2.minX }

            var instanceIndex = 0
            for candidate in candidates where candidate.1 == item.tag.title {
                if instanceIndex == item.tag.instanceIndex {
                    return AXHelpers.press(candidate.0)
                }
                instanceIndex += 1
            }
        }
        return false
    }

    private struct RawItem {
        let namespace: MenuBarItemTag.Namespace
        let identityTitle: String
        let displayTitle: String
        let bounds: CGRect
        let ownerPID: pid_t
    }

    private static func assemble(_ rawItems: [RawItem]) -> [MenuBarItem] {
        let sorted = rawItems.sorted { lhs, rhs in
            if lhs.bounds.minX == rhs.bounds.minX {
                return lhs.bounds.minY < rhs.bounds.minY
            }
            return lhs.bounds.minX < rhs.bounds.minX
        }
        var seenIceControlItems = Set<String>()
        var nextIndexByIdentity = [String: Int]()

        return sorted.compactMap { rawItem in
            guard !isNativeOverflowPlaceholder(rawItem.identityTitle) else {
                return nil
            }

            // AppKit publishes both the primary scene and a presentation
            // variant for Ice's NSStatusItems on macOS 27. They have the same
            // accessibility identifier and represent one logical button. Ice
            // control identifiers are unique, so retain only one variant.
            if
                rawItem.namespace == .ice,
                ControlItem.Identifier(rawValue: rawItem.identityTitle) != nil,
                !seenIceControlItems.insert(rawItem.identityTitle).inserted
            {
                return nil
            }

            let identity = "\(rawItem.namespace):\(rawItem.identityTitle)"
            let instanceIndex = nextIndexByIdentity[identity, default: 0]
            nextIndexByIdentity[identity] = instanceIndex + 1
            let windowID = syntheticWindowID(identity: identity, instanceIndex: instanceIndex)
            let tag = MenuBarItemTag(
                namespace: rawItem.namespace,
                title: rawItem.identityTitle,
                instanceIndex: instanceIndex
            )
            return MenuBarItem(
                tag: tag,
                windowID: windowID,
                ownerPID: rawItem.ownerPID,
                sourcePID: rawItem.ownerPID,
                bounds: rawItem.bounds,
                title: rawItem.displayTitle,
                isOnScreen: true
            )
        }
    }

    private static func namespace(for app: NSRunningApplication) -> MenuBarItemTag.Namespace {
        switch app.bundleIdentifier {
        case "com.apple.MenuBarAgent":
            // Preserve Ice's existing Control Center item identities.
            return .controlCenter
        case Constants.bundleIdentifier:
            return .ice
        case let bundleIdentifier?:
            return .string(bundleIdentifier)
        case nil:
            return .optional(app.localizedName)
        }
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isNativeOverflowPlaceholder(_ title: String) -> Bool {
        let normalized = title.lowercased()
        return normalized.contains("overflow") || normalized.contains("chevron")
    }

    private static func syntheticWindowID(identity: String, instanceIndex: Int) -> CGWindowID {
        var hash: UInt32 = 0x811C_9DC5
        for byte in "\(identity):\(instanceIndex)".utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return CGWindowID(0x8000_0000 | (hash & 0x7FFF_FFFF))
    }
}
