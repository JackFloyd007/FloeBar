import Foundation
@main enum NativeOverflowLabelsTests {
    static func main() {
        let labels = NativeOverflowLabels(table: ["de": [
            "menuBar.showOverflowItemsAccessibilityLabel": "Ausgeblendete Objekte anzeigen",
            "menuBar.hideOverflowItemsAccessibilityLabel": "Objekte ausblenden"
        ]])
        precondition(labels.expanded(label: "显示隐藏菜单栏项目", isAgent: true, isButton: true) == false)
        precondition(labels.expanded(label: "隐藏菜单栏项目", isAgent: true, isButton: true) == true)
        precondition(labels.expanded(label: "Ausgeblendete Objekte anzeigen", isAgent: true, isButton: true) == false)
        precondition(labels.expanded(label: "Apple密码钥匙", isAgent: true, isButton: true) == nil)
        precondition(labels.expanded(label: "Show Hidden Menu Bar Items", isAgent: false, isButton: true) == nil)
        precondition(labels.expanded(label: "Hide Menu Bar Items", isAgent: true, isButton: false) == nil)
        precondition(labels.expanded(label: nil, isAgent: true, isButton: true) == nil)
        precondition(labels.expanded(label: "overflow", isAgent: true, isButton: true) == nil)
        let ambiguous = NativeOverflowLabels(table: ["bad": [
            "menuBar.showOverflowItemsAccessibilityLabel": "same",
            "menuBar.hideOverflowItemsAccessibilityLabel": "same"
        ]])
        precondition(ambiguous.expanded(label: "same", isAgent: true, isButton: true) == nil)
        print("PASS: overflow requires exact system semantics, owner and role; Passwords and ambiguous labels rejected")
    }
}
