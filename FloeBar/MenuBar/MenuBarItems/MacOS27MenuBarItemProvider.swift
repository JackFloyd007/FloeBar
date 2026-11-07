//
//  MacOS27MenuBarItemProvider.swift
//  Ice
//
//  macOS 27 compatibility implementation derived from the GPLv3 Thaw project.
//

@preconcurrency import AXSwift
import Cocoa
import OSLog

/// Enumerates macOS 27 menu bar items through Accessibility.
///
/// macOS 27 no longer exposes each status item as an independent WindowServer
/// window. Every application still publishes its status items below
/// `AXExtrasMenuBar`, which also gives us direct process attribution.
@available(macOS 27.0, *)
enum MacOS27MenuBarItemProvider {
    private static let logger = Logger(category: "MacOS27MenuBarItemProvider")
    private static let maxItemHeight: CGFloat = 40
    /// Keep complete `AXExtrasMenuBar` walks from interleaving. Each owner's
    /// actual AX reads are also batched on the main thread below because
    /// HIServices' serializer is not safe when Ice answers an incoming AX
    /// hierarchy request at the same time as a background outgoing read.
    private static let scanGate = NativeMenuBarScanGate()
    // Accessed only inside main-thread AX batches, including targeted rereads.
    private static var runtimeIdentities = MacOS27RuntimeItemRegistry<AXUIElement>()

