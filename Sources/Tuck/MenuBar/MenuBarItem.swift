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
    /// 是否允许被移入“隐藏 / 始终隐藏”分区（Tuck 自身及 macOS 27 系统托管项仅支持在显示区调整顺序）。
    var canHide = true
    let axElement: AXElement?
    /// Tuck's own icon. It may move within the visible section only.
    var isTuck = false
    /// 系统内置项对应的 SF Symbol 名称（无真实截图时取代空白网格图标）。
    var systemSymbolName: String? = nil

    var id: CGWindowID { windowID }

    var application: NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
    }

    /// 优先解析外层宿主 .app 的高清图标（例如将 Lark Helper / GeminiAppLauncher 还原为宿主 App 图标）。
    var appIcon: NSImage? {
        if ItemScanner.isSystemBundle(bundleID) {
            return nil
        }
        guard let app = application else { return nil }
        if let hostURL = ItemScanner.enclosingAppURL(for: app.bundleURL) {
            return NSWorkspace.shared.icon(forFile: hostURL.path)
        }
        return app.icon
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
        "com.apple.MenuBarAgent",
        "com.apple.campo",
        "com.apple.Siri",
        "com.apple.AirPlayUIAgent",
        "com.apple.WeatherMenu",
    ]
    private static let immovableIdentifiers: Set<String> = [
        "com.apple.menuextra.clock",
        "com.apple.menuextra.controlcenter",
    ]

    /// 判断某个 Bundle ID 是否属于受 macOS 系统保护的内置菜单栏组件。
    static func isSystemBundle(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return systemBundles.contains(bundleID)
    }

    /// 返回与给定 bundleID 关联的所有运行中应用 Bundle ID（包含同一宿主 .app 下的主进程与所有 Helper/Launcher 子进程）。
    static func relatedBundleIDs(for bundleID: String, in runningApps: [NSRunningApplication]) -> Set<String> {
        var result: Set<String> = [bundleID]
        let matchingApps = runningApps.filter { $0.bundleIdentifier == bundleID }
        let hostURLs = Set(matchingApps.compactMap { enclosingAppURL(for: $0.bundleURL) ?? $0.bundleURL })

        for app in runningApps {
            guard let otherID = app.bundleIdentifier, !isSystemBundle(otherID) else { continue }
            if otherID.hasPrefix(bundleID + ".") || bundleID.hasPrefix(otherID + ".") {
                result.insert(otherID)
                continue
            }
            if let appHost = enclosingAppURL(for: app.bundleURL) ?? app.bundleURL, hostURLs.contains(appHost) {
                result.insert(otherID)
            }
        }
        return result
    }

    /// 若进程位于某个宿主 .app 包内部（如 Helper / LoginItem），返回最外层宿主 .app 的路径。
    static func enclosingAppURL(for bundleURL: URL?) -> URL? {
        guard let bundleURL else { return nil }
        let components = bundleURL.pathComponents
        guard let firstAppIndex = components.firstIndex(where: { $0.hasSuffix(".app") }),
              firstAppIndex < components.count - 1 else {
            return nil
        }
        let hostComponents = Array(components.prefix(firstAppIndex + 1))
        return NSURL.fileURL(withPathComponents: hostComponents)
    }

    /// 为第三方应用（含 Helper/Launcher）解析清晰易读的展示名称。
    static func friendlyAppName(for app: NSRunningApplication?, fallbackLabel: String?, bundleID: String?) -> String {
        if let hostURL = enclosingAppURL(for: app?.bundleURL) {
            let display = FileManager.default.displayName(atPath: hostURL.path)
                .replacingOccurrences(of: ".app", with: "")
            if !display.isEmpty {
                return display
            }
        }
        if let localized = app?.localizedName, !localized.isEmpty {
            return localized
        }
        if let fallbackLabel, !fallbackLabel.isEmpty {
            return fallbackLabel
        }
        return bundleID ?? String(localized: "Unknown")
    }

    /// 为系统内置菜单项匹配清晰的 SF Symbol，避免显示空白网格占位图标。
    static func systemSymbol(bundleID: String?, identifier: String?, label: String?) -> String? {
        guard isSystemBundle(bundleID) else { return nil }
        let hint = [identifier, label, bundleID].compactMap { $0?.lowercased() }.joined(separator: " ")
        if hint.contains("clock") || hint.contains("时钟") || hint.contains("时间") || hint.contains("日期") {
            return "clock"
        }
        if hint.contains("controlcenter") || hint.contains("control center") || hint.contains("控制中心") || hint.contains("bento") {
            return "switch.2"
        }
        if hint.contains("wifi") || hint.contains("wi-fi") || hint.contains("无线局域网") {
            return "wifi"
        }
        if hint.contains("bluetooth") || hint.contains("蓝牙") {
            return "dot.radiowaves.left.and.right"
        }
        if hint.contains("battery") || hint.contains("电池") {
            return "battery.100"
        }
        if hint.contains("sound") || hint.contains("audio") || hint.contains("声音") || hint.contains("音量") {
            return "speaker.wave.2"
        }
        if hint.contains("spotlight") || hint.contains("聚焦") {
            return "magnifyingglass"
        }
        if hint.contains("campo") || hint.contains("siri") {
            return "sparkles"
        }
        if hint.contains("textinput") || hint.contains("输入法") || hint.contains("键盘") || hint.contains("keyboard") {
            return "globe"
        }
        if hint.contains("focus") || hint.contains("专注") || hint.contains("dnd") {
            return "moon"
        }
        if hint.contains("airplay") || hint.contains("mirror") || hint.contains("隔空") || hint.contains("镜像") {
            return "rectangle.on.rectangle"
        }
        if hint.contains("nowplaying") || hint.contains("播放") {
            return "play.circle"
        }
        if hint.contains("weather") || hint.contains("天气") {
            return "cloud.sun"
        }
        return "menubar.rectangle"
    }

    /// 为 macOS 27 无独立 CGWindowID 的状态栏项生成稳定标识，确保图片缓存与列表 Diff 稳定命中。
    static func syntheticWindowID(bundleID: String?, pid: pid_t, slot: Int) -> CGWindowID {
        let key = "\(bundleID ?? "pid:\(pid)")#\(slot)"
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return CGWindowID(0x4000_0000 | (hash & 0x3FFF_FFFF))
    }

    /// macOS 27 统一菜单栏扫描路径：直接从 Accessibility（AXExtrasMenuBar）读取目标屏幕菜单栏中的所有状态项，
    /// 同时通过右边缘相对偏移量合并其他显示器的可见状态项，以及被刘海挤入溢出区的第三方应用，
    /// 确保多显示器与刘海屏环境下不会遗漏任何菜单栏应用。
    static func scanAX(
        on screenFrame: CGRect,
        menuBarHeight: CGFloat,
        otherScreenFrames: [(screenFrame: CGRect, menuBarStrip: CGRect)] = [],
        excluding ownPID: pid_t
    ) -> [MenuBarItem] {
        let allAX = AXMenuBar.statusItems(excluding: ownPID, includeOffScreen: false).filter { item in
            item.frame.width < 1000 && item.identifier != "menu-bar-overflow-indicator"
        }

        let currentStrip = CGRect(
            x: screenFrame.minX - 4,
            y: screenFrame.minY - 8,
            width: screenFrame.width + 8,
            height: menuBarHeight + 16
        )

        var onCurrentScreen: [AXStatusItem] = []
        var onOtherScreens: [(item: AXStatusItem, hostScreenFrame: CGRect)] = []
        var overflowCandidates: [AXStatusItem] = []

        for item in allAX {
            let bundleID = NSRunningApplication(processIdentifier: item.pid)?.bundleIdentifier
            if item.hasVisibleFrame {
                let center = item.frame.center
                if currentStrip.contains(center) {
                    onCurrentScreen.append(item)
                } else if let matchedOther = otherScreenFrames.first(where: { $0.menuBarStrip.contains(center) }) {
                    // 在当前显示器（如带刘海的内建屏幕）未出现、但在另一台显示器菜单栏可见的状态项。
                    onOtherScreens.append((item, matchedOther.screenFrame))
                } else if let bundleID, !isSystemBundle(bundleID) {
                    // 既不在当前屏幕菜单栏，也不在其他显示器的菜单栏内，说明被 macOS 27 移入了溢出区。
                    overflowCandidates.append(item)
                }
            }
        }

        // 若控制中心与具体应用暴露了坐标重合的代理元素，优先保留具体应用条目。
        let sortedRaw = onCurrentScreen.sorted { lhs, rhs in
            let lhsSys = isSystemBundle(NSRunningApplication(processIdentifier: lhs.pid)?.bundleIdentifier)
            let rhsSys = isSystemBundle(NSRunningApplication(processIdentifier: rhs.pid)?.bundleIdentifier)
            if lhsSys != rhsSys { return !lhsSys }
            return lhs.frame.minX < rhs.frame.minX
        }
        var deduplicated: [AXStatusItem] = []
        for candidate in sortedRaw {
            let duplicate = deduplicated.contains { existing in
                abs(existing.frame.midX - candidate.frame.midX) < 4
                    && abs(existing.frame.midY - candidate.frame.midY) < 4
            }
            if !duplicate {
                deduplicated.append(candidate)
            }
        }

        var seenBundles = Set(deduplicated.compactMap { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier })
        var seenPIDs = Set(deduplicated.map(\.pid))

        // 将在其他显示器上可见但当前屏幕被刘海裁切的图标，按距离屏幕右边缘的相对偏移量投影回当前屏幕坐标系。
        for (otherItem, hostScreenFrame) in onOtherScreens {
            let bid = NSRunningApplication(processIdentifier: otherItem.pid)?.bundleIdentifier
            if let bid, isSystemBundle(bid) { continue }
            if seenPIDs.contains(otherItem.pid) { continue }
            if let bid, seenBundles.contains(bid) { continue }
            seenPIDs.insert(otherItem.pid)
            if let bid { seenBundles.insert(bid) }

            let rightOffset = hostScreenFrame.maxX - otherItem.frame.minX
            let projectedFrame = CGRect(
                x: screenFrame.maxX - rightOffset,
                y: screenFrame.minY,
                width: otherItem.frame.width,
                height: otherItem.frame.height
            )
            deduplicated.append(AXStatusItem(
                pid: otherItem.pid,
                element: otherItem.element,
                frame: projectedFrame,
                label: otherItem.label,
                identifier: otherItem.identifier,
                isContainerOnly: otherItem.isContainerOnly
            ))
        }

        // 补充在所有屏幕上均处于溢出/无坐标状态的第三方 App，赋予菜单栏左侧虚拟坐标以自然归入隐藏区。
        for overflow in overflowCandidates {
            let bid = NSRunningApplication(processIdentifier: overflow.pid)?.bundleIdentifier
            if seenPIDs.contains(overflow.pid) { continue }
            if let bid, seenBundles.contains(bid) { continue }
            seenPIDs.insert(overflow.pid)
            if let bid { seenBundles.insert(bid) }
            let virtualFrame = CGRect(
                x: screenFrame.minX - max(overflow.frame.width, 24) - 10,
                y: screenFrame.minY,
                width: overflow.frame.width,
                height: overflow.frame.height
            )
            deduplicated.append(AXStatusItem(
                pid: overflow.pid,
                element: overflow.element,
                frame: virtualFrame,
                label: overflow.label,
                identifier: overflow.identifier,
                isContainerOnly: overflow.isContainerOnly
            ))
        }

        deduplicated.sort { $0.frame.minX < $1.frame.minX }

        var slotByKey: [String: Int] = [:]
        return deduplicated.map { ax in
            let app = NSRunningApplication(processIdentifier: ax.pid)
            let bundleID = app?.bundleIdentifier
            let isSystem = isSystemBundle(bundleID)
            let name: String
            if let bundleID, isSystem {
                let rawLabel = ax.label ?? app?.localizedName ?? bundleID
                name = rawLabel.components(separatedBy: "，").first?.components(separatedBy: ",").first ?? rawLabel
            } else {
                name = friendlyAppName(for: app, fallbackLabel: ax.label, bundleID: bundleID)
            }
            let key = bundleID ?? (isSystem ? (ax.identifier ?? "sys:\(name)") : "pid:\(ax.pid)")
            let slot = slotByKey[key, default: 0]
            slotByKey[key] = slot + 1

            // macOS 27 上仅锁定控制中心与时钟的位置；其余系统项（输入法、Wi-Fi、电池等）允许在“显示”区内调整顺序，但禁止移入隐藏区。
            let isImmovable = ax.identifier.map(immovableIdentifiers.contains) ?? false
            let isMovable = !isImmovable
            let canHide = !isSystem && bundleID != nil && !isImmovable

            return MenuBarItem(
                windowID: syntheticWindowID(bundleID: bundleID, pid: ax.pid, slot: slot),
                frame: ax.hasVisibleFrame ? ax.frame : .zero,
                pid: ax.pid,
                bundleID: bundleID,
                name: name,
                isMovable: isMovable,
                canHide: canHide,
                axElement: ax.isContainerOnly ? nil : ax.element,
                systemSymbolName: systemSymbol(bundleID: bundleID, identifier: ax.identifier, label: ax.label)
            )
        }
    }

    /// 在 macOS 27 收起状态下，为已隐藏但仍在运行的第三方 App 构造占位条目（用于 Tuck Bar 与布局编辑器展示）。
    static func placeholderItem(bundleID: String, slot: Int = 0) -> MenuBarItem? {
        guard !isSystemBundle(bundleID) else { return nil }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { !$0.isTerminated }) else {
            return nil
        }
        return MenuBarItem(
            windowID: syntheticWindowID(bundleID: bundleID, pid: app.processIdentifier, slot: slot),
            frame: .zero,
            pid: app.processIdentifier,
            bundleID: bundleID,
            name: friendlyAppName(for: app, fallbackLabel: nil, bundleID: bundleID),
            isMovable: true,
            axElement: nil
        )
    }

    /// Lists every status item in the menu bar that contains `anchor`
    /// (CoreGraphics coordinates), ordered left to right, excluding Tuck's own items.
    static func scan(anchor: CGRect, excluding ownFrames: [CGRect]) -> [MenuBarItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = row(containing: anchor, in: WindowServer.statusWindows()).filter { window in
            window.ownerPID != ownPID
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

    /// The status windows in the same menu bar as `anchor`.
    ///
    /// With several displays, every menu bar has its own copy of each item, all at
    /// the same height. Items in one menu bar sit edge to edge (a collapsed divider
    /// included), so follow the chain of touching windows outwards from the anchor.
    static func row(containing anchor: CGRect, in windows: [StatusWindow]) -> [StatusWindow] {
        let candidates = windows.filter { abs($0.frame.minY - anchor.minY) < 2 }
        guard let start = candidates.first(where: { approximatelyEqual($0.frame, anchor) }) else {
            return candidates
        }
        let tolerance: CGFloat = 6
        var row = [start]
        var used: Set<CGWindowID> = [start.windowID]
        var edge = start
        while let next = candidates.first(where: { !used.contains($0.windowID) && abs($0.frame.maxX - edge.frame.minX) < tolerance }) {
            row.append(next)
            used.insert(next.windowID)
            edge = next
        }
        edge = start
        while let next = candidates.first(where: { !used.contains($0.windowID) && abs($0.frame.minX - edge.frame.maxX) < tolerance }) {
            row.append(next)
            used.insert(next.windowID)
            edge = next
        }
        return row
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
            canHide: isMovable,
            axElement: ax?.element
        )
    }

    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.midX - b.midX) < 4 && abs(a.width - b.width) < 4
    }
}
