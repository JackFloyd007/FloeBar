//
//  ScreenCapture.swift
//  Ice
//

import CoreGraphics
import CoreVideo
@preconcurrency import ScreenCaptureKit

/// A namespace for screen capture operations.
enum ScreenCapture {

    // MARK: Permissions

    /// Returns a Boolean value that indicates whether the app has screen
    /// capture permissions.
    static func checkPermissions() -> Bool {
        for windowID in Bridging.getMenuBarWindowList(option: [.itemsOnly, .activeSpace]) {
            guard
                let window = WindowInfo(windowID: windowID),
                window.owningApplication != .current // Skip windows we own.
            else {
                continue
            }
            if window.title != nil {
                return true
            }
        }
        // CGPreflightScreenCaptureAccess() only returns an initial value,
        // but we can use it as a fallback.
        return CGPreflightScreenCaptureAccess()
    }

    /// Returns a Boolean value that indicates whether the app has screen
    /// capture permissions.
    ///
    /// This function caches its initial result and returns it on subsequent
    /// calls. Pass `true` to the `reset` parameter to replace the cached
    /// result with a newly computed value.
    static func cachedCheckPermissions(reset: Bool = false) -> Bool {
        enum Context {
            static var cachedResult: Bool?
        }
        // Cache both outcomes. Background Layout refreshes run frequently on
        // macOS 27; recomputing a negative result lets every refresh reach TCC
        // and can repeatedly surface the system consent alert. The dedicated
        // permission observer explicitly resets this cache while it polls, so
        // a newly granted permission still takes effect without a relaunch.
        if !reset, let cachedResult = Context.cachedResult {
            return cachedResult
        }
        let result = checkPermissions()
        Context.cachedResult = result
        return result
    }

