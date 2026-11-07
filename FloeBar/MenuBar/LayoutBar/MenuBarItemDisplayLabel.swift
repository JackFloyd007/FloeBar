//
//  MenuBarItemDisplayLabel.swift
//  FloeBar
//

import Foundation

/// Presentation only. Neither these strings nor ordinals identify AX endpoints
/// or enter the persisted menu bar layout.
enum MenuBarItemDisplayLabel {
    static func semantic(app: String, description: String?, title: String?, help: String?, identifier: String?) -> String? {
        let generic = ["menu bar item", "menu extra", "status item", "menubarextra", "菜单栏项目"]
        for (index, field) in [description, title, help, identifier].enumerated() {
            guard let value = field?.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty, value.count <= 160,
                value.rangeOfCharacter(from: .letters) != nil,
                value.caseInsensitiveCompare(app) != .orderedSame,
                !generic.contains(value.lowercased()),
                !value.hasPrefix(MacOS27RuntimeItemIdentity.prefix),
                UUID(uuidString: value) == nil,
                value.range(of: "^Item-[0-9]+$", options: .regularExpression) == nil else { continue }
            // Programmatic namespace-like identifiers are not readable labels.
            if index == 3, value.contains(".") { continue }
            return value
        }
        return nil
    }

    struct Item {
        let identity: String
        let group: String
        let app: String
        let semantic: String?
    }

    struct Presentation {
        let title: String
        let accessibilityLabel: String
        let detail: String?
    }

    struct Registry {
        private var ordinals = [String: Int]()
        private var next = [String: Int]()

        mutating func presentations(for items: [Item]) -> [String: Presentation] {
            let groups = Dictionary(grouping: items, by: \.group)
            var result = [String: Presentation]()
            for item in items {
                let key = item.group + "|" + item.identity
                if ordinals[key] == nil {
                    let ordinal = (next[item.group] ?? 0) + 1
                    next[item.group] = ordinal
                    ordinals[key] = ordinal
                }
                let peers = groups[item.group] ?? []
                if let semantic = item.semantic {
                    let duplicates = peers.filter { $0.semantic?.caseInsensitiveCompare(semantic) == .orderedSame }.count
                    let suffix = duplicates > 1 ? " (\(ordinals[key] ?? 1))" : ""
                    result[item.identity] = Presentation(
                        title: semantic + suffix,
                        accessibilityLabel: item.app + " · " + semantic + suffix,
                        detail: duplicates > 1 ? String(localized: "Multiple items share this label. The number identifies the item only in this app session.") : nil
                    )
                } else {
                    let title = peers.count > 1
                        ? String.localizedStringWithFormat(String(localized: "%@ · Item %lld"), item.app, ordinals[key] ?? 1)
                        : item.app
                    result[item.identity] = Presentation(
                        title: title,
                        accessibilityLabel: title,
                        detail: String(localized: "Purpose unknown. Item numbers apply only to the current app session.")
                    )
                }
            }
            return result
        }
    }
}
