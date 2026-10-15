import AppKit
import ScreenCaptureKit

enum Permissions {
    /// Needed to identify, click and move other apps' menu bar items.
    static var accessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Optional. Needed to show real item images in Tuck Bar and the layout editor.
    static var screenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openSettings(anchor: "Privacy_Accessibility")
        }
    }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            // CGRequestScreenCaptureAccess does not always prompt on macOS 15+,
            // but touching ScreenCaptureKit registers the app in System Settings.
            SCShareableContent.getWithCompletionHandler { _, _ in }
            openSettings(anchor: "Privacy_ScreenCapture")
        }
    }

    static func openSettings(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
