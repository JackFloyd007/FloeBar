//
//  MenuBarItemImageCache.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

/// Cache for menu bar item images.
final class MenuBarItemImageCache: ObservableObject {
    /// A private marker used for the code-drawn monochrome status glyph used
    /// by Macs Fan Control. It is intentionally not an SF Symbol name.
    private static let macsFanControlMonochromeReplica =
        "ice.macs-fan-control.monochrome"

    /// A representation of a captured menu bar item image.
    struct CapturedImage: Hashable {
        /// The base image.
        let cgImage: CGImage

        /// The scale factor of the image at the time of capture.
        let scale: CGFloat

        /// Whether this image was reconstructed from Accessibility metadata
        /// instead of captured from the actual MenuBarAgent button.
        let isSemanticReplica: Bool

        /// Stable description of a reconstructed image. Reusing an existing
        /// image with the same identity prevents the three-second refresh from
        /// needlessly invalidating every Layout tile.
        let replicaIdentity: String?

        init(
            cgImage: CGImage,
            scale: CGFloat,
            isSemanticReplica: Bool = false,
            replicaIdentity: String? = nil
        ) {
            self.cgImage = cgImage
            self.scale = scale
            self.isSemanticReplica = isSemanticReplica
            self.replicaIdentity = replicaIdentity
        }

        /// The image's size, applying ``scale``.
        var scaledSize: CGSize {
            CGSize(
                width: CGFloat(cgImage.width) / scale,
                height: CGFloat(cgImage.height) / scale
            )
        }

        /// The base image, converted to an `NSImage` and applying ``scale``.
        var nsImage: NSImage {
            NSImage(cgImage: cgImage, size: scaledSize)
        }

        /// Returns whether two captures contain the same pixels. ScreenCaptureKit
        /// creates a new `CGImage` object on every refresh even when the status
        /// glyph did not change; retaining the prior object prevents a needless
        /// Layout redraw every three seconds.
        static func isVisuallyEqual(_ old: CapturedImage, _ new: CapturedImage) -> Bool {
            if old.cgImage === new.cgImage {
                return true
            }
            guard
                old.scale == new.scale,
                old.cgImage.width == new.cgImage.width,
                old.cgImage.height == new.cgImage.height,
                let oldData = old.cgImage.dataProvider?.data,
                let newData = new.cgImage.dataProvider?.data
            else {
                return false
            }
            return CFEqual(oldData, newData)
        }
    }

    /// The result of an image capture operation.
    private struct CaptureResult {
        /// The successfully captured images.
        var images = [MenuBarItemTag: CapturedImage]()

        /// The menu bar items excluded from the capture.
        var excluded = [MenuBarItem]()
    }

    /// The cached item images, keyed by their corresponding tags.
    @Published private(set) var images = [MenuBarItemTag: CapturedImage]()

    /// Logger for the menu bar item image cache.
    private let logger = Logger(category: "MenuBarItemImageCache")

    /// Queue to run cache operations.
    private let queue = DispatchQueue(label: "MenuBarItemImageCache", qos: .background)

    /// Image capture options.
    private let captureOption: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    // MARK: Setup

    /// Sets up the cache.
    @MainActor
    func performSetup(with appState: AppState) {
        self.appState = appState
        configureCancellables()
    }

