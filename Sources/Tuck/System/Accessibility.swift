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
}

enum AXMenuBar {
    /// Status items ("menu extras") of every running app.
    ///
    /// Since macOS 26 every status item window is owned by Control Center, so the
    /// Accessibility tree is the only reliable way to learn which app owns an item.
    static func statusItems(excluding excludedPID: pid_t) -> [AXStatusItem] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != excludedPID && !$0.isTerminated && !NegativeCache.contains($0.processIdentifier)
        }
        let pids = apps.map(\.processIdentifier)
        let results = UnsafeMutableBufferPointer<[AXStatusItem]>.allocate(capacity: pids.count)
        results.initialize(repeating: [])
        defer { results.deallocate() }

        DispatchQueue.concurrentPerform(iterations: pids.count) { index in
            results[index] = items(of: pids[index])
        }
        return results.flatMap { $0 }
    }

    private static func items(of pid: pid_t) -> [AXStatusItem] {
        let app = AXElement.application(pid)
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(app.raw, "AXExtrasMenuBar" as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            // Apps that answer "no status items" rarely grow one; skip them for a
            // while. Timeouts are not cached, so a busy app is retried next scan.
            if error == .noValue || error == .attributeUnsupported {
                NegativeCache.insert(pid)
            }
            return []
        }
        let bar = AXElement(raw: value as! AXUIElement)
        return bar.children.compactMap { child in
            guard let frame = child.frame, frame.width > 0, frame.height > 0 else { return nil }
            let description = child.attribute(kAXDescriptionAttribute, as: String.self)
            let title = child.attribute(kAXTitleAttribute, as: String.self)
            let label = [description, title].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            return AXStatusItem(
                pid: pid,
                element: child,
                frame: frame,
                label: label,
                identifier: child.attribute(kAXIdentifierAttribute, as: String.self)
            )
        }
    }

    /// Right edge of the frontmost app's menus, in CoreGraphics coordinates.
    static func applicationMenuMaxX() -> CGFloat? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXElement.application(app.processIdentifier, timeout: 0.1)
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
    }
}
