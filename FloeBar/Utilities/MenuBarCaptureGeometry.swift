//
//  MenuBarCaptureGeometry.swift
//  FloeBar
//

import CoreGraphics

/// Screenshot dimensions are pixels; AX frames and display bounds are points.
/// Keep this conversion shared and independent of screen-recording permission.
struct MenuBarCaptureGeometry {
    let frame: CGRect
    let scale: CGFloat

    var pixelWidth: Int { max(1, Int((frame.width * scale).rounded())) }
    var pixelHeight: Int { max(1, Int((frame.height * scale).rounded())) }

    init?(frame: CGRect, scale: CGFloat) {
        guard [frame.minX, frame.minY, frame.width, frame.height, scale].allSatisfy(\.isFinite),
            frame.width > 0, frame.height > 0, scale > 0,
            frame.width * scale < CGFloat(Int.max), frame.height * scale < CGFloat(Int.max) else { return nil }
        self.frame = frame
        self.scale = scale
    }
}
