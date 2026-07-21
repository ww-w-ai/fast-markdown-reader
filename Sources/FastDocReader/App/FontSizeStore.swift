import CoreGraphics
import Foundation

/// Single source of truth for the reader's base font size. Pulled forward from
/// Task 7 so no code ever reads the UserDefaults key directly. Clamped to 10...36.
enum FontSizeStore {
    private static let key = "baseFontSize"
    static var size: CGFloat {
        get {
            let v = UserDefaults.standard.object(forKey: key) as? Double ?? 16
            return CGFloat(min(36, max(10, v)))
        }
        set { UserDefaults.standard.set(Double(min(36, max(10, newValue))), forKey: key) }
    }
    static let defaultSize: CGFloat = 16
    static func increase() { size = size + 1 }
    static func decrease() { size = size - 1 }
    static func reset() { size = defaultSize }
}
