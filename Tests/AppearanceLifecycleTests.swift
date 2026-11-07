import AppKit
import OSLog

// Stub only the external windows/settings; panel lifecycle uses the real manager.
struct MenuBarAppearancePartialConfiguration: Codable {
    enum Tint: String, Codable { case noTint, solid }
    var hasShadow = false
    var hasBorder = false
    var tintKind = Tint.noTint
}
struct MenuBarAppearanceConfigurationV2: Codable {
    enum Shape: String, Codable { case noShape, full }
    var shapeKind = Shape.noShape
    var isDynamic = false
    var lightModeConfiguration = MenuBarAppearancePartialConfiguration()
    var darkModeConfiguration = MenuBarAppearancePartialConfiguration()
    var staticConfiguration = MenuBarAppearancePartialConfiguration()
    static let defaultConfiguration = Self()
}
final class AppState { }
final class MenuBarOverlayPanel: NSObject {
    var needsShow = false
    static var closes = 0
    init(appState: AppState, owningScreen: NSScreen) { }
    func close() { Self.closes += 1 }
}
enum Defaults {
    enum Key { case menuBarAppearanceConfigurationV2 }
    static func data(forKey: Key) -> Data? { nil }
    static func set(_ data: Data, forKey: Key) { }
}
extension Logger {
    static let serialization = Logger(subsystem: "FloeBar.Tests", category: "Serialization")
}

@main
enum AppearanceLifecycleTests {
    @MainActor static func main() {
        let model = MenuBarAppearanceManager()
        let state = AppState()
        model.performSetup(with: state)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        settle()
        precondition(model.overlayPanels.isEmpty)
        model.configuration.isDynamic = true
        model.configuration.darkModeConfiguration.hasBorder = true
        settle()
        precondition(model.overlayPanels.count == NSScreen.screens.count)
        precondition(model.overlayPanels.allSatisfy(\.needsShow))
        let original = model.overlayPanels
        model.configuration.darkModeConfiguration.hasBorder = false
        model.configuration.lightModeConfiguration.hasShadow = true
        settle()
        precondition(model.overlayPanels == original, "theme variants share the existing native panels")
        model.configuration.isDynamic = false
        settle()
        precondition(model.overlayPanels.isEmpty && MenuBarOverlayPanel.closes == original.count)
        model.configuration.staticConfiguration.tintKind = .solid
        settle()
        precondition(model.overlayPanels.count == NSScreen.screens.count)
        model.configuration.staticConfiguration.tintKind = .noTint
        settle()
        precondition(model.overlayPanels.isEmpty)
        print("PASS: dynamic light/dark effects, native panel reuse, static configuration and all-off cleanup")
    }
}
