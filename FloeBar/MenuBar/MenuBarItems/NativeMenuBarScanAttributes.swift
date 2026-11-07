//
//  NativeMenuBarScanAttributes.swift
//  FloeBar
//

import ApplicationServices
import Foundation

/// Parsing shared by real AX scans and local fixtures. Structural failure is
/// never the same as a successfully enumerated empty status bar.
enum NativeMenuBarScanAttributes {
    enum ExtrasDisposition: Equatable { case empty, bar, incomplete }

    static func extras(error: AXError, value: CFTypeRef?, attributeNames: [String]? = nil) -> ExtrasDisposition {
        switch error {
        case .attributeUnsupported, .noValue:
            return .empty
        case .notImplemented:
            return attributeNames.map { $0.contains(kAXExtrasMenuBarAttribute) ? .incomplete : .empty } ?? .incomplete
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .incomplete }
            return .bar
        default:
            return .incomplete
        }
    }

    static func children(error: AXError, value: CFTypeRef?) -> [AXUIElement]? {
        guard error == .success else { return nil }
        return value as? [AXUIElement]
    }

    private static func attributeError(_ value: CFTypeRef) -> AXError? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let wrapped = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(wrapped) == .axError else { return nil }
        var error = AXError.success
        return AXValueGetValue(wrapped, .axError, &error) ? error : .failure
    }

    static func fields(error: AXError, value: CFTypeRef?, names: [String]) -> [String: CFTypeRef]? {
        guard error == .success, let values = value as? [CFTypeRef], values.count == names.count else { return nil }
        var result = [String: CFTypeRef]()
        for (name, value) in zip(names, values) {
            if let error = attributeError(value) {
                // Help/value are supplementary only. Unsupported attributes are
                // normal; failed core identity/geometry reads are not absence.
                if error == .noValue || error == .attributeUnsupported || name == kAXHelpAttribute || name == kAXValueAttribute { continue }
                return nil
            }
            result[name] = value
        }
        return result
    }

    /// Structural diagnostics only: field names/error codes, never values.
    static func failedCoreField(error: AXError, value: CFTypeRef?, names: [String]) -> (String, AXError?) {
        guard error == .success else { return ("batch", error) }
        guard let values = value as? [CFTypeRef], values.count == names.count else { return ("batch-shape", nil) }
        for (name, value) in zip(names, values) {
            if let failure = attributeError(value), failure != .noValue && failure != .attributeUnsupported,
                name != kAXHelpAttribute && name != kAXValueAttribute { return (name, failure) }
        }
        return ("core-shape", nil)
    }

    static func frame(_ fields: [String: CFTypeRef]) -> CGRect? {
        // AXSwift's existing .frame path reads AXFrame. Preserve that primary
        // representation; only unsupported/noValue falls back to position/size.
        if let value = fields["AXFrame"] {
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            let wrapped = unsafeBitCast(value, to: AXValue.self)
            guard AXValueGetType(wrapped) == .cgRect else { return nil }
            var bounds = CGRect.zero
            return AXValueGetValue(wrapped, .cgRect, &bounds) ? bounds : nil
        }
        guard let position = fields[kAXPositionAttribute], let size = fields[kAXSizeAttribute],
            CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
            AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