    static func displayID(containing frame: CGRect) -> CGDirectDisplayID? {
        AXHelpers.performOnMain {
            let matches = NSScreen.screens.filter { screen in
                let bounds = CGDisplayBounds(screen.displayID)
                return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: maxItemHeight).contains(frame)
            }
            return matches.count == 1 ? matches.first?.displayID : nil
        }
    }

    /// A single main-thread batch for our own controls only. Do not take the
    /// background scan lock here: its owner may be waiting for the main thread.
    @MainActor
    static func ownMenuBarItems(on displayID: CGDirectDisplayID) -> [MenuBarItem] {
        let frames = NSScreen.screens.map { screen in
            let display = CGDisplayBounds(screen.displayID)
            return CGRect(x: display.minX, y: display.minY, width: display.width, height: maxItemHeight)
        }
        let items = rawItems(
            from: .current,
            displayBounds: CGDisplayBounds(displayID),
            menuBarFrames: frames,
            includeSupplementaryMetadata: false
        ).items
        for identifier in [ControlItem.Identifier.visible.rawValue, MenuBarItemTag.nativeBoundary(for: .hidden).title] {
            let matches = items.filter { $0.identityTitle == identifier }
            if let first = matches.first, matches.contains(where: { $0.bounds != first.bounds }) {
                return [] // Distinct hosted variants are not a settled pair.
            }
        }
        return assemble(items, displayBounds: CGDisplayBounds(displayID))
    }

    static func menuBarItems(
        on display: CGDirectDisplayID? = nil,
        option _: MenuBarItem.ListOption,
        context: NativeMenuBarScanContext? = nil,
        requiring namespaces: Set<MenuBarItemTag.Namespace> = []
    ) async -> NativeMenuBarScanResult<[MenuBarItem]> {
        let context = context ?? NativeMenuBarScanContext(purpose: "discovery")
        let selection = await MainActor.run {
            (display ?? Bridging.getActiveMenuBarDisplayID(), NSWorkspace.shared.runningApplications)
        }
        guard let displayID = selection.0 else { return .init(value: [], status: .incomplete) }
        let required = Set(selection.1.filter { namespaces.contains(namespace(for: $0)) }.map(\.processIdentifier))
        let raw = await scan(
            applications: selection.1,
            displayBounds: CGDisplayBounds(displayID),
            requiring: required,
            supplementary: true,
            context: context
        )
        return .init(value: raw.completeValue.map { assemble($0, displayBounds: CGDisplayBounds(displayID)) } ?? [], status: raw.status)
    }

    /// Targeted order/capture reads require every selected live owner to answer.
    /// A full discovery may skip unrelated applications with no AX server, but
    /// it cannot silently skip a known owner required by the caller.
    static func menuBarItems(
        sourcePIDs: Set<pid_t>,
        namespaces: Set<MenuBarItemTag.Namespace> = [],
        on displayID: CGDirectDisplayID,
        context: NativeMenuBarScanContext? = nil
    ) async -> NativeMenuBarScanResult<[MenuBarItem]> {
        let context = context ?? NativeMenuBarScanContext(purpose: "targeted", budget: 1.5)
        let applications = await MainActor.run {
            NSWorkspace.shared.runningApplications.filter {
                sourcePIDs.contains($0.processIdentifier) || namespaces.contains(namespace(for: $0))
            }
        }
        let raw = await scan(
            applications: applications,
            displayBounds: CGDisplayBounds(displayID),
            requiring: Set(applications.map(\.processIdentifier)),
            supplementary: false,
            context: context
        )
        return .init(value: raw.completeValue.map { assemble($0, displayBounds: CGDisplayBounds(displayID)) } ?? [], status: raw.status)
    }

    /// Confirms that an AX frame still belongs to the item which published it.
    /// Concealed hosted scenes can retain an on-bar frame that is actually
    /// occupied by MenuBarAgent's overflow button.
    static func nativeHitMatches(_ item: MenuBarItem) -> Bool {
        if item.tag.namespace == .ice, item.tag.isControlItem {
            return nativeBoundaryHitMatches(item)
        }
        return AXHelpers.performOnMain {
            runtimeIdentities.removeUnavailableOwners(
                Set(NSWorkspace.shared.runningApplications.map(runtimeOwner))
            )
            guard let token = item.nativeIdentityToken,
                let element = runtimeIdentities.element(for: token) else { return false }
            return NativeMenuBarInteraction.matchesHit(
                expected: UIElement(element),
                hit: AXHelpers.element(at: item.bounds.center),
                expectedPID: item.ownerPID,
                expectedFrame: item.bounds,
                parent: AXHelpers.parent,
                pid: AXHelpers.pid,
                frame: AXHelpers.frame,
                equals: { CFEqual($0.element, $1.element) }
            )
        }
    }

    /// Hosted buttons may hit a child without an identifier. Accept only a
    /// bounded ancestor chain with our exact boundary identifier and frame.
    static func nativeBoundaryHitMatches(_ item: MenuBarItem) -> Bool {
        AXHelpers.performOnMain {
            guard item.tag.namespace == .ice, item.tag.isControlItem else { return false }
            var candidate = AXHelpers.element(at: item.bounds.center)
            for _ in 0 ..< 4 {
                guard let element = candidate,
                    AXHelpers.pid(for: element) == item.ownerPID else { return false }
                if AXHelpers.frame(for: element) == item.bounds, MacOS27NativeBoundary.matchesOwnedHit(
                    pid: AXHelpers.pid(for: element),
                    expectedPID: item.ownerPID,
                    identifier: AXHelpers.identifier(for: element),
                    expectedIdentifier: item.tag.title,
                    frame: AXHelpers.frame(for: element),
                    point: item.bounds.center
                ) {
                    return true
                }
                candidate = AXHelpers.parent(for: element)
            }
            return false
        }
    }

    /// One cancellable deadline also governs absence rereads. No synchronous
    /// MainActor owner walk can bypass the normal scan budget.
    static func confirmedAbsentIdentifiers(
        for items: [MenuBarItem], context: NativeMenuBarScanContext
    ) async -> NativeMenuBarScanResult<Set<String>> {
        let namespaces = Set(items.map(\.tag.namespace))
        let applications = await MainActor.run {
            NSWorkspace.shared.runningApplications.filter { namespaces.contains(namespace(for: $0)) }
        }
        let raw = await scan(
            applications: applications,
            displayBounds: nil,
            requiring: Set(applications.map(\.processIdentifier)),
            supplementary: false,
            offscreen: true,
            context: context
        )
        guard let confirmed = raw.completeValue else { return .init(value: [], status: raw.status) }
        let observedNamespaces = Set(applications.map(namespace))
        let identities = Set(confirmed.map { "\($0.namespace):\($0.identityTitle)" })
        let absent = Set(items.filter {
            observedNamespaces.contains($0.tag.namespace) && !identities.contains("\($0.tag.namespace):\($0.tag.title)")
        }.map { $0.tag.persistentIdentifier })
        return .init(value: absent, status: .complete)
    }

    private static func scan(
        applications: [NSRunningApplication],
        displayBounds: CGRect?,
        requiring required: Set<pid_t>,
        supplementary: Bool,
        offscreen: Bool = false,
        context: NativeMenuBarScanContext
    ) async -> NativeMenuBarScanResult<[RawItem]> {
        // The timer releases an expired queued waiter without waiting for the
        // active owner. Active AX calls are never forcibly interrupted.
        let queuedAt = context.timestamp()
        let expiry = Task {
            do { try await Task.sleep(for: .seconds(context.remaining)) } catch { return }
            await scanGate.discardWaiter(context.id)
        }
        defer { expiry.cancel() }
        return await withTaskCancellationHandler {
            guard !Task.isCancelled, await scanGate.acquire(context) else {
                let status = context.termination ?? .cancelled
                logger.notice("AX scan id=\(context.id.uuidString, privacy: .public) purpose=\(context.purpose, privacy: .public) status=\(status.rawValue, privacy: .public) total_ms=\(context.elapsed * 1000, privacy: .public) queued_cancel=true")
                return .init(value: [], status: status)
            }
            let queued = context.timestamp() - queuedAt
            var raw = [RawItem]()
            var confirmed = Set<Int32>()
            var status = NativeMenuBarScanStatus.complete
            do {
                try context.check()
                let frames = await MainActor.run {
                    runtimeIdentities.removeUnavailableOwners(Set(NSWorkspace.shared.runningApplications.map(runtimeOwner)))
                    return NSScreen.screens.map { screen in
                        let bounds = CGDisplayBounds(screen.displayID)
                        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: maxItemHeight)
                    }
                }
                for app in applications {
                    try context.check()
                    let owner = try await scannedItems(
                        from: app,
                        displayBounds: displayBounds,
                        frames: frames,
                        supplementary: supplementary,
                        offscreen: offscreen,
                        context: context
                    )
                    if owner.isComplete {
                        raw.append(contentsOf: owner.items)
                        confirmed.insert(app.processIdentifier)
                    } else if required.contains(app.processIdentifier) || owner.hasExtrasBar, context.reserveOwnerDiagnostic() {
                        let error = owner.failureError.map { String($0.rawValue) } ?? "none"
                        logger.notice("AX scan owner incomplete id=\(context.id.uuidString, privacy: .public) owner_pid=\(app.processIdentifier, privacy: .public) required=\(required.contains(app.processIdentifier), privacy: .public) stage=\(owner.failureStage ?? "unknown", privacy: .public) ax_error=\(error, privacy: .public) child=\(owner.failureChild ?? -1, privacy: .public) field=\(owner.failureField ?? "unknown", privacy: .public) role=\(owner.failureRole ?? "unknown", privacy: .public)")
                    }
                }
                try context.check()
            } catch let stopped as NativeMenuBarScanStatus { status = stopped } catch { status = .incomplete }
            await scanGate.release(context.id)
            status = NativeMenuBarScanCompletion.status(required: required, confirmed: confirmed, terminal: context.termination ?? status)
            let metrics = context.metrics
            let cancelDrain = metrics.cancelDrain.map { $0 * 1000 } ?? -1
            logger.notice("AX scan id=\(context.id.uuidString, privacy: .public) purpose=\(context.purpose, privacy: .public) status=\(status.rawValue, privacy: .public) total_ms=\(context.elapsed * 1000, privacy: .public) queue_ms=\(queued * 1000, privacy: .public) max_main_read_ms=\(metrics.longestRead * 1000, privacy: .public) calls=\(metrics.calls, privacy: .public) cancel_drain_ms=\(cancelDrain, privacy: .public)")
            return .init(value: status == .complete ? raw : [], status: status)
        } onCancel: {
            context.cancel()
            Task { await scanGate.discardWaiter(context.id) }
        }
    }

    private struct ReadResponse: @unchecked Sendable {
        let error: AXError
        let value: CFTypeRef?
    }

    /// Exactly one remote call in a main-queue turn, with pre/post checks.
    private static func read(
        _ element: AXUIElement, attributes: [String], context: NativeMenuBarScanContext
    ) async throws -> ReadResponse {
        let response = try await context.readOnMain { timeout in
            guard AXUIElementSetMessagingTimeout(element, timeout) == .success else { throw NativeMenuBarScanStatus.incomplete }
            defer { AXUIElementSetMessagingTimeout(element, 0.25) }
            if attributes.isEmpty {
                var values: CFArray?
                let error = AXUIElementCopyAttributeNames(element, &values)
                return ReadResponse(error: error, value: values)
            } else if attributes.count == 1 {
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(element, attributes[0] as CFString, &value)
                return ReadResponse(error: error, value: value)
            } else {
                var values: CFArray?
                let error = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &values)
                return ReadResponse(error: error, value: values)
            }
        }
        if response.error == .notImplemented, attributes.count > 1 {
            var values = [CFTypeRef]()
            for name in attributes {
                let single = try await read(element, attributes: [name], context: context)
                if single.error == .success, let value = single.value {
                    values.append(value)
                } else {
                    var error = single.error == .success ? AXError.failure : single.error
                    guard let value = AXValueCreate(.axError, &error) else { return ReadResponse(error: .failure, value: nil) }
                    values.append(value)
                }
            }
            return ReadResponse(error: .success, value: values as CFArray)
        }
        return response
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func scannedItems(
        from app: NSRunningApplication,
        displayBounds: CGRect?,
        frames: [CGRect],
        supplementary: Bool,
        offscreen: Bool,
        context: NativeMenuBarScanContext
    ) async throws -> RawSnapshot {
        guard !app.isTerminated else { return RawSnapshot() }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let extras = try await read(application, attributes: [kAXExtrasMenuBarAttribute], context: context)
        var attributeNames: [String]?
        if extras.error == .notImplemented {
            let names = try await read(application, attributes: [], context: context)
            if names.error == .success { attributeNames = names.value as? [String] }
        }
        switch NativeMenuBarScanAttributes.extras(error: extras.error, value: extras.value, attributeNames: attributeNames) {
        case .empty: return RawSnapshot()
        case .incomplete:
            return RawSnapshot(isComplete: false, failureStage: "extras", failureError: extras.error == .success ? nil : extras.error, failureField: "AXExtrasMenuBar")
        case .bar: break
        }
        guard let bar = element(extras.value) else { return RawSnapshot(isComplete: false, failureStage: "extras-type") }
        let childrenResult = try await read(bar, attributes: [kAXChildrenAttribute], context: context)
        guard let children = NativeMenuBarScanAttributes.children(error: childrenResult.error, value: childrenResult.value) else {
            return RawSnapshot(isComplete: false, hasExtrasBar: true, failureStage: "children", failureError: childrenResult.error == .success ? nil : childrenResult.error, failureField: "AXChildren")
        }
        let itemNamespace = namespace(for: app)
        var result = RawSnapshot(hasExtrasBar: true)
        var fallbackIndex = 0
        for (childIndex, child) in children.enumerated() {
            try context.check()
            // Read the original AXFrame API first. Do not request optional
            // position/size from a frame-only child and poison a valid result.
            var names = ["AXFrame", kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXRoleAttribute, kAXHelpAttribute]
            if supplementary && context.includesSupplementaryMetadata { names += [kAXValueAttribute] }
            let response = try await read(child, attributes: names, context: context)
            guard var values = NativeMenuBarScanAttributes.fields(error: response.error, value: response.value, names: names) else {
                let failure = NativeMenuBarScanAttributes.failedCoreField(error: response.error, value: response.value, names: names)
                result.noteFailure(stage: "core-fields", error: failure.1, child: childIndex, field: failure.0)
                continue
            }
            if values["AXFrame"] == nil {
                let geometryNames = [kAXPositionAttribute, kAXSizeAttribute]
                let geometry = try await read(child, attributes: geometryNames, context: context)
                guard let fallback = NativeMenuBarScanAttributes.fields(error: geometry.error, value: geometry.value, names: geometryNames) else {
                    let failure = NativeMenuBarScanAttributes.failedCoreField(error: geometry.error, value: geometry.value, names: geometryNames)
                    result.noteFailure(stage: "geometry-read", error: failure.1, child: childIndex, field: failure.0)
                    continue
                }
                values.merge(fallback) { _, refreshed in refreshed }
            }
            guard let bounds = NativeMenuBarScanAttributes.frame(values) else {
                let field = values[kAXPositionAttribute] == nil ? kAXPositionAttribute : (values[kAXSizeAttribute] == nil ? kAXSizeAttribute : "geometry-type")
                let role = values[kAXRoleAttribute] as? String ?? "unknown"
                let safeRole = [kAXMenuBarItemRole, kAXButtonRole, kAXMenuBarRole, kAXGroupRole, kAXImageRole].contains(role) ? role : "other"
                result.noteFailure(stage: "geometry", error: nil, child: childIndex, field: field, role: safeRole)
                continue
            }
            guard MacOS27ItemSnapshotGeometry.includes(frame: bounds, menuBarFrames: frames, maxItemHeight: maxItemHeight, includingOffscreenItems: offscreen),
                displayBounds == nil || displayBounds?.contains(bounds.center) == true else { continue }
            var identifier = nonEmpty(values[kAXIdentifierAttribute] as? String)
            var description = nonEmpty(values[kAXDescriptionAttribute] as? String)
            var help = nonEmpty(values[kAXHelpAttribute] as? String)
            var value = nonEmpty(values[kAXValueAttribute] as? String)
            if identifier == nil {
                let descendants = try await read(child, attributes: [kAXChildrenAttribute], context: context)
                if descendants.error == .success, let elements = descendants.value as? [AXUIElement] {
                    for descendant in elements {
                        var detailNames = [kAXIdentifierAttribute, kAXDescriptionAttribute]
                        if supplementary && context.includesSupplementaryMetadata { detailNames += [kAXHelpAttribute, kAXValueAttribute] }
                        let response = try await read(descendant, attributes: detailNames, context: context)
                        guard let details = NativeMenuBarScanAttributes.fields(error: response.error, value: response.value, names: detailNames) else {
                            let failure = NativeMenuBarScanAttributes.failedCoreField(error: response.error, value: response.value, names: detailNames)
                            result.noteFailure(stage: "descendant-fields", error: failure.1, child: childIndex, field: failure.0)
                            continue
                        }
                        identifier = identifier ?? nonEmpty(details[kAXIdentifierAttribute] as? String)
                        description = description ?? nonEmpty(details[kAXDescriptionAttribute] as? String)
                        help = help ?? nonEmpty(details[kAXHelpAttribute] as? String)
                        value = value ?? nonEmpty(details[kAXValueAttribute] as? String)
                    }
                } else if descendants.error != .noValue && descendants.error != .attributeUnsupported {
                    result.noteFailure(stage: "descendants", error: descendants.error, child: childIndex, field: "AXChildren")
                }
            }
            try context.check()
            let title = nonEmpty(values[kAXTitleAttribute] as? String)
            let originalDisplayTitle = title ?? description ?? identifier ?? "Item-\(fallbackIndex)"
            let isThirdParty = app.bundleIdentifier != Constants.bundleIdentifier && app.bundleIdentifier?.hasPrefix("com.apple.") != true
            let displayTitle = isThirdParty
                ? MenuBarItemDisplayLabel.semantic(app: app.localizedName ?? app.bundleIdentifier ?? "", description: description, title: title, help: help, identifier: identifier) ?? originalDisplayTitle
                : originalDisplayTitle
            if title == nil && description == nil && identifier == nil { fallbackIndex += 1 }
            let identity = await MainActor.run { () -> (String, pid_t) in
                let token = runtimeIdentities.identity(for: child, owner: runtimeOwner(app), now: ProcessInfo.processInfo.systemUptime, equals: { CFEqual($0, $1) })
                var pid = app.processIdentifier
                _ = AXUIElementGetPid(child, &pid)
                return (token, pid)
            }
            let identityTitle: String
            if itemNamespace == .textInputMenuAgent { identityTitle = "Item-\(childIndex)" } else if identifier == nil && app.bundleIdentifier != Constants.bundleIdentifier && app.bundleIdentifier?.hasPrefix("com.apple.") != true { identityTitle = identity.0 } else { identityTitle = identifier ?? description ?? originalDisplayTitle }
            result.items.append(
                RawItem(
                    namespace: itemNamespace,
                    identityTitle: identityTitle,
                    displayTitle: displayTitle,
                    nativeIdentityToken: identity.0,
                    bounds: bounds,
                    ownerPID: identity.1,
                    accessibilityHelp: help,
                    accessibilityValue: value,
                    isNativeOverflowControl: itemNamespace == .controlCenter && NativeOverflowLabels.system.expanded(
                        label: description ?? title,
                        isAgent: identity.1 == app.processIdentifier,
                        isButton: values[kAXRoleAttribute] as? String == kAXButtonRole
                    ) != nil
                )
            )
        }
        return result
    }

    private struct RawSnapshot {
        var items = [RawItem]()
        var isComplete = true
        var hasExtrasBar = false
        var failureStage: String?
        var failureError: AXError?
        var failureChild: Int?
        var failureField: String?
        var failureRole: String?

        mutating func noteFailure(stage: String, error: AXError?, child: Int, field: String, role: String? = nil) {
            isComplete = false
            guard failureStage == nil else { return }
            failureStage = stage
            failureError = error
            failureChild = child
            failureField = field
            failureRole = role
        }
    }

    private static func rawItems(
        from runningApp: NSRunningApplication,
        displayBounds: CGRect?,
        menuBarFrames: [CGRect],
        includeSupplementaryMetadata: Bool,
        includingOffscreenItems: Bool = false
    ) -> RawSnapshot {
        precondition(Thread.isMainThread)
        guard let application = AXHelpers.application(for: runningApp) else {
            return RawSnapshot(isComplete: false)
        }
        let children: [UIElement]
        do {
            guard let extras: UIElement = try application.attribute(.extrasMenuBar) else {
                return RawSnapshot() // A successful read can report no status items.
            }
            children = try extras.arrayAttribute(.children) ?? []
        } catch let error as AXError where error == .notImplemented {
            // Some hosts remove AXExtrasMenuBar along with their final item.
            // Only a successful attribute-list read that omits it establishes
            // absence; a timeout/unresponsive owner is never treated as empty.
            if let attributes = try? application.attributes(), !attributes.contains(.extrasMenuBar) {
                return RawSnapshot()
            }
            return RawSnapshot(isComplete: false)
        } catch {
            return RawSnapshot(isComplete: false)
        }

        let namespace = namespace(for: runningApp)
        var fallbackIndex = 0
        var result = RawSnapshot()
        for (childIndex, child) in children.enumerated() {
            guard let frame = AXHelpers.frame(for: child) else {
                result.isComplete = false
                continue
            }
            guard MacOS27ItemSnapshotGeometry.includes(
                frame: frame,
                menuBarFrames: menuBarFrames,
                maxItemHeight: maxItemHeight,
                includingOffscreenItems: includingOffscreenItems
            ) else {
                continue
            }

            if let displayBounds, !displayBounds.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                continue
            }

            var identityDescendants: [UIElement]?
            let identifier: String?
            do {
                if let ownIdentifier = nonEmpty(try child.attribute(.identifier)) {
                    identifier = ownIdentifier
                } else {
                    let descendants: [UIElement] = try child.arrayAttribute(.children) ?? []
                    identityDescendants = descendants
                    var descendantIdentifier: String?
                    for descendant in descendants {
                        if let value = nonEmpty(try descendant.attribute(.identifier)) {
                            descendantIdentifier = value
                            break
                        }
                    }
                    identifier = descendantIdentifier
                }
            } catch {
                // A failed metadata read is not evidence that the element
                // lacks an identifier. Never mint a fallback identity for it.
                result.isComplete = false
                continue
            }
            lazy var descendants = identityDescendants ?? AXHelpers.children(for: child)
            let accessibilityDescription = nonEmpty(AXHelpers.description(for: child))
                ?? descendants.compactMap { nonEmpty(AXHelpers.description(for: $0)) }.first
            let accessibilityHelp = includeSupplementaryMetadata
                ? nonEmpty(AXHelpers.help(for: child))
                    ?? descendants.compactMap { nonEmpty(AXHelpers.help(for: $0)) }.first
                : nil
            let accessibilityValue = includeSupplementaryMetadata
                ? nonEmpty(AXHelpers.value(for: child))
                    ?? descendants.compactMap { nonEmpty(AXHelpers.value(for: $0)) }.first
                : nil
            let accessibilityTitle = nonEmpty(AXHelpers.title(for: child))
            let fallbackTitle = "Item-\(fallbackIndex)"
            let displayTitle = accessibilityTitle ?? accessibilityDescription ?? identifier ?? fallbackTitle
            if accessibilityTitle == nil, accessibilityDescription == nil, identifier == nil {
                fallbackIndex += 1
            }

            let nativeIdentityToken = runtimeIdentities.identity(
                for: child.element,
                owner: runtimeOwner(runningApp),
                now: ProcessInfo.processInfo.systemUptime,
                equals: { CFEqual($0, $1) }
            )

            // TextInputMenuAgent exposes the currently selected input source
            // (for example "ABC" or "简体拼音") as its AX description. That
            // label is presentation, not identity.
            let identityTitle = if namespace == .textInputMenuAgent {
                "Item-\(childIndex)"
            } else if identifier == nil,
                runningApp.bundleIdentifier != Constants.bundleIdentifier,
                runningApp.bundleIdentifier?.hasPrefix("com.apple.") != true {
                nativeIdentityToken
            } else {
                identifier ?? accessibilityDescription ?? displayTitle
            }
            let ownerPID = AXHelpers.pid(for: child) ?? runningApp.processIdentifier
            result.items.append(
                RawItem(
                    namespace: namespace,
                    identityTitle: identityTitle,
                    displayTitle: displayTitle,
                    nativeIdentityToken: nativeIdentityToken,
                    bounds: frame,
                    ownerPID: ownerPID,
                    accessibilityHelp: accessibilityHelp,
                    accessibilityValue: accessibilityValue,
                    isNativeOverflowControl: namespace == .controlCenter &&
                        isNativeOverflowControl(child, expectedOwner: runningApp.processIdentifier)
                )
            )
        }
        return result
    }

    private struct RawItem {
        let namespace: MenuBarItemTag.Namespace
        let identityTitle: String
        let displayTitle: String
        let nativeIdentityToken: String
        let bounds: CGRect
        let ownerPID: pid_t
        let accessibilityHelp: String?
        let accessibilityValue: String?
        let isNativeOverflowControl: Bool
    }

    private static func assemble(_ rawItems: [RawItem], displayBounds: CGRect) -> [MenuBarItem] {
        let candidates = rawItems.map { item in
            NativeMenuBarSnapshot.Candidate(
                semanticIdentity: "\(item.namespace):\(item.identityTitle)",
                objectIdentity: item.nativeIdentityToken,
                frame: item.bounds,
                isOwnedControl: item.namespace == .ice &&
                    (ControlItem.Identifier(rawValue: item.identityTitle) != nil ||
                        item.identityTitle.hasPrefix("Ice.NativeBoundary."))
            )
        }
        return NativeMenuBarSnapshot.indices(in: candidates, display: displayBounds).compactMap { index in
            let rawItem = rawItems[index]
            guard !rawItem.isNativeOverflowControl,
                !isNativeOverflowPlaceholder(rawItem.identityTitle) else { return nil }
            let identity = "\(rawItem.namespace):\(rawItem.identityTitle)"
            let instanceIndex = 0
            let windowID = syntheticWindowID(identity: identity, instanceIndex: instanceIndex)
            let tag = MenuBarItemTag(
                namespace: rawItem.namespace,
                title: rawItem.identityTitle,
                instanceIndex: instanceIndex
            )
            return MenuBarItem(
                tag: tag,
                windowID: windowID,
                ownerPID: rawItem.ownerPID,
                sourcePID: rawItem.ownerPID,
                bounds: rawItem.bounds,
                title: rawItem.displayTitle,
                accessibilityHelp: rawItem.accessibilityHelp,
                accessibilityValue: rawItem.accessibilityValue,
                isOnScreen: true,
                nativeIdentityToken: rawItem.nativeIdentityToken
            )
        }
    }

    private static func namespace(for app: NSRunningApplication) -> MenuBarItemTag.Namespace {
        switch app.bundleIdentifier {
        case "com.apple.MenuBarAgent":
            // Preserve Ice's existing Control Center item identities.
            return .controlCenter
        case Constants.bundleIdentifier:
            return .ice
        case let bundleIdentifier?:
            return .string(bundleIdentifier)
        case nil:
            return .optional(app.localizedName)
        }
    }

    private static func runtimeOwner(_ app: NSRunningApplication) -> String {
        "\(app.processIdentifier):\(app.launchDate?.timeIntervalSinceReferenceDate ?? 0)"
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isNativeOverflowControl(_ element: UIElement, expectedOwner: pid_t) -> Bool {
        NativeOverflowLabels.system.expanded(
            label: AXHelpers.description(for: element) ?? AXHelpers.title(for: element),
            isAgent: AXHelpers.pid(for: element) == expectedOwner,
            isButton: AXHelpers.role(for: element) == .button
        ) != nil
    }

    private static func isNativeOverflowPlaceholder(_ title: String) -> Bool {
        let normalized = title.lowercased()
        return normalized.contains("overflow") || normalized.contains("chevron")
    }

    private static func syntheticWindowID(identity: String, instanceIndex: Int) -> CGWindowID {
        var hash: UInt32 = 0x811C_9DC5
        for byte in "\(identity):\(instanceIndex)".utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return CGWindowID(0x8000_0000 | (hash & 0x7FFF_FFFF))
    }
}
