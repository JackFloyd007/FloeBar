//
//  SystemAppVisibilityVerifier.swift
//  FloeBar
//

import AppKit
import ApplicationServices
import OSLog

/// Optional physical evidence. Preferences and recovery never depend on AX.
/// Missing objects, labels and failed hits are deliberately not hidden proof.
@MainActor
final class SystemAppVisibilityVerifier {
    struct Generation: Equatable {
        let pid: pid_t
        let launched: Date
    }

    struct Parent {
        let element: AXUIElement
        let generation: Generation
        let children: [AXUIElement]
        let visible: [AXUIElement]
    }

    struct Target {
        let element: AXUIElement
        let parent: Parent
        let frame: CGRect
    }

    struct Baseline {
        let bundle: String
        let source: Generation
        let bar: AXUIElement
        let sourceChildren: [AXUIElement]
        let targets: [Target]
        let display: CGDirectDisplayID
        let displayBounds: CGRect
    }

    private struct Unavailable: Error {
        let stage: String
        let code: Int32
    }

    private let logger = Logger(category: "SystemAppVisibilityProof")
    private let limit = 32

    func capture(bundles: [String]) async -> [String: Baseline] {
        guard #available(macOS 27.0, *), AXIsProcessTrusted() else { return [:] }
        let context = NativeMenuBarScanContext(purpose: "visibility-proof-baseline", budget: 1.5)
        var result = [String: Baseline]()
        for bundle in bundles {
            do {
                let baseline = try await capture(bundle: bundle, context: context)
                result[bundle] = baseline
                logger.notice("Visibility proof baseline target=\(bundle, privacy: .public) status=ready source_pid=\(baseline.source.pid) items=\(baseline.targets.count)")
            } catch { log(error, bundle: bundle, phase: "baseline") }
        }
        return result
    }

    private func generation(_ pid: pid_t) throws -> Generation {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
            let launched = app.launchDate else { throw Unavailable(stage: "process-generation", code: 0) }
        return Generation(pid: pid, launched: launched)
    }

