import AppKit
import OSLog

enum Constants { static let bundleIdentifier = "FloeBar.Tests" }
enum MenuBarSection {
    enum Name: String, CaseIterable, Codable { case visible, hidden, alwaysHidden }
}
enum ControlItem {
    enum Identifier: String, CaseIterable {
        case visible = "Ice.ControlItem.Visible"
        case hidden = "Ice.ControlItem.Hidden"
        case alwaysHidden = "Ice.ControlItem.AlwaysHidden"
        var tag: MenuBarItemTag { MenuBarItemTag(namespace: .ice, title: rawValue) }
    }
}
struct MenuBarItem: Equatable {
    var tag: MenuBarItemTag
    var bounds: CGRect
    var ownerPID: pid_t = -1
    var sourcePID: pid_t? { nil }
    var isControlItem: Bool { tag.isControlItem }
    var sourceApplication: NSRunningApplication? { nil }
    var owningApplication: NSRunningApplication? { nil }
}
extension Collection where Element == MenuBarItem {
    func first(matching tag: MenuBarItemTag) -> MenuBarItem? { first { $0.tag == tag } }
}
enum MenuBarItemManager {
    struct ItemCache {
        var displayID: CGDirectDisplayID?
        var sections: [MenuBarSection.Name: [MenuBarItem]] = [:]
        subscript(_ section: MenuBarSection.Name) -> [MenuBarItem] {
            get { sections[section, default: []] }
            set { sections[section] = newValue }
        }
        func address(for tag: MenuBarItemTag) -> (section: MenuBarSection.Name, index: Int)? {
            for section in MenuBarSection.Name.allCases {
                if let index = self[section].firstIndex(where: { $0.tag == tag }) { return (section, index) }
            }
            return nil
        }
    }
    enum MoveDestination {
        case leftOfItem(MenuBarItem), rightOfItem(MenuBarItem)
        var targetItem: MenuBarItem {
            switch self { case .leftOfItem(let item), .rightOfItem(let item): item }
        }
    }
}
enum MacOS27MenuBarItemProvider {
    static func confirmedAbsentIdentifiers(for items: [MenuBarItem]) -> Set<String> { [] }
}
extension Logger {
    init(category: String) { self.init(subsystem: "FloeBar.Tests", category: category) }
    static let serialization = Logger(category: "Serialization")
}
