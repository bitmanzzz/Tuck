import Foundation

/// The gap macOS leaves around every menu bar item.
///
/// This is a system-wide, per-Mac setting kept by macOS, not by Tuck. Apps read
/// it when they create their items, so changes show up after logging back in.
enum ItemSpacing: Hashable {
    case standard
    case compact
    case tighter
    /// A value set outside Tuck.
    case custom(Int)

    static let presets: [ItemSpacing] = [.standard, .compact, .tighter]

    private static let spacingKey = "NSStatusItemSpacing" as CFString
    private static let paddingKey = "NSStatusItemSelectionPadding" as CFString

    /// macOS uses 16 for both values when they aren't set.
    private var value: Int? {
        switch self {
        case .standard: nil
        case .compact: 12
        case .tighter: 8
        case .custom(let value): value
        }
    }

    static var current: ItemSpacing {
        guard let value = read(spacingKey) else { return .standard }
        return presets.first { $0.value == value } ?? .custom(value)
    }

    func apply() {
        let number = value.map { $0 as CFNumber }
        for key in [Self.spacingKey, Self.paddingKey] {
            CFPreferencesSetValue(key, number, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    private static func read(_ key: CFString) -> Int? {
        CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int
    }
}