    private func source(_ bundle: String) throws -> Generation {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).filter { !$0.isTerminated }
        guard applications.count == 1, let application = applications.first else { throw Unavailable(stage: "source-ambiguous", code: 0) }
        return try generation(application.processIdentifier)
    }

    private func pid(_ element: AXUIElement) throws -> pid_t {
        var value: pid_t = 0
        let error = AXUIElementGetPid(element, &value)
        guard error == .success, value > 0 else { throw Unavailable(stage: "element-pid", code: error.rawValue) }
        return value
    }

    private func read(_ element: AXUIElement, _ name: String, stage: String, context: NativeMenuBarScanContext) async throws -> CFTypeRef {
        try Task.checkCancellation()
        let value = try await context.readOnMain { timeout in
            guard AXUIElementSetMessagingTimeout(element, timeout) == .success else { throw Unavailable(stage: stage + ".timeout", code: 0) }
            defer { AXUIElementSetMessagingTimeout(element, 0.25) }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            guard error == .success, let value else { throw Unavailable(stage: stage, code: error.rawValue) }
            return value
        }
        try Task.checkCancellation()
        return value
    }

    private func element(_ value: CFTypeRef, stage: String) throws -> AXUIElement {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw Unavailable(stage: stage + ".type", code: 0) }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func children(_ element: AXUIElement, visible: Bool = false, stage: String, context: NativeMenuBarScanContext) async throws -> [AXUIElement] {
        let value = try await read(element, visible ? kAXVisibleChildrenAttribute : kAXChildrenAttribute, stage: stage, context: context)
        guard let values = value as? [AXUIElement], values.count <= limit,
            values.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { throw Unavailable(stage: stage + ".type-or-cap", code: 0) }
        return values
    }

    private func frame(_ element: AXUIElement, context: NativeMenuBarScanContext) async throws -> CGRect {
        do {
            let value = try await read(element, "AXFrame", stage: "target.frame", context: context)
            guard CFGetTypeID(value) == AXValueGetTypeID() else { throw Unavailable(stage: "target.frame.type", code: 0) }
            let wrapped = unsafeBitCast(value, to: AXValue.self)
            var bounds = CGRect.zero
            guard AXValueGetType(wrapped) == .cgRect, AXValueGetValue(wrapped, .cgRect, &bounds) else { throw Unavailable(stage: "target.frame.type", code: 0) }
            return bounds
        } catch let failure as Unavailable where failure.code == AXError.attributeUnsupported.rawValue || failure.code == AXError.noValue.rawValue {
            let position = try await read(element, kAXPositionAttribute, stage: "target.position", context: context)
            let size = try await read(element, kAXSizeAttribute, stage: "target.size", context: context)
            guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { throw Unavailable(stage: "target.geometry.type", code: 0) }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { throw Unavailable(stage: "target.geometry.type", code: 0) }
            return CGRect(origin: point, size: dimensions)
        }
    }

    private func exactHit(_ target: AXUIElement, bounds: CGRect, context: NativeMenuBarScanContext) async throws -> Bool {
        let system = AXUIElementCreateSystemWide()
        var candidate: AXUIElement? = try await context.readOnMain { timeout in
            let timeoutResult = AXUIElementSetMessagingTimeout(system, timeout)
            guard timeoutResult == .success else { throw Unavailable(stage: "target.hit-timeout", code: timeoutResult.rawValue) }
            defer { AXUIElementSetMessagingTimeout(system, 0.25) }
            var hit: AXUIElement?
            let error = AXUIElementCopyElementAtPosition(system, Float(bounds.midX), Float(bounds.midY), &hit)
            guard error == .success, let hit else { throw Unavailable(stage: "target.hit", code: error.rawValue) }
            return hit
        }
        for _ in 0..<4 {
            guard let current = candidate else { return false }
            if CFEqual(current, target) { return true }
            candidate = try await element(read(current, kAXParentAttribute, stage: "hit.parent", context: context), stage: "hit.parent")
        }
        return false
    }

    private func capture(bundle: String, context: NativeMenuBarScanContext) async throws -> Baseline {
        try context.check()
        guard let display = Bridging.getActiveMenuBarDisplayID() else { throw Unavailable(stage: "display", code: 0) }
        let displayBounds = CGDisplayBounds(display)
        let source = try source(bundle)
        let app = AXUIElementCreateApplication(source.pid)
        let bar = try await element(read(app, kAXExtrasMenuBarAttribute, stage: "source.extras", context: context), stage: "source.extras")
        let items = try await children(bar, stage: "source.children", context: context)
        guard !items.isEmpty else { throw Unavailable(stage: "source.empty-unproven", code: 0) }
        var targets = [Target]()
        let strip = CGRect(x: displayBounds.minX, y: displayBounds.minY, width: displayBounds.width, height: 40)
        for item in items {
            let bounds = try await frame(item, context: context)
            guard bounds.width > 0, bounds.height > 0, strip.contains(bounds),
                try await exactHit(item, bounds: bounds, context: context) else { throw Unavailable(stage: "target.not-positive-visible", code: 0) }
            let parent = try await element(read(item, kAXParentAttribute, stage: "target.parent", context: context), stage: "target.parent")
            let role = try await read(parent, kAXRoleAttribute, stage: "parent.role", context: context)
            guard role as? String == kAXMenuBarRole as String else { throw Unavailable(stage: "parent.not-menu-bar", code: 0) }
            let parentGeneration = try generation(pid(parent))
            let all = try await children(parent, stage: "parent.children", context: context)
            logger.notice("Visibility proof target=\(bundle, privacy: .public) phase=baseline source_pid=\(source.pid) parent_pid=\(parentGeneration.pid) source_children=\(items.count) parent_children=\(all.count) positive_hit=true direct_parent_contains_target=\(all.contains { CFEqual($0, item) })")
            // Optional standard attributes are not fabricated when unsupported.
            let visible = try await children(parent, visible: true, stage: "parent.visible-children", context: context)
            guard all.contains(where: { CFEqual($0, item) }), visible.contains(where: { CFEqual($0, item) }),
                SystemAppVisibilityModel.sameIdentitySet(visible, visible.filter { node in all.contains { CFEqual(node, $0) } }, equals: CFEqual) else { throw Unavailable(stage: "parent.positive-link", code: 0) }
            targets.append(Target(element: item, parent: Parent(element: parent, generation: parentGeneration, children: all, visible: visible), frame: bounds))
            logger.notice("Visibility proof target=\(bundle, privacy: .public) source_pid=\(source.pid) parent_pid=\(parentGeneration.pid) positive_hit=true positive_parent_link=true children=\(all.count) visible=\(visible.count)")
        }
        guard try self.source(bundle) == source, display == Bridging.getActiveMenuBarDisplayID(), CGDisplayBounds(display) == displayBounds else { throw Unavailable(stage: "baseline.generation-changed", code: 0) }
        return Baseline(bundle: bundle, source: source, bar: bar, sourceChildren: items, targets: targets, display: display, displayBounds: displayBounds)
    }

    func hidden(_ baseline: Baseline) async -> Bool {
        let context = NativeMenuBarScanContext(purpose: "visibility-proof-hidden", budget: 3)
        var consecutive = 0
        do {
            for _ in 0..<4 {
                try await Task.sleep(for: .milliseconds(200))
                try context.check()
                guard try source(baseline.bundle) == baseline.source,
                    baseline.display == Bridging.getActiveMenuBarDisplayID(),
                    CGDisplayBounds(baseline.display) == baseline.displayBounds else { throw Unavailable(stage: "post.generation-changed", code: 0) }
                let app = AXUIElementCreateApplication(baseline.source.pid)
                let bar = try await element(read(app, kAXExtrasMenuBarAttribute, stage: "post.extras", context: context), stage: "post.extras")
                let items = try await children(bar, stage: "post.source-children", context: context)
                guard CFEqual(bar, baseline.bar), SystemAppVisibilityModel.sameIdentitySet(items, baseline.sourceChildren, equals: CFEqual) else { throw Unavailable(stage: "post.source-rebuilt", code: 0) }
                var excluded = true
                for target in baseline.targets {
                    let parent = try await element(read(target.element, kAXParentAttribute, stage: "post.parent", context: context), stage: "post.parent")
                    guard CFEqual(parent, target.parent.element), try generation(pid(parent)) == target.parent.generation,
                        try await frame(target.element, context: context) == target.frame else { throw Unavailable(stage: "post.parent-or-frame-changed", code: 0) }
                    let all = try await children(parent, stage: "post.parent-children", context: context)
                    let visible = try await children(parent, visible: true, stage: "post.visible-children", context: context)
                    let proven = SystemAppVisibilityModel.hiddenInVisibleSubset(
                        target: target.element,
                        baselineChildren: target.parent.children,
                        baselineVisible: target.parent.visible,
                        currentChildren: all,
                        currentVisible: visible,
                        equals: CFEqual
                    )
                    logger.notice("Visibility proof target=\(baseline.bundle, privacy: .public) phase=post retained_children=\(all.count) visible=\(visible.count) excluded_with_stable_identity=\(proven)")
                    excluded = proven && excluded
                }
                let parentsCurrent = try baseline.targets.allSatisfy { try generation(pid($0.parent.element)) == $0.parent.generation }
                guard try source(baseline.bundle) == baseline.source, parentsCurrent,
                    baseline.display == Bridging.getActiveMenuBarDisplayID(), CGDisplayBounds(baseline.display) == baseline.displayBounds else { throw Unavailable(stage: "post.late-generation-changed", code: 0) }
                consecutive = excluded ? consecutive + 1 : 0
                if consecutive >= 2 {
                    logger.notice("Visibility proof target=\(baseline.bundle, privacy: .public) status=hidden-confirmed consecutive=\(consecutive) current_menu_bar_only=true")
                    return true
                }
            }
            throw Unavailable(stage: "post.no-stable-visible-exclusion", code: 0)
        } catch {
            log(error, bundle: baseline.bundle, phase: "post")
            return false
        }
    }

    private func log(_ error: any Error, bundle: String, phase: String) {
        let failure = error as? Unavailable
        let stage = failure?.stage ?? String(describing: error)
        let code = failure?.code ?? 0
        logger.notice("Visibility proof target=\(bundle, privacy: .public) phase=\(phase, privacy: .public) status=unavailable stage=\(stage, privacy: .public) ax_code=\(code); no physical absence inferred")
    }
}

