import AppKit

/// AXUIElement is a thread-safe CoreFoundation type.
struct AXElement: @unchecked Sendable {
    let raw: AXUIElement

    func attribute<T>(_ name: String, as type: T.Type = T.self) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(raw, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    var children: [AXElement] {
        (attribute(kAXChildrenAttribute, as: [AXUIElement].self) ?? []).map(AXElement.init)
    }

    /// Frame in CoreGraphics global coordinates.
    var frame: CGRect? {
        guard
            let position = attribute(kAXPositionAttribute, as: AXValue.self),
            let size = attribute(kAXSizeAttribute, as: AXValue.self)
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    @discardableResult
    func press() -> Bool {
        AXUIElementPerformAction(raw, kAXPressAction as CFString) == .success
    }

    static func application(_ pid: pid_t, timeout: Float = 0.3) -> AXElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        return AXElement(raw: element)
    }
}

/// A status item as seen through the Accessibility API of its owning app.
struct AXStatusItem: Sendable {
    let pid: pid_t
    let element: AXElement
    let frame: CGRect
    let label: String?
    let identifier: String?
    /// 若该元素仅表示此进程拥有 AXExtrasMenuBar 容器，但当前无可见子项（例如位于 macOS 27 原生溢出区或被隐藏）。
    var isContainerOnly = false

    var hasVisibleFrame: Bool {
        frame.width > 0 && frame.height > 0
    }
}

enum AXMenuBar {
    /// 获取所有运行中应用的状态栏图标（排除指定 PID，默认排除 Tuck 自身）。
    ///
    /// 自 macOS 26 起状态栏窗口由控制中心托管，macOS 27 起进一步合并进 MenuBarAgent 单一窗口，
    /// 因此通过辅助功能树（AXExtrasMenuBar）查询是识别图标归属与屏幕坐标的可靠方式。
    static func statusItems(excluding excludedPID: pid_t, includeOffScreen: Bool = false) -> [AXStatusItem] {
        statusItems(excludingPID: excludedPID, includeOffScreen: includeOffScreen)
    }

    /// 获取所有运行中应用的状态栏图标（可选择不排除任何进程，用于计算整条状态栏范围）。
    static func allStatusItems() -> [AXStatusItem] {
        statusItems(excludingPID: nil, includeOffScreen: false)
    }

    /// 查询单个进程暴露的 AXExtrasMenuBar 状态栏图标列表。
    static func statusItems(for pid: pid_t, useNegativeCache: Bool = false, includeOffScreen: Bool = false) -> [AXStatusItem] {
        items(of: pid, useNegativeCache: useNegativeCache, includeOffScreen: includeOffScreen)
    }

    /// 清除无状态栏项的负缓存（在 macOS 27 解除隐藏断言后调用，避免刚恢复显示的 App 被跳过）。
    static func clearNegativeCache() {
        NegativeCache.clear()
    }

    /// 检测 macOS 27 的 MenuBarAgent 当前是否显示了原生刘海溢出指示按钮（menu-bar-overflow-indicator）。
    /// 当返回 true 时，表示仍有左侧状态栏图标被折叠在刘海溢出区中。
    static func hasMenuBarOverflow() -> Bool {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else {
            return false
        }
        return items(of: agent.processIdentifier, useNegativeCache: false, includeOffScreen: false).contains {
            $0.identifier == "menu-bar-overflow-indicator" && $0.hasVisibleFrame
        }
    }

    private static func statusItems(excludingPID: pid_t?, includeOffScreen: Bool) -> [AXStatusItem] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != excludingPID && !$0.isTerminated && !NegativeCache.contains($0.processIdentifier)
        }
        let pids = apps.map(\.processIdentifier)
        guard !pids.isEmpty else { return [] }
        let results = UnsafeMutableBufferPointer<[AXStatusItem]>.allocate(capacity: pids.count)
        results.initialize(repeating: [])
        defer { results.deallocate() }

