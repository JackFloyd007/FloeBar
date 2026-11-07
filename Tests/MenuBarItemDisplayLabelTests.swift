import Foundation

@main
struct MenuBarItemDisplayLabelTests {
    typealias L = MenuBarItemDisplayLabel
    static func main() {
        precondition(L.semantic(app: "Stats", description: "Stats", title: "Stats", help: "CPU: 迷你", identifier: "CPU_mini") == "CPU: 迷你")
        precondition(L.semantic(app: "Stats", description: nil, title: "42%", help: nil, identifier: "com.stats.cpu") == nil)
        precondition(L.semantic(app: "Stats", description: "内存: 迷你", title: "Stats", help: nil, identifier: nil) == "内存: 迷你")
        precondition(L.semantic(app: "Stats", description: nil, title: "Item-3", help: nil, identifier: UUID().uuidString) == nil)
        var registry = L.Registry()
        let known = [L.Item(identity: "cpu", group: "stats:1", app: "Stats", semantic: "CPU: 迷你"), L.Item(identity: "memory", group: "stats:1", app: "Stats", semantic: "内存: 迷你")]
        let names = registry.presentations(for: known)
        precondition(names.count == 2 && names["cpu"]?.title == "CPU: 迷你" && names["memory"]?.title == "内存: 迷你")
        precondition(names["cpu"]?.accessibilityLabel.contains("Stats") == true)
        let unknown = [L.Item(identity: "a", group: "app:1", app: "App", semantic: nil), L.Item(identity: "b", group: "app:1", app: "App", semantic: nil)]
        let first = registry.presentations(for: unknown)
        let reordered = registry.presentations(for: unknown.reversed())
        precondition(first["a"]?.title == reordered["a"]?.title && first["b"]?.title == reordered["b"]?.title)
        precondition(first["a"]?.title != first["b"]?.title && first["a"]?.detail != nil)
        let duplicate = unknown.map { L.Item(identity: $0.identity, group: $0.group, app: $0.app, semantic: "CPU") }
        let duplicates = registry.presentations(for: duplicate)
        precondition(duplicates.count == 2 && duplicates["a"]?.title != duplicates["b"]?.title)
        let again = registry.presentations(for: duplicate.reversed())
        precondition(duplicates["a"]?.title == again["a"]?.title)
        print("MenuBarItemDisplayLabelTests passed")
    }
}
