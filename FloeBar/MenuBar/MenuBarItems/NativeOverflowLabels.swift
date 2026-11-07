//
//  NativeOverflowLabels.swift
//  FloeBar
//

import Foundation

/// Match the system's semantic labels, never a small anonymous button's shape.
struct NativeOverflowLabels {
    static let system: NativeOverflowLabels = {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/MenuBarAgent.app/Contents/Resources/MenuBarCore.loctable")
        let table = (try? Data(contentsOf: url)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        return NativeOverflowLabels(table: table ?? [:])
    }()

    var show: Set<String> = ["Show Hidden Menu Bar Items", "显示隐藏菜单栏项目", "顯示隱藏的選單列項目"]
    var hide: Set<String> = ["Hide Menu Bar Items", "隐藏菜单栏项目", "隱藏選單列項目"]

    init(table: [String: Any] = [:]) {
        for case let translations as [String: Any] in table.values {
            if let value = translations["menuBar.showOverflowItemsAccessibilityLabel"] as? String { show.insert(value) }
            if let value = translations["menuBar.hideOverflowItemsAccessibilityLabel"] as? String { hide.insert(value) }
        }
    }

    func expanded(label: String?, isAgent: Bool, isButton: Bool) -> Bool? {
        guard isAgent, isButton, let label else { return nil }
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard show.contains(text) != hide.contains(text) else { return nil }
        return hide.contains(text)
    }
}
