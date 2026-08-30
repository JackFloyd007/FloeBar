//
//  MenuBarItemImageCache.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

/// Cache for menu bar item images.
final class MenuBarItemImageCache: ObservableObject {
    /// A representation of a captured menu bar item image.
    struct CapturedImage: Hashable {
        /// The base image.
        let cgImage: CGImage

        /// The scale factor of the image at the time of capture.
        let scale: CGFloat

        /// Whether this image was reconstructed from Accessibility metadata
        /// instead of captured from the actual MenuBarAgent button.
        let isSemanticReplica: Bool

        init(cgImage: CGImage, scale: CGFloat, isSemanticReplica: Bool = false) {
            self.cgImage = cgImage
            self.scale = scale
            self.isSemanticReplica = isSemanticReplica
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
            return await captureMacOS27Images(of: items, fallbackScale: scale)
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

    /// Captures macOS 27 items from MenuBarAgent's composite hosting window.
    /// Items that are currently concealed, or systems without Screen Recording
    /// permission, receive a semantic replica of their menu bar button instead
    /// of the owning application's icon.
    @available(macOS 27.0, *)
    private nonisolated func captureMacOS27Images(
        of items: [MenuBarItem],
        fallbackScale: CGFloat
    ) async -> CaptureResult {
        let capturable = items.filter { !$0.isControlItem || $0.tag == .visibleControlItem }
        guard !capturable.isEmpty else { return CaptureResult() }

        let displayID = Bridging.getActiveMenuBarDisplayID() ?? CGMainDisplayID()
        let capture = await ScreenCapture.captureMenuBarHostingWindow(displayID: displayID)
        var result = CaptureResult()

        if let capture {
            let imageBounds = CGRect(
                x: 0,
                y: 0,
                width: capture.image.width,
                height: capture.image.height
            )
            for item in capturable where capture.windowFrame.intersects(item.bounds) {
                let rawCropRect = CGRect(
                    x: (item.bounds.minX - capture.windowFrame.minX) * capture.scale,
                    y: (item.bounds.minY - capture.windowFrame.minY) * capture.scale,
                    width: item.bounds.width * capture.scale,
                    height: item.bounds.height * capture.scale
                )
                let cropRect = rawCropRect.integral.intersection(imageBounds)
                guard
                    !cropRect.isNull,
                    !cropRect.isEmpty,
                    let image = capture.image.cropping(to: cropRect),
                    !image.isTransparent(alphaThreshold: 0.05)
                else {
                    continue
                }
                result.images[item.tag] = CapturedImage(cgImage: image, scale: capture.scale)
            }
        }

        for item in capturable where result.images[item.tag] == nil || prefersSemanticReplica(for: item) {
            if let fallback = menuBarReplicaImage(for: item, scale: fallbackScale) {
                result.images[item.tag] = fallback
            } else {
                result.excluded.append(item)
            }
        }
        return result
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

        let symbol = symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: item.displayName)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        }
        let labelSize = label.map {
            ($0 as NSString).size(withAttributes: [.font: font])
        }
        let logicalSize: CGSize
        if let symbol {
            logicalSize = CGSize(
                width: max(18, symbol.size.width + (labelSize.map { $0.width + 4 } ?? 0)),
                height: 18
            )
        } else if let labelSize {
            logicalSize = CGSize(width: min(max(18, labelSize.width), 112), height: 18)
        } else {
            return nil
        }

        let image = NSImage(size: logicalSize, flipped: false) { bounds in
            var cursorX = bounds.minX
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
        return CapturedImage(
            cgImage: cgImage,
            scale: effectiveScale,
            isSemanticReplica: true
        )
    }

    private nonisolated func replicaSymbolName(for item: MenuBarItem) -> String? {
        let value = "\(item.tag.title) \(item.title ?? "") \(item.displayName)".lowercased()
        if value.contains("spotlight") || value.contains("search") || value.contains("搜索") {
            return "magnifyingglass"
        }
        if value.contains("siri") { return "siri" }
        if value.contains("battery") { return "battery.100" }
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
        if item.tag.namespace == .textInputMenuAgent,
           let inputSourceLabel = currentInputSourceLabel()
        {
            return inputSourceLabel
        }

        let raw = (item.title ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !raw.isEmpty else {
            return replicaSymbolName(for: item) == nil ? compact(item.displayName) : nil
        }

        if item.tag.namespace == .textInputMenuAgent {
            if let firstCJK = raw.first(where: { character in
                character.unicodeScalars.contains { $0.properties.isIdeographic }
            }) {
                return String(firstCJK)
            }
            return compact(raw)
        }
        if raw.localizedCaseInsensitiveContains("rpm"),
           let range = raw.range(of: #"\d+\s*RPM"#, options: .regularExpression)
        {
            return String(raw[range])
        }
        if replicaSymbolName(for: item) != nil {
            // A recognized symbol represents the button itself. Appending the
            // owning application's name makes the Layout row look unlike the
            // compact status item and introduces artificial spacing.
            return nil
        }
        let genericTitles = ["item-0", "item-1", "window", "button"]
        if genericTitles.contains(raw.lowercased()) || raw.hasPrefix("Ice.ControlItem.") {
            return compact(item.displayName)
        }
        return compact(raw)
    }

    /// Some hosted system items expose a generic AX identity instead of their
    /// actual pixels. Prefer a deterministic menu-bar glyph for those items so
    /// Layout never falls back to labels such as `Item-0` or `Spotlight`.
    private nonisolated func prefersSemanticReplica(for item: MenuBarItem) -> Bool {
        if item.tag.namespace == .textInputMenuAgent { return true }
        let value = "\(item.tag.title) \(item.title ?? "") \(item.displayName)".lowercased()
        return value.contains("spotlight") || value.contains("search") || value.contains("搜索")
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

        if #unavailable(macOS 27.0) {
            guard await appState.hasPermission(.screenRecording) else { return }
        }

        guard
            let displayID = await appState.itemManager.itemCache.displayID,
            let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
        else {
            return
        }

        let scale = screen.backingScaleFactor
        var newImages = [MenuBarItemTag: CapturedImage]()

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

        await MainActor.run { [newImages] in
            let validTags = Set(appState.itemManager.itemCache.managedItems.map(\.tag))
            images = images.filter { validTags.contains($0.key) }
            images.merge(newImages) { current, new in
                // A concealed item can only produce a semantic fallback. Keep
                // its last exact capture until it is visible and can be
                // recaptured, rather than replacing it with a guessed icon.
                if !current.isSemanticReplica, new.isSemanticReplica {
                    return current
                }
                return new
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
