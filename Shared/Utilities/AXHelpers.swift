//
//  AXHelpers.swift
//  Shared
//

@preconcurrency import AXSwift
import Cocoa

enum AXHelpers {
    private static let queue = DispatchQueue.targetingGlobal(
        label: "AXHelpers.queue",
        qos: .userInteractive
    )

    /// Child AX elements do not inherit a timeout set on an application's
    /// root element. Configure the process-wide fallback once so a child that
    /// disappears while MenuBarAgent is recomposing cannot block the serialized
    /// scan for the Accessibility API's multi-second default timeout.
    private static let globalMessagingTimeoutConfiguration: Void = {
        AXUIElementSetMessagingTimeout(systemWideElement.element, 0.25)
    }()

    @discardableResult
    static func isProcessTrusted(prompt: Bool = false) -> Bool {
        queue.sync { checkIsProcessTrusted(prompt: prompt) }
    }

    static func element(at point: CGPoint) -> UIElement? {
        queue.sync {
            _ = globalMessagingTimeoutConfiguration
            return try? systemWideElement.elementAtPosition(Float(point.x), Float(point.y))
        }
    }

    static func application(for runningApp: NSRunningApplication) -> Application? {
        queue.sync {
            _ = globalMessagingTimeoutConfiguration
            let application = Application(runningApp)
            if let application {
                // A stalled application's accessibility server must not block
                // the complete menu bar scan indefinitely.
                AXUIElementSetMessagingTimeout(application.element, 0.25)
            }
            return application
        }
    }

    static func extrasMenuBar(for app: Application) -> UIElement? {
        queue.sync { try? app.attribute(.extrasMenuBar) }
    }

    static func children(for element: UIElement) -> [UIElement] {
        queue.sync { try? element.arrayAttribute(.children) } ?? []
    }

    static func isEnabled(_ element: UIElement) -> Bool {
        queue.sync { try? element.attribute(.enabled) } ?? false
    }

    static func frame(for element: UIElement) -> CGRect? {
        queue.sync { try? element.attribute(.frame) }
    }

    static func role(for element: UIElement) -> Role? {
        queue.sync { try? element.role() }
    }

    static func title(for element: UIElement) -> String? {
        queue.sync { try? element.attribute(.title) }
    }

    static func identifier(for element: UIElement) -> String? {
        queue.sync { try? element.attribute(.identifier) }
    }

    static func description(for element: UIElement) -> String? {
        queue.sync { try? element.attribute(.description) }
    }

    static func pid(for element: UIElement) -> pid_t? {
        queue.sync {
            var pid: pid_t = 0
            return AXUIElementGetPid(element.element, &pid) == .success ? pid : nil
        }
    }

    @discardableResult
    static func press(_ element: UIElement) -> Bool {
        queue.sync {
            do {
                try element.performAction(.press)
                return true
            } catch {
                return false
            }
        }
    }
}