extension SystemAppVisibilityVerifier {
    struct HostBaseline {
        let host: Generation
        let attribute: String
        let bar: AXUIElement
        let children: [AXUIElement]
        let visible: [AXUIElement]
        let boundTargets: [AXUIElement]
        let sources: [Baseline]
    }

    /// Only publicly provable leaves participate in host object uniqueness.
    /// A failed read, optional absence or composite structure is unknown.
    private func isLeaf(_ element: AXUIElement, context: NativeMenuBarScanContext) async throws -> Bool {
        let names: [String] = try await context.readOnMain { timeout in
            let configured = AXUIElementSetMessagingTimeout(element, timeout)
            guard configured == .success else { throw Unavailable(stage: "host.leaf-timeout", code: configured.rawValue) }
            defer { AXUIElementSetMessagingTimeout(element, 0.25) }
            var result: CFArray?
            let error = AXUIElementCopyAttributeNames(element, &result)
            guard error == .success, let names = result as? [String], names.count <= 128 else { throw Unavailable(stage: "host.leaf-attribute-names", code: error.rawValue) }
            return names
        }
        try Task.checkCancellation()
        if !names.contains(kAXChildrenAttribute) { return true }
        return try await children(element, stage: "host.leaf-children", context: context).isEmpty
    }

    func captureHost(bundles: [String], sources: [String: Baseline]) async -> HostBaseline? {
        let context = NativeMenuBarScanContext(purpose: "visibility-proof-host-baseline", budget: 1.5)
        do {
            guard !bundles.isEmpty, Set(bundles) == Set(sources.keys) else { throw Unavailable(stage: "host.source-baseline-incomplete", code: 0) }
            let hosts = NSWorkspace.shared.runningApplications.filter {
                $0.executableURL?.lastPathComponent == "MenuBarAgent" && $0.executableURL?.path.hasPrefix("/System/Library/") == true
            }
            guard hosts.count == 1, let hostApp = hosts.first else { throw Unavailable(stage: "host.process-ambiguous", code: 0) }
            let host = try generation(hostApp.processIdentifier)
            let app = AXUIElementCreateApplication(host.pid)
            let sourceBaselines = bundles.compactMap { sources[$0] }
            let originals = sourceBaselines.flatMap { $0.targets.map(\.element) }
            var seenBars = [AXUIElement]()
            for attribute in [kAXExtrasMenuBarAttribute, kAXMenuBarAttribute] {
                do {
                    let bar = try await element(read(app, attribute, stage: "host." + attribute, context: context), stage: "host.bar")
                    guard !seenBars.contains(where: { CFEqual($0, bar) }) else { continue }
                    seenBars.append(bar)
                    let barRole = try await read(bar, kAXRoleAttribute, stage: "host.bar-role", context: context)
                    guard barRole as? String == kAXMenuBarRole else { throw Unavailable(stage: "host.not-menu-bar", code: 0) }
                    let all = try await children(bar, stage: "host.children", context: context)
                    var visible: [AXUIElement]?
                    do { visible = try await children(bar, visible: true, stage: "host.visible-children", context: context) } catch {
                        log(error, bundle: "<selected-batch>", phase: "host-baseline")
                    }
                    let directMatches = originals.filter { source in all.contains { CFEqual(source, $0) } }.count
                    logger.notice("Visibility proof phase=host-baseline host_pid=\(host.pid) attribute=\(attribute, privacy: .public) children=\(all.count) visible_supported=\(visible != nil) visible=\(visible?.count ?? -1) source_objects=\(originals.count) directly_bound=\(directMatches); strict-leaf association only")
                    var firstOrder = true
                    var matches = [[AXUIElement]](repeating: [], count: originals.count)
                    for child in all {
                        let role = try await read(child, kAXRoleAttribute, stage: "host.child-role", context: context)
                        guard [kAXMenuBarItemRole, kAXButtonRole].contains(role as? String ?? "") else { firstOrder = false; continue }
                        guard try await isLeaf(child, context: context) else { throw Unavailable(stage: "host.nonleaf-first-order-candidate", code: 0) }
                        let bound = originals.indices.filter { CFEqual(child, originals[$0]) }
                        if bound.count > 1 { firstOrder = false }
                        for index in bound { matches[index].append(child) }
                    }
                    let unique = matches.filter { $0.count == 1 }.count
                    logger.notice("Visibility proof phase=host-baseline host_pid=\(host.pid) attribute=\(attribute, privacy: .public) children=\(all.count) visible_supported=\(visible != nil) visible=\(visible?.count ?? -1) source_objects=\(originals.count) uniquely_bound=\(unique) complete_first_order=\(firstOrder); no name/frame association")
                    guard firstOrder, !all.isEmpty, unique == originals.count, let visible else { continue }
                    let targets = matches.compactMap(\.first)
                    guard SystemAppVisibilityModel.sameIdentitySet(targets, targets, equals: CFEqual),
                        targets.allSatisfy({ target in visible.contains { CFEqual(target, $0) } }),
                        SystemAppVisibilityModel.sameIdentitySet(visible, visible.filter { node in all.contains { CFEqual(node, $0) } }, equals: CFEqual) else { continue }
                    guard try generation(host.pid) == host else { throw Unavailable(stage: "host.baseline-generation-changed", code: 0) }
                    return HostBaseline(host: host, attribute: attribute, bar: bar, children: all, visible: visible, boundTargets: targets, sources: sourceBaselines)
                } catch { log(error, bundle: "<selected-batch>", phase: "host-baseline") }
            }
            throw Unavailable(stage: "host.no-complete-unique-visible-source-link", code: 0)
        } catch {
            log(error, bundle: "<selected-batch>", phase: "host-baseline")
            return nil
        }
    }

