import AppKit

// Private CoreGraphics (SkyLight) symbols. They have been stable since macOS 10.x
// and are used by every menu bar manager; keep the surface as small as possible.

private typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetWindowCount")
private func CGSGetWindowCount(_ cid: CGSConnectionID, _ targetCID: CGSConnectionID, _ outCount: inout Int32) -> CGError

@_silgen_name("CGSGetProcessMenuBarWindowList")
private func CGSGetProcessMenuBarWindowList(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ count: Int32,
    _ list: UnsafeMutablePointer<CGWindowID>,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetScreenRectForWindow")
private func CGSGetScreenRectForWindow(_ cid: CGSConnectionID, _ wid: CGWindowID, _ outRect: inout CGRect) -> CGError

@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ key: CFString,
    _ value: CFTypeRef
) -> CGError

/// A window in the menu bar that hosts a status item.
struct StatusWindow: Hashable, Sendable {
    let windowID: CGWindowID
    /// Frame in CoreGraphics global coordinates (origin at top-left of the primary display).
    let frame: CGRect
    let ownerPID: pid_t
    let isOnScreen: Bool
}

enum WindowServer {
    /// Status item windows of every process, including items pushed off-screen.
    static func statusWindows() -> [StatusWindow] {
        let cid = CGSMainConnectionID()
        var count: Int32 = 0
        guard CGSGetWindowCount(cid, 0, &count) == .success, count > 0 else { return [] }
        var ids = [CGWindowID](repeating: 0, count: Int(count))
        var real: Int32 = 0
        guard CGSGetProcessMenuBarWindowList(cid, 0, count, &ids, &real) == .success else { return [] }
        let list = Array(ids.prefix(Int(real)))
        return describe(list).filter { $0.layer == Int(CGWindowLevelForKey(.statusWindow)) }.map(\.window)
    }

    static func frame(of windowID: CGWindowID) -> CGRect? {
        var rect = CGRect.zero
        guard CGSGetScreenRectForWindow(CGSMainConnectionID(), windowID, &rect) == .success else { return nil }
        return rect
    }

    /// Lets the app hide the cursor while it is not frontmost (needed while moving items).
    static func allowCursorHidingInBackground() {
        let cid = CGSMainConnectionID()
        _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    /// True when a menu, or a popover attached to the menu bar, is currently open.
    static func isMenuBarInterfaceOpen(menuBarHeight: CGFloat) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else {
            return false
        }
        let popUpLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let mainMenuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Owner names are localized ("程序坞"), so identify system processes by bundle ID.
        let ignoredPIDs = Set(["com.apple.dock", "com.apple.WindowManager"].flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier)
        } + [ownPID])
        let screenSizes = NSScreen.screens.map(\.frame.size)
        for window in info {
            guard
                let layer = window[kCGWindowLayer] as? Int,
                let pid = window[kCGWindowOwnerPID] as? pid_t,
                let boundsDict = window[kCGWindowBounds] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            if ignoredPIDs.contains(pid) || screenSizes.contains(bounds.size) { continue }
            if layer == popUpLevel { return true }
            if layer <= 0 || layer == statusLevel || layer == mainMenuLevel || window[kCGWindowOwnerName] as? String == "Window Server" {
                continue
            }
            // Popovers hang directly below the menu bar.
            if bounds.minY <= menuBarHeight + 8 && bounds.height > menuBarHeight + 4 {
                return true
            }
        }
        return false
    }

    private struct Described {
        let window: StatusWindow
        let layer: Int
    }

    private static func describe(_ ids: [CGWindowID]) -> [Described] {
        guard !ids.isEmpty else { return [] }
        let pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        let array = pointers.withUnsafeBufferPointer { buffer in
            CFArrayCreate(kCFAllocatorDefault, UnsafeMutablePointer(mutating: buffer.baseAddress), ids.count, nil)
        }
        guard let array, let info = CGWindowListCreateDescriptionFromArray(array) as? [[CFString: Any]] else { return [] }
        return info.compactMap { dict in
            guard
                let id = dict[kCGWindowNumber] as? CGWindowID,
                let layer = dict[kCGWindowLayer] as? Int,
                let pid = dict[kCGWindowOwnerPID] as? pid_t,
                let boundsDict = dict[kCGWindowBounds] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            let onScreen = dict[kCGWindowIsOnscreen] as? Bool ?? false
            return Described(window: StatusWindow(windowID: id, frame: frame, ownerPID: pid, isOnScreen: onScreen), layer: layer)
        }
    }
}
