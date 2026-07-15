import CoreGraphics
import Foundation

enum CGWindowDictionary {
    static func intValue(_ key: CFString, from window: [String: Any]) -> Int? {
        if let number = window[key as String] as? NSNumber {
            return number.intValue
        }
        return window[key as String] as? Int
    }

    static func boolValue(_ key: CFString, from window: [String: Any]) -> Bool? {
        if let number = window[key as String] as? NSNumber {
            return number.boolValue
        }
        return window[key as String] as? Bool
    }

    static func stringValue(_ key: CFString, from window: [String: Any]) -> String? {
        window[key as String] as? String
    }

    static func frame(from window: [String: Any]) -> CGRect {
        let rawBounds = window[kCGWindowBounds as String]
        if let bounds = rawBounds as? NSDictionary,
           let frame = CGRect(dictionaryRepresentation: bounds) {
            return frame
        }
        guard let bounds = rawBounds as? [String: Any] else {
            return .zero
        }
        return CGRect(
            x: doubleValue(bounds["X"]),
            y: doubleValue(bounds["Y"]),
            width: doubleValue(bounds["Width"]),
            height: doubleValue(bounds["Height"])
        )
    }

    private static func doubleValue(_ value: Any?) -> CGFloat {
        if let number = value as? NSNumber {
            return CGFloat(number.doubleValue)
        }
        if let value = value as? Double {
            return CGFloat(value)
        }
        if let value = value as? CGFloat {
            return value
        }
        return 0
    }
}