    private func hostGenerationsCurrent(_ baseline: HostBaseline) throws -> Bool {
        guard try generation(baseline.host.pid) == baseline.host else { return false }
        return try baseline.sources.allSatisfy {
            try source($0.bundle) == $0.source && Bridging.getActiveMenuBarDisplayID() == $0.display && CGDisplayBounds($0.display) == $0.displayBounds
        }
    }

    func hiddenInHost(_ baseline: HostBaseline) async -> Bool {
        let context = NativeMenuBarScanContext(purpose: "visibility-proof-host-post", budget: 3)
        var consecutive = 0
        do {
            for _ in 0..<4 {
                try await Task.sleep(for: .milliseconds(200))
                guard try hostGenerationsCurrent(baseline) else { throw Unavailable(stage: "host.post-generation-changed", code: 0) }
                for source in baseline.sources {
                    let app = AXUIElementCreateApplication(source.source.pid)
                    let bar = try await element(read(app, kAXExtrasMenuBarAttribute, stage: "host.post-source-extras", context: context), stage: "host.post-source-extras")
                    let all = try await children(bar, stage: "host.post-source-children", context: context)
                    guard CFEqual(bar, source.bar), SystemAppVisibilityModel.sameIdentitySet(all, source.sourceChildren, equals: CFEqual) else { throw Unavailable(stage: "host.post-source-rebuilt", code: 0) }
                }
                let app = AXUIElementCreateApplication(baseline.host.pid)
                let bar = try await element(read(app, baseline.attribute, stage: "host.post-bar", context: context), stage: "host.post-bar")
                guard CFEqual(bar, baseline.bar) else { throw Unavailable(stage: "host.post-parent-rebuilt", code: 0) }
                let all = try await children(bar, stage: "host.post-children", context: context)
                let visible = try await children(bar, visible: true, stage: "host.post-visible-children", context: context)
                for child in all {
                    guard try await isLeaf(child, context: context) else { throw Unavailable(stage: "host.post-nonleaf-candidate", code: 0) }
                }
                let proven = SystemAppVisibilityModel.hiddenInHostSubset(
                    targets: baseline.boundTargets,
                    baselineChildren: baseline.children,
                    baselineVisible: baseline.visible,
                    currentChildren: all,
                    currentVisible: visible,
                    equals: CFEqual
                )
                guard try hostGenerationsCurrent(baseline) else { throw Unavailable(stage: "host.post-late-generation-changed", code: 0) }
                logger.notice("Visibility proof phase=host-post host_pid=\(baseline.host.pid) children=\(all.count) visible=\(visible.count) bound_targets=\(baseline.boundTargets.count) stable_exclusion=\(proven)")
                consecutive = proven ? consecutive + 1 : 0
                if consecutive >= 2 {
                    logger.notice("Visibility proof phase=host-post status=hidden-confirmed consecutive=\(consecutive) current_menu_bar_only=true")
                    return true
                }
            }
            throw Unavailable(stage: "host.no-stable-visible-exclusion", code: 0)
        } catch {
            log(error, bundle: "<selected-batch>", phase: "host-post")
            return false
        }
    }
}
