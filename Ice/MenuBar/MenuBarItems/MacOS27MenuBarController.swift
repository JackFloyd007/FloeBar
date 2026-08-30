//
//  MacOS27MenuBarController.swift
//  Ice
//

import Cocoa
import OSLog

/// Assignment-backed menu bar section management for macOS 27.
///
/// Divider geometry can no longer hide items on macOS 27. This controller
/// persists logical section membership and applies it through MenuBarClientCore's
/// process-bound assessment-mode allowlist. The private API is loaded at runtime
/// and degrades to a read-only layout if Apple removes it.
@MainActor
final class MacOS27MenuBarController {
    private struct StoredLayout: Codable {
        var assignments = [String: MenuBarSection.Name]()
        var order = [MenuBarSection.Name: [String]]()
    }

    private static let defaultsKey = "MacOS27MenuBarController.layout.v1"
    private static let allSystemItemIdentifiers = Set(0 ... 8)
    private static let systemHostBundleIdentifiers: Set<String> = [
        "com.apple.MenuBarAgent",
        "com.apple.controlcenter",
    ]

    private let logger = Logger(category: "MacOS27MenuBarController")
    private var layout: StoredLayout
    private var snapshots = [String: MenuBarItem]()
    private var knownBundleIdentifiers = [String: String]()
    private var knownSystemItemIdentifiers = [String: Int]()
    private var lastLiveItems = [MenuBarItem]()
    private var revealedSection: MenuBarSection.Name?
    private var assertionHandle: UnsafeMutableRawPointer?
    private var appliedAllowedBundleIdentifiers = Set<String>()
    private var appliedAllowedSystemItemIdentifiers = Set(0 ... 8)
    private var activationGeneration = 0

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
        IceAssessmentModeHidingInvalidate(assertionHandle)
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
        displayID: CGDirectDisplayID?
    ) -> MenuBarItemManager.ItemCache {
        precondition(Thread.isMainThread)
        lastLiveItems = liveItems

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

        if !liveItems.isEmpty {
            lastLiveItems = liveItems
        }

        let concealedSections: Set<MenuBarSection.Name> = switch revealedSection {
        case .alwaysHidden: []
        case .hidden: [.alwaysHidden]
        case .visible, nil: [.hidden, .alwaysHidden]
        }
        let concealedIdentifiers = Set(layout.assignments.compactMap { identifier, section in
            concealedSections.contains(section) ? identifier : nil
        })

        var bundlesWithVisibleItems = Set<String>()
        for item in lastLiveItems {
            let identifier = item.tag.persistentIdentifier
            guard !concealedIdentifiers.contains(identifier),
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
        concealedBundleIdentifiers.subtract(Self.systemHostBundleIdentifiers)
        concealedBundleIdentifiers.remove(Constants.bundleIdentifier)

        let concealedSystemIdentifiers = Set(concealedIdentifiers.compactMap {
            knownSystemItemIdentifiers[$0]
        })
        let allowedSystemIdentifiers = Self.allSystemItemIdentifiers
            .subtracting(concealedSystemIdentifiers)

        let runningBundleIdentifiers = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        var allowedBundleIdentifiers = runningBundleIdentifiers
            .subtracting(concealedBundleIdentifiers)
        allowedBundleIdentifiers.insert(Constants.bundleIdentifier)
        allowedBundleIdentifiers.formUnion(Self.systemHostBundleIdentifiers)
        allowedBundleIdentifiers.formUnion(
            knownBundleIdentifiers.values.filter { !concealedBundleIdentifiers.contains($0) }
        )

        let hasActiveConcealment = !concealedBundleIdentifiers.isEmpty ||
            allowedSystemIdentifiers != Self.allSystemItemIdentifiers
        guard hasActiveConcealment else {
            invalidateAssertion()
            return
        }

        guard assertionHandle == nil ||
                allowedBundleIdentifiers != appliedAllowedBundleIdentifiers ||
                allowedSystemIdentifiers != appliedAllowedSystemItemIdentifiers
        else {
            return
        }

        invalidateAssertion()
        activationGeneration += 1
        let generation = activationGeneration
        assertionHandle = IceAssessmentModeHidingActivate(
            allowedBundleIdentifiers.sorted(),
            allowedSystemIdentifiers.sorted().map(NSNumber.init(value:))
        ) { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.activationGeneration else { return }
                self.logger.error("macOS 27 assessment-mode activation failed")
                self.invalidateAssertion()
            }
        }
        appliedAllowedBundleIdentifiers = allowedBundleIdentifiers
        appliedAllowedSystemItemIdentifiers = allowedSystemIdentifiers

        if assertionHandle == nil {
            logger.error("macOS 27 assessment-mode hiding is unavailable")
        }
    }

    private func invalidateAssertion() {
        if let assertionHandle {
            IceAssessmentModeHidingInvalidate(assertionHandle)
        }
        assertionHandle = nil
        appliedAllowedBundleIdentifiers.removeAll()
        appliedAllowedSystemItemIdentifiers = Self.allSystemItemIdentifiers
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func bundleIdentifier(for item: MenuBarItem) -> String? {
        item.sourceApplication?.bundleIdentifier ?? item.owningApplication?.bundleIdentifier
    }

    private func systemItemIdentifier(for tag: MenuBarItemTag) -> Int? {
        tag.macOS27SystemItemIdentifier
    }
}
