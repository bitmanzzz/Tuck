import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController!
    private var settingsWindow: SettingsWindowController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowServer.allowCursorHidingInBackground()

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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show(.general)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave items stranded off-screen.
        controller.conceal()
    }
}