        DispatchQueue.concurrentPerform(iterations: pids.count) { index in
            results[index] = items(of: pids[index], useNegativeCache: true, includeOffScreen: includeOffScreen)
        }
        return results.flatMap { $0 }
    }

    private static func items(of pid: pid_t, useNegativeCache: Bool, includeOffScreen: Bool) -> [AXStatusItem] {
        let app = AXElement.application(pid, timeout: 0.4)
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(app.raw, "AXExtrasMenuBar" as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            // 对不支持或无状态栏项的 App 做短时负缓存以保持扫描速度；
            // macOS 27 上被原生隐藏或位于溢出区的 App 可能临时返回 noValue，因此仅缓存 attributeUnsupported。
            if useNegativeCache {
                let shouldCache = MenuBarHider.usesUnifiedMenuBar
                    ? (error == .attributeUnsupported)
                    : (error == .noValue || error == .attributeUnsupported)
                if shouldCache {
                    NegativeCache.insert(pid)
                }
            }
            return []
        }
        let bar = AXElement(raw: value as! AXUIElement)
        let children = bar.children
        let parsed: [AXStatusItem] = children.compactMap { child in
            // MenuBarAgent 会将系统图标包裹在一层 AXGroup (AXHostingView) 内，需向下解包一层读取真实标识符与描述。
            let role = child.attribute(kAXRoleAttribute, as: String.self)
            let leaf = (role == kAXGroupRole) ? (child.children.first ?? child) : child
            let frame = leaf.frame ?? child.frame ?? .zero
            if !includeOffScreen && (frame.width <= 0 || frame.height <= 0) {
                return nil
            }
            let description = leaf.attribute(kAXDescriptionAttribute, as: String.self)
                ?? child.attribute(kAXDescriptionAttribute, as: String.self)
            let title = leaf.attribute(kAXTitleAttribute, as: String.self)
                ?? child.attribute(kAXTitleAttribute, as: String.self)
            let help = (leaf.attribute(kAXHelpAttribute, as: String.self)
                ?? child.attribute(kAXHelpAttribute, as: String.self))?
                .components(separatedBy: .newlines).first
            let label = [description, title, help]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            let identifier = leaf.attribute(kAXIdentifierAttribute, as: String.self)
                ?? child.attribute(kAXIdentifierAttribute, as: String.self)
            return AXStatusItem(
                pid: pid,
                element: leaf,
                frame: frame,
                label: label,
                identifier: identifier
            )
        }
        if !parsed.isEmpty {
            return parsed
        }
        // 某些应用在 macOS 27 原生溢出区或被隐藏时，AXExtrasMenuBar 仍存在但 children 为空；
        // 返回容器占位信号，确保布局编辑器不会丢失这些菜单栏应用。
        if includeOffScreen {
            return [AXStatusItem(pid: pid, element: bar, frame: .zero, label: nil, identifier: nil, isContainerOnly: true)]
        }
        return []
    }

    /// Right edge of an app's menus, in CoreGraphics coordinates. Call off the
    /// main thread: the app may be Tuck itself, which answers on its main thread.
    static func applicationMenuMaxX(pid: pid_t) -> CGFloat? {
        let element = AXElement.application(pid, timeout: 0.5)
        guard let bar = element.attribute(kAXMenuBarAttribute, as: AXUIElement.self) else { return nil }
        return AXElement(raw: bar).children.compactMap(\.frame).filter { $0.width > 0 }.map(\.maxX).max()
    }

    /// Remembers apps that have no status items, so scans stay fast.
    private enum NegativeCache {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var entries: [pid_t: Date] = [:]
        private static let lifetime: TimeInterval = 60

        static func contains(_ pid: pid_t) -> Bool {
            lock.withLock {
                guard let date = entries[pid] else { return false }
                if Date().timeIntervalSince(date) > lifetime {
                    entries[pid] = nil
                    return false
                }
                return true
            }
        }

        static func insert(_ pid: pid_t) {
            lock.withLock { entries[pid] = Date() }
        }

        static func clear() {
            lock.withLock { entries.removeAll() }
        }
    }
}
