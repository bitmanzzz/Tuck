import AppKit

enum MenuBarSection: String, CaseIterable, Identifiable {
    case visible
    case hidden
    case alwaysHidden

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .visible: "Visible"
        case .hidden: "Hidden"
        case .alwaysHidden: "Always Hidden"
        }
    }
}

struct MenuBarItem: Identifiable, Hashable {
    let windowID: CGWindowID
    /// Frame in CoreGraphics global coordinates at scan time.
    let frame: CGRect
    let pid: pid_t
    let bundleID: String?
    let name: String
    let isMovable: Bool
    let axElement: AXElement?
    /// Tuck's own icon. It may move within the visible section only.
    var isTuck = false

    var id: CGWindowID { windowID }

    var application: NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.windowID == rhs.windowID && lhs.frame == rhs.frame
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }
}

enum ItemScanner {
    private static let systemBundles: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.apple.TextInputMenuAgent",
        "com.apple.Spotlight",
    ]
    private static let immovableIdentifiers: Set<String> = [
        "com.apple.menuextra.clock",
        "com.apple.menuextra.controlcenter",
    ]

    /// Lists every status item in the menu bar that contains `anchor`
    /// (CoreGraphics coordinates), ordered left to right, excluding Tuck's own items.
    static func scan(anchor: CGRect, excluding ownFrames: [CGRect]) -> [MenuBarItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = WindowServer.statusWindows().filter { window in
            abs(window.frame.minY - anchor.minY) < 2
                && window.ownerPID != ownPID
                // Collapsed dividers (Tuck's or another manager's) are thousands of points wide.
                && window.frame.width < 1000
                && !ownFrames.contains { approximatelyEqual($0, window.frame) }
        }
        let axItems = AXMenuBar.statusItems(excluding: ownPID)

        var used = Set<Int>()
        return windows
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { window in
                let match = axItems.indices
                    .filter { !used.contains($0) }
                    .filter { abs(axItems[$0].frame.midY - window.frame.midY) < 12 }
                    .filter { axItems[$0].frame.midX >= window.frame.minX - 2 && axItems[$0].frame.midX <= window.frame.maxX + 2 }
                    .min { abs(axItems[$0].frame.midX - window.frame.midX) < abs(axItems[$1].frame.midX - window.frame.midX) }
                if let match { used.insert(match) }
                return makeItem(window: window, ax: match.map { axItems[$0] })
            }
    }

    private static func makeItem(window: StatusWindow, ax: AXStatusItem?) -> MenuBarItem {
        let pid = ax?.pid ?? window.ownerPID
        let app = NSRunningApplication(processIdentifier: pid)
        let bundleID = app?.bundleIdentifier
        let appName = app?.localizedName
        let name: String
        if ax == nil, bundleID == "com.apple.controlcenter" {
            // On macOS 26 Control Center hosts every item, so the window owner
            // says nothing about an item that has no Accessibility match.
            name = String(localized: "Unknown")
        } else if let bundleID, systemBundles.contains(bundleID) {
            name = ax?.label ?? appName ?? bundleID
        } else {
            name = appName ?? ax?.label ?? String(localized: "Unknown")
        }
        let isMovable = !(ax?.identifier.map(immovableIdentifiers.contains) ?? false)
        return MenuBarItem(
            windowID: window.windowID,
            frame: window.frame,
            pid: pid,
            bundleID: bundleID,
            name: name,
            isMovable: isMovable,
            axElement: ax?.element
        )
    }

    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.midX - b.midX) < 4 && abs(a.width - b.width) < 4
    }
}
