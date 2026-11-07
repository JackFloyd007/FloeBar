//
//  ScreenCapture.swift
//  Ice
//

import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import OSLog
@preconcurrency import ScreenCaptureKit

/// A namespace for screen capture operations.
enum ScreenCapture {

    // MARK: Permissions

    /// Returns a Boolean value that indicates whether the app has screen
    /// capture permissions.
    static func checkPermissions() -> Bool {
        if #available(macOS 27.0, *) {
            // Window metadata is not evidence of permission to capture pixels.
            return CGPreflightScreenCaptureAccess()
        }
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
            static let lock = NSLock()
            static var cachedResult: Bool?
        }
        Context.lock.lock()
        defer { Context.lock.unlock() }
        // Cache both outcomes for display/legacy consumers. This check never
        // requests permission; explicit native previews recheck just before use.
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
        // On27, all pixel capture is reserved for the explicit preview API.
        // Background color/wallpaper consumers keep their normal nil fallback.
        if #available(macOS 27.0, *) { return nil }
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

    // MARK: macOS 27 Menu Bar Capture

    @available(macOS 27.0, *)
    struct MenuBarCapture {
        let image: CGImage
        let windowFrame: CGRect
        let scale: CGFloat
    }

    /// Take one composited screen-region screenshot, then crop by live AX frames.
    /// Window/stream capture does not preserve all hosted status-item pixels on
    /// macOS 27. This screenshot API captures what is actually on the display.
    @available(macOS 27.0, *)
    @MainActor
    static func captureMenuBarDisplayStrip(
        displayID: CGDirectDisplayID,
        userInitiated: Bool = false,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async -> MenuBarCapture? {
        guard userInitiated, !Task.isCancelled, isCurrent() else { return nil }
        let displayFrame = CGDisplayBounds(displayID)
        guard displayFrame.width > 0, displayFrame.height > 0 else { return nil }
        let stripFrame = CGRect(
            x: displayFrame.minX,
            y: displayFrame.minY,
            width: displayFrame.width,
            height: min(40, displayFrame.height)
        )
        // CGDisplayPixelsWide reports logical pixels on HiDPI displays (1470
        // here for a 2940-pixel Retina buffer). Capture at the backing scale,
        // otherwise the source has already lost detail before Layout draws it.
        let scale = await MainActor.run {
            NSScreen.screens.first { $0.displayID == displayID }?.backingScaleFactor
        } ?? CGDisplayCopyDisplayMode(displayID).map {
            CGFloat($0.pixelWidth) / CGFloat(max(1, $0.width))
        } ?? 1
        guard let geometry = MenuBarCaptureGeometry(frame: stripFrame, scale: scale) else { return nil }
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        configuration.displayIntent = .local
        configuration.width = geometry.pixelWidth
        configuration.height = geometry.pixelHeight

        do {
            let output = try await MenuBarPreviewAuthorization.capture(
                userInitiated: userInitiated,
                isCurrent: isCurrent,
                preflight: { CGPreflightScreenCaptureAccess() },
                operation: {
                    Logger(category: "ScreenCapture").notice("Explicit menu bar pixel preview capture starting")
                    return try await SCScreenshotManager.captureScreenshot(rect: stripFrame, configuration: configuration)
                }
            )
            guard let output, let image = output.sdrImage else { return nil }
            return MenuBarCapture(
                image: image,
                windowFrame: stripFrame,
                scale: CGFloat(image.width) / stripFrame.width
            )
        } catch {
            return nil
        }
    }
}
