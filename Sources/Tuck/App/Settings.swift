import Combine
import Foundation
import ServiceManagement

enum DisplayMode: String, CaseIterable, Identifiable {
    /// Tuck Bar on screens with a notch, inline elsewhere.
    case automatic
    /// Hidden items expand inside the menu bar.
    case inline
    /// Hidden items appear in a panel below the menu bar.
    case bar

    var id: String { rawValue }
}

enum RehideStrategy: String, CaseIterable, Identifiable {
    /// Shortly after the pointer leaves the menu bar and no item menu is open.
    case smart
    /// A fixed time after the pointer leaves the menu bar.
    case timed
    /// When another app becomes active.
    case focusChange
    case never

    var id: String { rawValue }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: Keys.displayMode) }
    }
    @Published var showOnHover: Bool {
        didSet { defaults.set(showOnHover, forKey: Keys.showOnHover) }
    }
    /// Seconds the pointer must rest on the menu bar before hover shows items.
    @Published var hoverDelay: Double {
        didSet { defaults.set(hoverDelay, forKey: Keys.hoverDelay) }
    }
    @Published var showOnClick: Bool {
        didSet { defaults.set(showOnClick, forKey: Keys.showOnClick) }
    }
    @Published var showOnScroll: Bool {
        didSet { defaults.set(showOnScroll, forKey: Keys.showOnScroll) }
    }
    @Published var rehideStrategy: RehideStrategy {
        didSet { defaults.set(rehideStrategy.rawValue, forKey: Keys.rehideStrategy) }
    }
    @Published var rehideInterval: Double {
        didSet { defaults.set(rehideInterval, forKey: Keys.rehideInterval) }
    }
    @Published var alwaysHiddenEnabled: Bool {
        didSet { defaults.set(alwaysHiddenEnabled, forKey: Keys.alwaysHiddenEnabled) }
    }
    @Published var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: Keys.checkForUpdates) }
    }
    @Published var hotkeys: [HotkeyAction: KeyCombo] {
        didSet {
            let encoded = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })
            defaults.set(try? JSONEncoder().encode(encoded), forKey: Keys.hotkeys)
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Tuck: launch at login change failed: \(error)")
            }
        }
    }

    private init() {
        defaults.register(defaults: [
            Keys.displayMode: DisplayMode.automatic.rawValue,
            Keys.showOnHover: false,
            Keys.hoverDelay: 0.3,
            Keys.showOnClick: true,
            Keys.showOnScroll: false,
            Keys.rehideStrategy: RehideStrategy.smart.rawValue,
            Keys.rehideInterval: 10.0,
            Keys.alwaysHiddenEnabled: false,
            Keys.checkForUpdates: true,
        ])
        displayMode = DisplayMode(rawValue: defaults.string(forKey: Keys.displayMode) ?? "") ?? .automatic
        showOnHover = defaults.bool(forKey: Keys.showOnHover)
        hoverDelay = defaults.double(forKey: Keys.hoverDelay)
        showOnClick = defaults.bool(forKey: Keys.showOnClick)
        showOnScroll = defaults.bool(forKey: Keys.showOnScroll)
        rehideStrategy = RehideStrategy(rawValue: defaults.string(forKey: Keys.rehideStrategy) ?? "") ?? .smart
        rehideInterval = defaults.double(forKey: Keys.rehideInterval)
        alwaysHiddenEnabled = defaults.bool(forKey: Keys.alwaysHiddenEnabled)
        checkForUpdates = defaults.bool(forKey: Keys.checkForUpdates)
        if let data = defaults.data(forKey: Keys.hotkeys),
           let decoded = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            hotkeys = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                HotkeyAction(rawValue: key).map { ($0, value) }
            })
        } else {
            hotkeys = [:]
        }
    }

    private enum Keys {
        static let displayMode = "displayMode"
        static let showOnHover = "showOnHover"
        static let hoverDelay = "hoverDelay"
        static let showOnClick = "showOnClick"
        static let showOnScroll = "showOnScroll"
        static let rehideStrategy = "rehideStrategy"
        static let rehideInterval = "rehideInterval"
        static let alwaysHiddenEnabled = "alwaysHiddenEnabled"
        static let checkForUpdates = "checkForUpdates"
        static let hotkeys = "hotkeys"
    }
}
