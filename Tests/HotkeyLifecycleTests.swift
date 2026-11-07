import AppKit
import OSLog

struct KeyCombination: Hashable {
    var key = Key.escape
    enum Key: Hashable { case escape }
    var modifiers: NSEvent.ModifierFlags = .command
    var displayValue: String { "⌘A" }
    var isSystemReserved: Bool { false }
    init() { }
    init(event: NSEvent) { modifiers = event.modifierFlags }
    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }
}
enum HotkeyAction: Hashable {
    case test
    @MainActor func perform(appState: AppState) { }
}
final class HotkeyRegistry {
    enum EventKind { case keyDown }
    var active = Set<UInt32>()
    private var next: UInt32 = 0
    func register(hotkey: Hotkey, eventKind: EventKind, handler: @escaping () -> Void) -> UInt32? {
        next += 1; active.insert(next); return next
    }
    func unregister(_ id: UInt32) { active.remove(id) }
}
final class AppState {
    struct Settings {
        struct Hotkeys { let registry = HotkeyRegistry() }
        let hotkeys = Hotkeys()
    }
    let settings = Settings()
}
final class EventMonitor {
    static var active = 0
    private var started = false
    static func local(for mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> EventMonitor { Self() }
    func start() { if !started { started = true; Self.active += 1 } }
    func stop() { if started { started = false; Self.active -= 1 } }
}
extension Logger {
    static let hotkeys = Logger(subsystem: "FloeBar.Tests", category: "Hotkeys")
}

@main
enum HotkeyLifecycleTests {
    @MainActor static func main() {
        let state = AppState()
        let hotkey = Hotkey(action: .test, keyCombination: KeyCombination())
        hotkey.performSetup(with: state)
        let model = HotkeyRecorderModel(hotkey: hotkey)
        let registry = state.settings.hotkeys.registry
        precondition(hotkey.isEnabled && registry.active.count == 1)
        for notification in [NSApplication.didResignActiveNotification, NSWindow.willCloseNotification] {
            model.startRecording()
            model.startRecording()
            precondition(model.isRecording && !hotkey.isEnabled && registry.active.isEmpty && EventMonitor.active == 1)
            NotificationCenter.default.post(name: notification, object: nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            precondition(!model.isRecording && hotkey.isEnabled && registry.active.count == 1 && EventMonitor.active == 0)
            model.stopRecording()
            precondition(registry.active.count == 1)
        }
        model.startRecording()
        model.stopRecording() // The view's onDisappear calls the same method.
        precondition(hotkey.isEnabled && EventMonitor.active == 0)
        let empty = Hotkey(action: .test)
        empty.performSetup(with: state)
        let emptyModel = HotkeyRecorderModel(hotkey: empty)
        emptyModel.startRecording()
        emptyModel.stopRecording()
        precondition(!empty.isEnabled && registry.active.count == 1)
        print("PASS: real hotkey listener restoration on cancel, app resignation and window close; no duplicate registration")
    }
}