    /// Configures the internal observers for the cache.
    @MainActor
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            Publishers.Merge3(
                // Update every 3 seconds at minimum.
                Timer.publish(every: 3, on: .main, in: .default).autoconnect().replace(with: ()),

                // Update when the active space or screen parameters change.
                Publishers.Merge(
                    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
                    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                )
                .replace(with: ()),

                // Update when the average menu bar color or cached items change.
                Publishers.Merge(
                    appState.menuBarManager.$averageColorInfo.removeDuplicates().replace(with: ()),
                    appState.itemManager.$itemCache.removeDuplicates().replace(with: ())
                )
            )
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: false)
            .sink { [weak self] in
                guard let self else {
                    return
                }
                Task {
                    await self.updateCache()
                }
            }
            .store(in: &c)
        }

        cancellables = c
    }

    // MARK: Capturing Images

    /// Captures a composite image of the given items, then crops out an image
    /// for each item and returns the result.
    private nonisolated func compositeCapture(_ items: [MenuBarItem], scale: CGFloat) -> CaptureResult {
        var result = CaptureResult()

        var windowIDs = [CGWindowID]()
        var storage = [CGWindowID: (MenuBarItem, CGRect)]()
        var boundsUnion = CGRect.null

        for item in items {
            let windowID = item.windowID

            // Don't use `item.bounds`, it could be out of date.
            guard let bounds = Bridging.getWindowBounds(for: windowID) else {
                result.excluded.append(item)
                continue
            }

            windowIDs.append(windowID)
            storage[windowID] = (item, bounds)
            boundsUnion = boundsUnion.union(bounds)
        }

        guard
            let compositeImage = ScreenCapture.captureWindows(with: windowIDs, option: captureOption),
            CGFloat(compositeImage.width) == boundsUnion.width * scale, // Safety check.
            !compositeImage.isTransparent()
        else {
            result.excluded = items // Exclude all items.
            return result
        }

        // Crop out each item from the composite.
        for windowID in windowIDs {
            guard let (item, bounds) = storage[windowID] else {
                continue
            }

            let cropRect = CGRect(
                x: (bounds.origin.x - boundsUnion.origin.x) * scale,
                y: (bounds.origin.y - boundsUnion.origin.y) * scale,
                width: bounds.width * scale,
                height: bounds.height * scale
            )

            guard
                let image = compositeImage.cropping(to: cropRect),
                !image.isTransparent()
            else {
                result.excluded.append(item)
                continue
            }

            result.images[item.tag] = CapturedImage(cgImage: image, scale: scale)
        }

        return result
    }

    /// Captures an image of each of the given items individually, then
    /// returns the result.
    private nonisolated func individualCapture(_ items: [MenuBarItem], scale: CGFloat) -> CaptureResult {
        var result = CaptureResult()

        for item in items {
            guard
                let image = ScreenCapture.captureWindow(with: item.windowID, option: captureOption),
                !image.isTransparent()
            else {
                result.excluded.append(item)
                continue
            }
            result.images[item.tag] = CapturedImage(cgImage: image, scale: scale)
        }

        return result
    }

    /// Captures the images of the given menu bar items and returns the result.
    private nonisolated func captureImages(of items: [MenuBarItem], scale: CGFloat, appState: AppState) async -> CaptureResult {
        if #available(macOS 27.0, *) {
            let displayID = await appState.itemManager.itemCache.displayID ?? CGMainDisplayID()
            return await captureMacOS27Images(
                of: items,
                displayID: displayID,
                fallbackScale: scale
            )
        }

        // Use individual capture after a move operation, since composite capture
        // doesn't account for overlapping items.
        if await appState.itemManager.lastMoveOperationOccurred(within: .seconds(2)) {
            logger.debug("Capturing individually due to recent item movement")
            return individualCapture(items, scale: scale)
        }

        let compositeResult = compositeCapture(items, scale: scale)

        if compositeResult.excluded.isEmpty {
            return compositeResult // All items captured successfully.
        }

        logger.notice(
            """
            Some items were excluded from composite capture. Attempting to capture \
            excluded items individually: \(compositeResult.excluded, privacy: .public)
            """
        )

        var individualResult = individualCapture(compositeResult.excluded, scale: scale)

        // Merge the successfully captured images from each result. Keep excluded
        // items as part of the result, so they can be logged elsewhere.
        individualResult.images.merge(compositeResult.images) { (_, new) in new }

        return individualResult
    }

    /// Captures the exact pixels currently rendered for macOS 27 status items.
    /// Apple modules are cleanest in MenuBarAgent's transparent hosting window;
    /// third-party Liquid Glass items are read from the visible display strip.
    /// Accessibility-derived replicas remain only as a non-prompting fallback
    /// for concealed items and unavailable capture permission.
    @available(macOS 27.0, *)
    private nonisolated func captureMacOS27Images(
        of items: [MenuBarItem],
        displayID: CGDirectDisplayID,
        fallbackScale: CGFloat
    ) async -> CaptureResult {
        let capturable = items.filter { !$0.isControlItem || $0.tag == .visibleControlItem }
        guard !capturable.isEmpty else { return CaptureResult() }

        var result = CaptureResult()

        if ScreenCapture.cachedCheckPermissions() {
            // Layout reveals all sections before this pass. Refresh only the
            // participating owners so crop geometry follows each item's live
            // position without another full running-application AX scan.
            let sourcePIDs = Set(capturable.map { $0.sourcePID ?? $0.ownerPID })
            let namespaces = Set(capturable.map(\.tag.namespace))
            let refreshedItems = await Task.detached(priority: .userInitiated) {
                MacOS27MenuBarItemProvider.menuBarItems(
                    sourcePIDs: sourcePIDs,
                    namespaces: namespaces
                )
            }.value
            let refreshedByTag = Dictionary(
                refreshedItems.map { ($0.tag, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            let liveItems = capturable.compactMap { refreshedByTag[$0.tag] }
            let systemItems = liveItems.filter { !prefersDisplayStripCapture(for: $0) }
            let thirdPartyItems = liveItems.filter { prefersDisplayStripCapture(for: $0) }

            if
                !systemItems.isEmpty,
                let capture = await ScreenCapture.captureMenuBarHostingWindow(displayID: displayID),
                isPlausibleMacOS27Capture(capture)
            {
                appendMacOS27Crops(
                    for: systemItems,
                    from: capture,
                    knockOutBackground: false,
                    into: &result
                )
            }

            if
                !thirdPartyItems.isEmpty,
                let capture = await ScreenCapture.captureMenuBarDisplayStrip(displayID: displayID),
                isPlausibleMacOS27Capture(capture)
            {
                appendMacOS27Crops(
                    for: thirdPartyItems,
                    from: capture,
                    knockOutBackground: true,
                    into: &result
                )
            }
        }

        for item in capturable where result.images[item.tag] == nil {
            if let replica = menuBarReplicaImage(for: item, scale: fallbackScale) {
                result.images[item.tag] = replica
            } else {
                result.excluded.append(item)
            }
        }
        let exactItems = result.images
            .filter { !$0.value.isSemanticReplica }
            .map { $0.key.description }
            .sorted()
        let exactTags = exactItems.joined(separator: ", ")
        let replicaCount = result.images.values.filter(\.isSemanticReplica).count
        logger.debug(
            "macOS 27 thumbnails: \(exactItems.count, privacy: .public) exact [\(exactTags, privacy: .public)], \(replicaCount, privacy: .public) replicas, \(result.excluded.count, privacy: .public) excluded"
        )
        return result
    }

    /// Genuine Apple-hosted modules render correctly in MenuBarAgent's private
    /// window. Ice and all third-party namespaces use the visible display strip,
    /// which preserves their actual artwork instead of column-shredded hosting
    /// pixels.
    @available(macOS 27.0, *)
    private nonisolated func prefersDisplayStripCapture(for item: MenuBarItem) -> Bool {
        if item.isControlItem {
            return true
        }
        return !item.tag.namespace.description.hasPrefix("com.apple.")
    }

    @available(macOS 27.0, *)
    private nonisolated func isPlausibleMacOS27Capture(
        _ capture: ScreenCapture.MenuBarHostingCapture
    ) -> Bool {
        guard
            capture.scale.isFinite,
            capture.scale > 0,
            capture.windowFrame.width.isFinite,
            capture.windowFrame.height.isFinite,
            capture.windowFrame.width > 0,
            capture.windowFrame.height > 0
        else {
            return false
        }
        return abs(CGFloat(capture.image.width) - capture.windowFrame.width * capture.scale) <= 3 &&
            abs(CGFloat(capture.image.height) - capture.windowFrame.height * capture.scale) <= 3
    }

    /// Crops one menu-bar capture into exact per-item images. Duplicate AX
    /// frames are rejected for both owners, preventing one glyph from being
    /// shown under several app names while MenuBarAgent is reflowing.
    @available(macOS 27.0, *)
    private nonisolated func appendMacOS27Crops(
        for items: [MenuBarItem],
        from capture: ScreenCapture.MenuBarHostingCapture,
        knockOutBackground: Bool,
        into result: inout CaptureResult
    ) {
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: capture.image.width,
            height: capture.image.height
        )
        var cropOwners = [CGRect: MenuBarItemTag]()

        for item in items {
            let bounds = item.bounds
            guard
                !bounds.isNull,
                !bounds.isEmpty,
                bounds.width >= 8,
                bounds.width <= 200,
                bounds.height > 0,
                bounds.height <= 40,
                capture.windowFrame.intersects(bounds)
            else {
                continue
            }

            let expectedCropRect = CGRect(
                x: (bounds.minX - capture.windowFrame.minX) * capture.scale,
                y: (bounds.minY - capture.windowFrame.minY) * capture.scale,
                width: bounds.width * capture.scale,
                height: bounds.height * capture.scale
            ).integral
            let cropRect = expectedCropRect.intersection(imageBounds)
            guard
                !cropRect.isNull,
                !cropRect.isEmpty,
                cropRect.minX - expectedCropRect.minX <= 1,
                cropRect.minY - expectedCropRect.minY <= 1,
                expectedCropRect.maxX - cropRect.maxX <= 1,
                expectedCropRect.maxY - cropRect.maxY <= 1
            else {
                continue
            }

            if let priorTag = cropOwners[cropRect] {
                result.images.removeValue(forKey: priorTag)
                continue
            }

            guard let rawImage = capture.image.cropping(to: cropRect) else {
                continue
            }
            let image: CGImage?
            if knockOutBackground {
                image = rawImage.knockingOutNearUniformBackground()
            } else {
                image = rawImage
            }
            guard let image, !image.isTransparent(alphaThreshold: 0.05) else {
                continue
            }

            cropOwners[cropRect] = item.tag
            result.images[item.tag] = CapturedImage(
                cgImage: image,
                scale: capture.scale
            )
        }
    }

    /// Draws the information that the status item exposes through Accessibility.
    /// This intentionally avoids application icons: those often look unrelated
    /// to the compact symbol or text the application actually puts in the bar.
    private nonisolated func menuBarReplicaImage(
        for item: MenuBarItem,
        scale: CGFloat
    ) -> CapturedImage? {
        let symbolName = replicaSymbolName(for: item)
        let label = replicaLabel(for: item)
        let pointSize: CGFloat = 14
        let font = NSFont.menuBarFont(ofSize: pointSize)

        let symbol = symbolName.flatMap { name in
            if name == Self.macsFanControlMonochromeReplica {
                return macsFanControlMonochromeImage(pointSize: pointSize)
            }
            return NSImage(systemSymbolName: name, accessibilityDescription: item.displayName)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        }
        let labelSize = label.map {
            ($0 as NSString).size(withAttributes: [.font: font])
        }
        guard symbol != nil || labelSize != nil else {
            return nil
        }
        let contentWidth = (symbol?.size.width ?? 0) +
            (symbol != nil && labelSize != nil ? 4 : 0) +
            (labelSize?.width ?? 0)
        let measuredWidth = item.bounds.width.isFinite && item.bounds.width >= 12
            ? item.bounds.width
            : max(18, contentWidth + 8)
        let measuredHeight = item.bounds.height.isFinite && item.bounds.height >= 18
            ? item.bounds.height
            : 22
        let logicalSize = CGSize(
            width: min(max(18, measuredWidth), 160),
            height: min(max(22, measuredHeight), 40)
        )

        let image = NSImage(size: logicalSize, flipped: false) { bounds in
            var cursorX = bounds.midX - min(contentWidth, bounds.width) / 2
            if let symbol {
                let symbolSize = symbol.size
                let symbolRect = CGRect(
                    x: cursorX,
                    y: bounds.midY - symbolSize.height / 2,
                    width: symbolSize.width,
                    height: symbolSize.height
                )
                symbol.draw(in: symbolRect)
                NSColor.labelColor.setFill()
                symbolRect.fill(using: .sourceIn)
                cursorX = symbolRect.maxX + 4
            }
            if let label {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                ]
                let labelRect = CGRect(
                    x: cursorX,
                    y: bounds.midY - (labelSize?.height ?? 0) / 2,
                    width: max(0, bounds.maxX - cursorX),
                    height: labelSize?.height ?? bounds.height
                )
                (label as NSString).draw(
                    in: labelRect,
                    withAttributes: attributes
                )
            }
            return true
        }

        var proposedRect = CGRect(origin: .zero, size: logicalSize)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        let effectiveScale = cgImage.width > 0 && logicalSize.width > 0
            ? CGFloat(cgImage.width) / logicalSize.width
            : scale
        let replicaIdentity = [
            symbolName ?? "",
            label ?? "",
            String(format: "%.2fx%.2f", logicalSize.width, logicalSize.height),
            NSAppearance.currentDrawing().name.rawValue,
        ].joined(separator: "|")
        return CapturedImage(
            cgImage: cgImage,
            scale: effectiveScale,
            isSemanticReplica: true,
            replicaIdentity: replicaIdentity
        )
    }

    /// Recreates the compact eight-blade status glyph selected by Macs Fan
    /// Control's monochrome menu-bar style. This is an independent geometric
    /// drawing rather than the application's artwork, and therefore scales and
    /// tints like the surrounding menu-bar symbols without any animation.
    private nonisolated func macsFanControlMonochromeImage(pointSize: CGFloat) -> NSImage {
        let image = NSImage(
            size: CGSize(width: pointSize, height: pointSize),
            flipped: false
        ) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }

            let innerRadius = pointSize * 0.23
            let outerRadius = pointSize * 0.44
            let hookLength = pointSize * 0.11

            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: bounds.midX, y: bounds.midY)
            context.setShouldAntialias(true)
            context.setLineWidth(max(1, pointSize * 0.08))
            context.setLineCap(.butt)
            context.setLineJoin(.miter)
            context.setStrokeColor(NSColor.labelColor.cgColor)

            for blade in 0..<8 {
                context.saveGState()
                context.rotate(by: CGFloat(blade) * .pi / 4)
                context.beginPath()
                context.move(to: CGPoint(x: 0, y: innerRadius))
                context.addLine(to: CGPoint(x: 0, y: outerRadius))
                context.addLine(to: CGPoint(x: -hookLength, y: outerRadius))
                context.strokePath()
                context.restoreGState()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private nonisolated func replicaSymbolName(for item: MenuBarItem) -> String? {
        let value = "\(item.tag.title) \(item.title ?? "") \(item.displayName)".lowercased()
        let bundleIdentifier = item.sourceApplication?.bundleIdentifier
            ?? item.owningApplication?.bundleIdentifier
        if bundleIdentifier == "local.wenbo.AppVolumes" ||
            value.contains("app volumes") || value.contains("app 音量")
        {
            // The installed App Volumes build assigns this exact SF Symbol to
            // its NSStatusItem button (MacMixApp.swift and the shipped binary).
            return "slider.horizontal.3"
        }
        if let bundleIdentifier, bundleIdentifier == "com.crystalidea.macsfancontrol" {
            let domain = bundleIdentifier as CFString
            let iconStyle = CFPreferencesCopyAppValue(
                "menubarIcon" as CFString,
                domain
            ) as? NSNumber
            if iconStyle?.intValue == 2 {
                return Self.macsFanControlMonochromeReplica
            }
            return "fan.fill"
        }
        if value.contains("spotlight") || value.contains("search") || value.contains("搜索") {
            return "magnifyingglass"
        }
        if value.contains("siri") { return "siri" }
        if value.contains("battery") || value.contains("电池") {
            return batterySymbolName(for: item.accessibilityValue)
        }
        if value.contains("wifi") || value.contains("wi-fi") { return "wifi" }
        if value.contains("bluetooth") { return "bluetooth" }
        if value.contains("controlcenter") || value.contains("control center") { return "switch.2" }
        if value.contains("display") || value.contains("screenmirroring") { return "rectangle.on.rectangle" }
        if value.contains("volume") || value.contains("sound") || value.contains("音量") { return "speaker.wave.2.fill" }
        if value.contains("audiovideo") || value.contains("audio and video") || value.contains("音频和视频") {
            return "video.fill"
        }
        if value.contains("now-playing") || value.contains("now playing") || value.contains("播放中") {
            return "play.fill"
        }
        if value.contains("fan") || value.contains("rpm") { return "fan.fill" }
        if value.contains("weather") { return "cloud.sun.fill" }
        if value.contains("password") { return "key.fill" }
        return nil
    }

    private nonisolated func replicaLabel(for item: MenuBarItem) -> String? {
        let raw = (item.title ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        if item.tag.namespace == .textInputMenuAgent {
            if let firstCJK = raw.first(where: { character in
                character.unicodeScalars.contains { $0.properties.isIdeographic }
            }) {
                return String(firstCJK)
            }
            if !raw.isEmpty, !raw.hasPrefix("Item-") {
                return compact(raw)
            }
            return currentInputSourceLabel()
        }

        let bundleIdentifier = item.sourceApplication?.bundleIdentifier
            ?? item.owningApplication?.bundleIdentifier
        if let bundleIdentifier, bundleIdentifier == "com.crystalidea.macsfancontrol" {
            // With no fan/sensor selected, Macs Fan Control displays only its
            // monochrome fan glyph. Its AXHelp still lists every live RPM, so
            // do not mistake that tooltip for visible status-item text.
            let domain = bundleIdentifier as CFString
            let selectedFan = CFPreferencesCopyAppValue("trayFan" as CFString, domain) as? String
            let selectedSensor = CFPreferencesCopyAppValue("traySensor" as CFString, domain) as? String
            guard selectedFan != nil && selectedFan != "-1" || !(selectedSensor ?? "").isEmpty else {
                return nil
            }
            let help = item.accessibilityHelp ?? ""
            if let range = help.range(of: #"\d+\s*RPM"#, options: .regularExpression) {
                return String(help[range]).replacingOccurrences(of: " ", with: "")
            }
        }

        if replicaSymbolName(for: item) != nil {
            // A recognized symbol represents the button itself. Appending the
            // owning application's name makes the Layout row look unlike the
            // compact status item and introduces artificial spacing.
            return nil
        }
        guard !raw.isEmpty else { return compact(item.displayName) }
        let genericTitles = ["item-0", "item-1", "window", "button"]
        if genericTitles.contains(raw.lowercased()) || raw.hasPrefix("Ice.ControlItem.") {
            return compact(item.displayName)
        }
        return compact(raw)
    }

    private nonisolated func batterySymbolName(for value: String?) -> String {
        let normalized = (value ?? "").lowercased()
        let percentage = normalized.firstMatch(of: /\d{1,3}/).flatMap {
            Int($0.output)
        } ?? 100
        let level = switch percentage {
        case ..<13: 0
        case ..<38: 25
        case ..<63: 50
        case ..<88: 75
        default: 100
        }
        let isCharging = normalized.contains("charging") ||
            normalized.contains("正在充电") || normalized.contains("充电中")
        let candidates = if isCharging {
            // SF Symbols provides the charging overlay on the full battery
            // template; the system fills it dynamically in the real menu bar.
            ["battery.100percent.bolt", "battery.100.bolt"]
        } else {
            ["battery.\(level)percent", "battery.\(level)"]
        }
        return candidates.first {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        } ?? "battery.100"
    }

    private nonisolated func currentInputSourceLabel() -> String? {
        let domain = "com.apple.HIToolbox" as CFString
        let selectedSources = CFPreferencesCopyAppValue(
            "AppleSelectedInputSources" as CFString,
            domain
        ) as? [[String: Any]] ?? []
        let currentLayout = CFPreferencesCopyAppValue(
            "AppleCurrentKeyboardLayoutInputSourceID" as CFString,
            domain
        ) as? String
        let identity = (selectedSources.flatMap { source in
            [source["Bundle ID"] as? String, source["Input Mode"] as? String]
                .compactMap { $0 }
        } + [currentLayout].compactMap { $0 })
            .joined(separator: " ")
            .lowercased()

        if identity.contains("scim") || identity.contains("itabc") ||
            identity.contains("pinyin") || identity.contains("simplified")
        {
            return "简"
        }
        if identity.contains("tcim") || identity.contains("zhuyin") ||
            identity.contains("traditional")
        {
            return "繁"
        }
        if identity.contains("japanese") || identity.contains("kotoeri") {
            return "あ"
        }
        if identity.contains("korean") { return "한" }
        if identity.contains("abc") || identity.contains("us") { return "ABC" }
        return nil
    }

    private nonisolated func compact(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(12))
    }

    /// Captures the images of the menu bar items in the given section and returns
    /// a dictionary containing the images, keyed by their menu bar item tags.
    private func captureImages(for section: MenuBarSection.Name, scale: CGFloat, appState: AppState) async -> [MenuBarItemTag: CapturedImage] {
        let items = await appState.itemManager.itemCache.managedItems(for: section)
        let captureResult = await captureImages(of: items, scale: scale, appState: appState)
        if !captureResult.excluded.isEmpty {
            logger.error("Some items failed capture: \(captureResult.excluded, privacy: .public)")
        }
        return captureResult.images
    }

    // MARK: Update Cache

    /// Updates the cache for the given sections, without checking whether
    /// caching is necessary.
    func updateCacheWithoutChecks(sections: [MenuBarSection.Name]) async {
        guard let appState else {
            return
        }

        guard
            let displayID = await appState.itemManager.itemCache.displayID,
            let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
        else {
            return
        }

        let scale = screen.backingScaleFactor
        var newImages = [MenuBarItemTag: CapturedImage]()

        if #available(macOS 27.0, *) {
            let allItems = await MainActor.run {
                sections.flatMap { section in
                    appState.itemManager.itemCache.managedItems(for: section)
                }
            }
            let result = await captureMacOS27Images(
                of: allItems,
                displayID: displayID,
                fallbackScale: scale
            )
            newImages = result.images
        } else {
            guard await appState.hasPermission(.screenRecording) else { return }

            for section in sections {
                guard await !appState.itemManager.itemCache[section].isEmpty else {
                    continue
                }

                let sectionImages = await captureImages(for: section, scale: scale, appState: appState)

                guard !sectionImages.isEmpty else {
                    logger.warning("Failed item image cache for \(section.logString, privacy: .public)")
                    continue
                }

                newImages.merge(sectionImages) { (_, new) in new }
            }
        }

        await MainActor.run { [newImages] in
            let validTags = Set(appState.itemManager.itemCache.managedItems.map(\.tag))
            var updatedImages = images.filter { validTags.contains($0.key) }
            updatedImages.merge(newImages) { old, new in
                if CapturedImage.isVisuallyEqual(old, new) {
                    return old
                }
                if
                    let oldIdentity = old.replicaIdentity,
                    oldIdentity == new.replicaIdentity
                {
                    return old
                }
                // A temporarily concealed item must not replace its last exact
                // crop with a replica merely because it is absent this tick.
                return new.isSemanticReplica && !old.isSemanticReplica ? old : new
            }
            // Publishing an equal dictionary still wakes every Layout tile.
            // Assign only when content really changed so the periodic refresh
            // cannot produce a redraw pulse.
            if updatedImages != images {
                images = updatedImages
            }
        }
    }

    /// Updates the cache for the given sections, if necessary.
    func updateCache(sections: [MenuBarSection.Name]) async {
        guard let appState else {
            return
        }

        let isIceBarPresented = await appState.navigationState.isIceBarPresented
        let isSearchPresented = await appState.navigationState.isSearchPresented

        if !isIceBarPresented && !isSearchPresented {
            guard
                await appState.navigationState.isAppFrontmost,
                await appState.navigationState.isSettingsPresented,
                await appState.navigationState.settingsNavigationIdentifier == .menuBarLayout
            else {
                return
            }
        }

        guard await !appState.itemManager.lastMoveOperationOccurred(within: .seconds(1)) else {
            logger.debug("Skipping item image cache due to recent item movement")
            return
        }

        await updateCacheWithoutChecks(sections: sections)
    }

    /// Updates the cache for all sections, if necessary.
    func updateCache() async {
        guard let appState else {
            return
        }

        let isIceBarPresented = await appState.navigationState.isIceBarPresented
        let isSearchPresented = await appState.navigationState.isSearchPresented
        let isSettingsPresented = await appState.navigationState.isSettingsPresented

        var sectionsNeedingDisplay = [MenuBarSection.Name]()

        if isSettingsPresented || isSearchPresented {
            sectionsNeedingDisplay = MenuBarSection.Name.allCases
        } else if
            isIceBarPresented,
            let section = await appState.menuBarManager.iceBarPanel.currentSection
        {
            sectionsNeedingDisplay.append(section)
        }

        await updateCache(sections: sectionsNeedingDisplay)
    }

    // MARK: Cache Failed

    /// Returns a Boolean value that indicates whether caching menu bar items
    /// failed for the given section.
    @MainActor
    func cacheFailed(for section: MenuBarSection.Name) -> Bool {
        if #unavailable(macOS 27.0) {
            guard ScreenCapture.cachedCheckPermissions() else { return true }
        }
        let items = appState?.itemManager.itemCache[section] ?? []
        guard !items.isEmpty else {
            return false
        }
        let keys = Set(images.keys)
        for item in items where keys.contains(item.tag) {
            return false
        }
        return true
    }
}
