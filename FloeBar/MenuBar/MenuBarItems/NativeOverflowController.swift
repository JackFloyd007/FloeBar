//
//  NativeOverflowController.swift
//  FloeBar
//

import AppKit
import ApplicationServices
import OSLog

/// Controls the native overflow, independently from any private hide assertion.
/// Pointer fallback requires a fresh semantic target and exact physical hit.
/// An action return code never counts as visibility proof.
@MainActor
final class NativeOverflowController {
    private let logger = Logger(category: "NativeOverflowController")
    private var busy = false
    private let labels = NativeOverflowLabels.system

    private struct Target {
        let element: AXUIElement
        let expanded: Bool
        let frame: CGRect
    }

    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private func target(_ element: AXUIElement, pid: pid_t, bar: CGRect) -> Target? {
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success,
              let expanded = labels.expanded(
                label: attribute(element, kAXDescriptionAttribute as CFString) as? String
                    ?? attribute(element, kAXTitleAttribute as CFString) as? String,
                isAgent: owner == pid,
                isButton: attribute(element, kAXRoleAttribute as CFString) as? String == kAXButtonRole
              ),
              let position = attribute(element, kAXPositionAttribute as CFString),
              let size = attribute(element, kAXSizeAttribute as CFString),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        // The CF type IDs above establish these concrete Core Foundation types.
        let positionValue = unsafeBitCast(position, to: AXValue.self)
        let sizeValue = unsafeBitCast(size, to: AXValue.self)
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &dimensions) else { return nil }
        let frame = CGRect(origin: point, size: dimensions)
        guard frame.width > 0, frame.height > 0, frame.width < 80,
              bar.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
        return Target(element: element, expanded: expanded, frame: frame)
    }

    private func find(on display: CGDirectDisplayID) -> Target? {
        guard AXIsProcessTrusted(), let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return nil }
        let bounds = CGDisplayBounds(display)
        let bar = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 40)
        let root = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        var queue = [root]
        var visited = [AXUIElement]()
        var matches = [Target]()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        while !queue.isEmpty, visited.count < 120, ProcessInfo.processInfo.systemUptime < deadline {
            let element = queue.removeFirst()
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            visited.append(element)
            if let match = target(element, pid: agent.processIdentifier, bar: bar) { matches.append(match) }
            for key in [kAXChildrenAttribute, kAXWindowsAttribute] {
                if let children = attribute(element, key as CFString) as? [AXUIElement] { queue.append(contentsOf: children) }
            }
            if CFEqual(element, root), let extras = attribute(root, kAXExtrasMenuBarAttribute as CFString), CFGetTypeID(extras) == AXUIElementGetTypeID() {
                queue.append(unsafeBitCast(extras, to: AXUIElement.self))
            }
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { return nil }
        // Some OS builds omit this button from the hierarchy. Read-only hit
        // tests can discover it; exact label + owner checks remain mandatory.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        for x in stride(from: bar.midX, to: bar.maxX - 100, by: 6) {
            guard ProcessInfo.processInfo.systemUptime < deadline + 0.6 else { break }
            var element: AXUIElement?
            if AXUIElementCopyElementAtPosition(system, Float(x), Float(bar.minY + 15), &element) == .success,
               let element, let match = target(element, pid: agent.processIdentifier, bar: bar) { return match }
        }
        return nil
    }

    private func pressPhysicalTarget(_ expected: Target) -> Bool {
        let point = CGPoint(x: expected.frame.midX, y: expected.frame.midY)
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit, CFEqual(hit, expected.element) else {
            logger.error("Native overflow physical hit does not match; no click posted")
            return false
        }
        // Nothing asynchronous, no resize, no owner activation between final
        // hit verification and this paired click. Never reuse saved coordinates.
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseDown,
                  mouseCursorPosition: point,
                  mouseButton: .left
              ),
              let up = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseUp,
                  mouseCursorPosition: point,
                  mouseButton: .left
              ) else { return false }
        guard !CGEventSource.buttonState(.combinedSessionState, button: .left),
              !CGEventSource.buttonState(.combinedSessionState, button: .right),
              CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: [.maskCommand, .maskShift, .maskControl, .maskAlternate]) else { return false }
        let previous = CGEvent(source: nil)?.location
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        if let previous { CGWarpMouseCursorPosition(previous) }
        logger.notice("Native overflow exact-hit click posted")
        return true
    }

    /// nil requests a toggle from the CURRENT system state, not our cached arrow.
    func change(expanded requested: Bool?, on display: CGDirectDisplayID) async -> Bool? {
        guard !busy, !Task.isCancelled else { return nil }
        busy = true
        defer { busy = false }
        guard let before = find(on: display) else { logger.notice("Native overflow unavailable or ambiguous"); return nil }
        let desired = requested ?? !before.expanded
        if before.expanded == desired { return desired }
        // Resolve a second time immediately before invoking the semantic action.
        guard let live = find(on: display), CFEqual(live.element, before.element),
              live.expanded == before.expanded, live.frame == before.frame else { return nil }
        guard !Task.isCancelled else { return nil }
        let result = AXUIElementPerformAction(live.element, kAXPressAction as CFString)
        logger.notice("Native overflow AXPress result: \(result.rawValue)")
        if result == .actionUnsupported || result == .notImplemented {
            guard let latest = find(on: display), CFEqual(latest.element, live.element),
                  latest.expanded == before.expanded else { return nil }
            guard pressPhysicalTarget(latest) else { return nil }
        }
        for _ in 0..<8 {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
            if let current = find(on: display), current.expanded == desired { return desired }
        }
        logger.error("Native overflow did not reach requested state")
        return nil
    }
}
