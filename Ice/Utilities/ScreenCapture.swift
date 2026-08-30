//
//  ScreenCapture.swift
//  Ice
//

import CoreGraphics
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
            return window.title != nil
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
        if !reset, let result = Context.cachedResult {
            return result
        }
        let result = checkPermissions()
        Context.cachedResult = result
        return result
    }

    /// Requests screen capture permissions.
    static func requestPermissions() {
        if #available(macOS 15.0, *) {
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

    /// Captures the full-width MenuBarAgent window that composites status
    /// items on macOS 27. Falls back to the top strip of the display if the
    /// private hosting window is not exposed by ScreenCaptureKit.
    @available(macOS 27.0, *)
    static func captureMenuBarHostingWindow(
        displayID: CGDirectDisplayID
    ) async -> MenuBarHostingCapture? {
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
                window.owningApplication?.bundleIdentifier == "com.apple.MenuBarAgent" &&
                window.frame.height > 0 &&
                window.frame.height <= 40 &&
                window.frame.width > displayFrame.width * 0.8 &&
                abs(window.frame.minX - displayFrame.minX) < 2 &&
                abs(window.frame.minY - displayFrame.minY) < 2
            }
            .max { $0.windowID < $1.windowID }

        let filter: SCContentFilter
        let captureFrame: CGRect
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false

        if let hostingWindow {
            filter = SCContentFilter(desktopIndependentWindow: hostingWindow)
            captureFrame = hostingWindow.frame
            configuration.ignoreShadowsSingleWindow = true
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
            captureFrame = CGRect(
                x: displayFrame.minX,
                y: displayFrame.minY,
                width: displayFrame.width,
                height: min(40, displayFrame.height)
            )
            configuration.sourceRect = CGRect(
                x: 0,
                y: 0,
                width: captureFrame.width,
                height: captureFrame.height
            )
        }

        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int((captureFrame.width * scale).rounded())
        configuration.height = Int((captureFrame.height * scale).rounded())

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return MenuBarHostingCapture(image: image, windowFrame: captureFrame, scale: scale)
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
