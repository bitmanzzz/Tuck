import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController!
    private var settingsWindow: SettingsWindowController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowServer.allowCursorHidingInBackground()
        NSApp.mainMenu = makeMainMenu()

        let settings = Settings.shared
        controller = MenuBarController(settings: settings)
        settingsWindow = SettingsWindowController(controller: controller)
        controller.openSettings = { [weak self] tab in
            self?.settingsWindow.show(tab)
        }

        HotkeyCenter.shared.onAction = { [weak self] action in
            self?.controller.perform(action)
        }
        settings.$hotkeys
            .sink { HotkeyCenter.shared.apply($0) }
            .store(in: &cancellables)

        if !Permissions.accessibility {
            settingsWindow.show(.permissions)
        }
    }

    /// Shown while the settings window is active. Also gives text fields the
    /// standard editing shortcuts.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About Tuck"), action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit Tuck"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Tuck", action: nil, keyEquivalent: "").submenu = appMenu

        let editMenu = NSMenu(title: String(localized: "Edit"))
        editMenu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = editMenu

        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return main
    }

    @objc private func showAbout() {
        settingsWindow.show(.about)
    }

    @objc private func showSettings() {
        settingsWindow.show(.general)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show(.general)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave items stranded off-screen.
        controller.conceal()
    }
}