    /// Requests screen capture permissions.
    static func requestPermissions() {
        if #available(macOS 27.0, *) {
            // On macOS 27, querying SCShareableContent while the current
            // binary is not authorized can repeatedly display the system
            // consent alert. Only use the explicit, user-initiated request.
            CGRequestScreenCaptureAccess()
        } else if #available(macOS 15.0, *) {
            // CGRequestScreenCaptureAccess() is broken on macOS 15. We can
            // try accessing SCShareableContent to trigger a request if the
            // user doesn't have permissions.
            // TODO: Find out if we still need this as of macOS 26.
            SCShareableContent.getWithCompletionHandler { _, _ in }
        } else {
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: Capture Window(s)

    /// Captures a composite image of an array of windows.
    ///
    /// The windows are composited from front to back, according to the order
    /// of the `windowIDs` parameter.
    ///
    /// - Parameters:
    ///   - windowIDs: The identifiers of the windows to capture.
    ///   - screenBounds: The bounds to capture, specified in screen coordinates.
    ///     Pass `nil` to capture the minimum rectangle that encloses the windows.
    ///   - option: Options that specify which parts of the windows are captured.
    static func captureWindows(with windowIDs: [CGWindowID], screenBounds: CGRect? = nil, option: CGWindowImageOption = []) -> CGImage? {
        guard let array = Bridging.createCGWindowArray(with: windowIDs) else {
            return nil
        }
        let bounds = screenBounds ?? .null
        // ScreenCaptureKit doesn't support capturing images of offscreen menu bar
        // items, so we unfortunately have to use the deprecated CGWindowList API.
        return CGImage(windowListFromArrayScreenBounds: bounds, windowArray: array, imageOption: option)
    }

    /// Captures an image of a window.
    ///
    /// - Parameters:
    ///   - windowID: The identifier of the window to capture.
    ///   - screenBounds: The bounds to capture, specified in screen coordinates.
    ///     Pass `nil` to capture the minimum rectangle that encloses the window.
    ///   - option: Options that specify which parts of the window are captured.
    static func captureWindow(with windowID: CGWindowID, screenBounds: CGRect? = nil, option: CGWindowImageOption = []) -> CGImage? {
        captureWindows(with: [windowID], screenBounds: screenBounds, option: option)
    }

    // MARK: macOS 27 MenuBarAgent Capture

    @available(macOS 27.0, *)
    struct MenuBarHostingCapture {
        let image: CGImage
        let windowFrame: CGRect
        let scale: CGFloat
    }

    /// Returns whether ScreenCaptureKit reported the macOS 27 hosting strip in
    /// point space or in backing-pixel space. Some early macOS 27 builds use
    /// the latter, and multiplying that frame by `pointPixelScale` a second
    /// time produces shifted or half-height menu-bar crops.
    @available(macOS 27.0, *)
    private static func hostingFrameAppearsPixelBacked(
        _ frame: CGRect,
        displayFrame: CGRect
    ) -> Bool {
        guard displayFrame.width > 0 else { return false }
        return frame.height > 40 || frame.width > displayFrame.width * 1.5
    }

    /// Normalizes a captured bitmap to a point-space frame and the actual
    /// bitmap-to-point scale. Deriving the scale from the returned image keeps
    /// AX crop geometry aligned when ScreenCaptureKit's reported scale drifts.
    @available(macOS 27.0, *)
    private static func normalizedMenuBarCapture(
        image: CGImage,
        windowFrame: CGRect,
        displayFrame: CGRect,
        reportedScale: CGFloat
    ) -> MenuBarHostingCapture? {
        guard
            image.width > 0,
            image.height > 0,
            displayFrame.width > 0,
            displayFrame.height > 0
        else {
            return nil
        }

        if hostingFrameAppearsPixelBacked(windowFrame, displayFrame: displayFrame) {
            let scale = CGFloat(image.width) / displayFrame.width
            guard scale > 0.5, scale < 6 else { return nil }
            return MenuBarHostingCapture(
                image: image,
                windowFrame: CGRect(
                    x: displayFrame.minX,
                    y: displayFrame.minY,
                    width: displayFrame.width,
                    height: CGFloat(image.height) / scale
                ),
                scale: scale
            )
        }

        guard windowFrame.width > 0, windowFrame.height > 0 else { return nil }
        let scale = CGFloat(image.width) / windowFrame.width
        guard scale > 0.5, scale < 6 else { return nil }

        if abs(CGFloat(image.height) - windowFrame.height * scale) > 3 {
            let displayScale = CGFloat(image.width) / displayFrame.width
            guard displayScale > 0.5, displayScale < 6 else { return nil }
            return MenuBarHostingCapture(
                image: image,
                windowFrame: CGRect(
                    x: displayFrame.minX,
                    y: displayFrame.minY,
                    width: displayFrame.width,
                    height: CGFloat(image.height) / displayScale
                ),
                scale: displayScale
            )
        }

        _ = reportedScale
        return MenuBarHostingCapture(
            image: image,
            windowFrame: windowFrame,
            scale: scale
        )
    }

    /// Captures the full-width MenuBarAgent window that composites Apple
    /// status items on macOS 27. Returns `nil` rather than mixing in unrelated
    /// display-strip pixels when the private hosting window is unavailable.
    @available(macOS 27.0, *)
    static func captureMenuBarHostingWindow(
        displayID: CGDirectDisplayID
    ) async -> MenuBarHostingCapture? {
        // SCShareableContent itself can trigger a consent alert. Cache the
        // non-prompting permission check so the layout refresh timer does not
        // hit TCC every three seconds. The caller has a semantic replica when
        // capture is unavailable.
        guard cachedCheckPermissions() else {
            return nil
        }

        let content: SCShareableContent
        do {
            content = try await shareableContent()
        } catch {
            return nil
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            return nil
        }
        let displayFrame = display.frame
        let hostingWindow = content.windows
            .filter { window in
                let pointSpaceGeometry =
                    window.frame.height <= 40 &&
                    window.frame.width > displayFrame.width * 0.8
                let pixelSpaceGeometry =
                    window.frame.height > 40 &&
                    window.frame.height <= 80 &&
                    window.frame.width > displayFrame.width * 1.5
                return window.owningApplication?.bundleIdentifier == "com.apple.MenuBarAgent" &&
                window.frame.height > 0 &&
                (pointSpaceGeometry || pixelSpaceGeometry) &&
                abs(window.frame.minX - displayFrame.minX) < 2 &&
                abs(window.frame.minY - displayFrame.minY) < 2
            }
            .max { $0.windowID < $1.windowID }

        // A full-display fallback includes unrelated app-menu pixels and can
        // silently associate them with status items. A clean miss is safer;
        // callers retain the last exact image or use a semantic fallback.
        guard let hostingWindow else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: hostingWindow)
        let captureFrame = hostingWindow.frame
        let reportedScale = CGFloat(filter.pointPixelScale)
        let pixelBacked = hostingFrameAppearsPixelBacked(
            captureFrame,
            displayFrame: displayFrame
        )
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureDynamicRange = .SDR
        configuration.width = max(
            1,
            Int((captureFrame.width * (pixelBacked ? 1 : max(reportedScale, 0.5))).rounded())
        )
        configuration.height = max(
            1,
            Int((captureFrame.height * (pixelBacked ? 1 : max(reportedScale, 0.5))).rounded())
        )

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return normalizedMenuBarCapture(
                image: image,
                windowFrame: captureFrame,
                displayFrame: displayFrame,
                reportedScale: reportedScale
            )
        } catch {
            return nil
        }
    }

    /// Captures the visible menu-bar band of a display. Third-party status
    /// items on macOS 27 are composited incorrectly in MenuBarAgent's private
    /// hosting window, while this display crop contains the exact pixels the
    /// user sees. Callers remove the near-uniform menu-bar background after
    /// cropping each AX item frame.
    @available(macOS 27.0, *)
    static func captureMenuBarDisplayStrip(
        displayID: CGDirectDisplayID
    ) async -> MenuBarHostingCapture? {
        // Never let a background image refresh trigger TCC UI. If this build
        // is not currently authorized, Layout keeps its last exact image (or a
        // semantic fallback) until the user grants permission explicitly.
        guard cachedCheckPermissions() else {
            return nil
        }

        let content: SCShareableContent
        do {
            content = try await shareableContent()
        } catch {
            return nil
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            return nil
        }

        let displayFrame = display.frame
        let stripFrame = CGRect(
            x: displayFrame.minX,
            y: displayFrame.minY,
            width: displayFrame.width,
            height: min(40, displayFrame.height)
        )
        // Exclude overlays above the main-menu window level. They are painted
        // over the real status items and would otherwise contaminate a crop.
        let mainMenuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let overlayWindows = content.windows.filter { window in
            window.isOnScreen &&
                window.windowLayer > mainMenuLevel &&
                window.frame.intersects(stripFrame)
        }
        let filter = SCContentFilter(display: display, excludingWindows: overlayWindows)
        let reportedScale = CGFloat(filter.pointPixelScale)
        let scale = max(reportedScale, 0.5)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureDynamicRange = .SDR
        configuration.width = max(1, Int((stripFrame.width * scale).rounded()))
        configuration.height = max(1, Int((stripFrame.height * scale).rounded()))
        configuration.sourceRect = CGRect(
            x: stripFrame.minX - displayFrame.minX,
            y: stripFrame.minY - displayFrame.minY,
            width: stripFrame.width,
            height: stripFrame.height
        )

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return normalizedMenuBarCapture(
                image: image,
                windowFrame: stripFrame,
                displayFrame: displayFrame,
                reportedScale: reportedScale
            )
        } catch {
            return nil
        }
    }

    @available(macOS 27.0, *)
    private static func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getWithCompletionHandler { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: CaptureError.noShareableContent)
                }
            }
        }
    }

    private enum CaptureError: Error {
        case noShareableContent
    }
}
