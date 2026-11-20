import AppKit

/// Moves and clicks menu bar items by replaying what a user would do:
/// a ⌘-drag to rearrange, a click to open.
///
/// Move events name the item's window instead of relying on where the cursor
/// is, so items behind the notch or pushed off screen can be moved too.
@MainActor
final class ItemMover {
    /// A position next to another status item window.
    enum Destination {
        case leftOf(CGWindowID)
        case rightOf(CGWindowID)
    }

    enum MoveError: LocalizedError {
        case notMovable
        case notFound
        case unchanged
        case misplaced

        var errorDescription: String? {
            switch self {
            case .notMovable: String(localized: "This item can't be moved.")
            case .notFound: String(localized: "The item is no longer in the menu bar.")
            case .unchanged: String(localized: "macOS didn't accept the move.")
            case .misplaced: String(localized: "macOS put the item in a different spot.")
            }
        }
    }

    private(set) var isBusy = false

    func move(_ item: MenuBarItem, to destination: Destination) async throws {
        guard item.isMovable else { throw MoveError.notMovable }
        let targetID: CGWindowID
        switch destination {
        case .leftOf(let id), .rightOf(let id): targetID = id
        }
        guard let ownerPID = WindowServer.ownerPID(of: item.windowID) else { throw MoveError.notFound }

        isBusy = true
        defer { isBusy = false }

        // Where an item lands depends on where it comes from: one coming in from
        // the hidden section can end up a slot past the drop point. Check the
        // result and move it again from where it landed, which is exact.
        var moved = false
        for attempt in 0...3 {
            guard
                let start = WindowServer.frame(of: item.windowID),
                let target = WindowServer.frame(of: targetID)
            else { throw MoveError.notFound }

            let end: CGPoint
            switch destination {
            case .leftOf:
                if abs(start.maxX - target.minX) < 1 { return }
                end = CGPoint(x: target.minX, y: target.midY)
            case .rightOf:
                if abs(start.minX - target.maxX) < 1 { return }
                end = CGPoint(x: target.maxX, y: target.midY)
            }
            if attempt == 3 { break }

            await withHiddenCursor {
                // The press point only has to miss every real window; the
                // window fields decide which item picks it up.
                postMove(.leftMouseDown, at: CGPoint(x: 20_000, y: 20_000), window: item.windowID, pid: ownerPID)
                try? await Task.sleep(for: .milliseconds(100))
                postMove(.leftMouseUp, at: end, window: targetID, pid: ownerPID)
            }
            if await waitForFrameChange(of: item.windowID, from: start) {
                moved = true
                await waitForLayoutToSettle(of: [item.windowID, targetID])
            }
        }
        throw moved ? MoveError.misplaced : MoveError.unchanged
    }

    /// Opens an item's menu. Prefers the Accessibility press action, which does
    /// not touch the cursor; falls back to a synthetic click.
    func click(_ item: MenuBarItem, rightButton: Bool = false) async {
        if MenuBarHider.usesUnifiedMenuBar {
            await clickUnified(item, rightButton: rightButton)
            return
        }
        if !rightButton, let element = item.axElement, element.press() {
            return
        }
        guard let frame = WindowServer.frame(of: item.windowID), isOnScreen(frame) else { return }
        await syntheticClick(at: frame.center, rightButton: rightButton)
    }

    /// macOS 27 激活点击路径：轮询等待刚放行的图标进入可见菜单栏后，向其屏幕中心发送真实左键/右键点击。
    private func clickUnified(_ item: MenuBarItem, rightButton: Bool) async {
        let candidatePIDs: [pid_t]
        if let bundleID = item.bundleID {
            let running = NSWorkspace.shared.runningApplications
            let relatedBundles = ItemScanner.relatedBundleIDs(for: bundleID, in: running)
            let pids = running.filter { !$0.isTerminated && $0.bundleIdentifier.map(relatedBundles.contains) == true }
                .map(\.processIdentifier)
            candidatePIDs = pids.isEmpty ? [item.pid] : pids
        } else {
            candidatePIDs = [item.pid]
        }

        let visibleScreens = NSScreen.screens.map(\.cgFrame)
        var freshAX: AXStatusItem?

        // 等待 MenuBarAgent 应用可见性断言并将该图标渲染到刘海右侧可见区域（最多等待约 1.2s）。
        for _ in 0..<24 {
            let found = await Task.detached { () -> AXStatusItem? in
                for pid in candidatePIDs {
                    let items = AXMenuBar.statusItems(for: pid).filter { item in
                        item.hasVisibleFrame && visibleScreens.contains { $0.contains(item.frame.center) }
                    }
                    if let first = items.first {
                        return first
                    }
                }
                return nil
            }.value
            if let found {
                freshAX = found
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let targetFrame = freshAX?.frame ?? item.frame
        if targetFrame.width > 0, isOnScreen(targetFrame) {
            await syntheticClick(at: targetFrame.center, rightButton: rightButton)
            return
        }

        if !rightButton, let element = freshAX?.element ?? item.axElement {
            element.press()
        }
    }

    /// macOS 27 在屏 ⌘-拖拽（用于同屏内调整相邻图标顺序，依赖真实屏幕坐标与渐进拖拽事件）。
    func drag(from startFrame: CGRect, to endPoint: CGPoint) async {
        guard startFrame.width > 0, isOnScreen(startFrame) else { return }
        isBusy = true
        defer { isBusy = false }

        let start = startFrame.center
        await withHiddenCursor {
            postHID(.mouseMoved, at: start, flags: [])
            try? await Task.sleep(for: .milliseconds(30))
            postHID(.mouseMoved, at: start, flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(30))
            postHID(.leftMouseDown, at: start, flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(85))

            let steps = 10
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(
                    x: start.x + (endPoint.x - start.x) * t,
                    y: start.y + (endPoint.y - start.y) * t
                )
                postHID(.leftMouseDragged, at: point, flags: .maskCommand)
                try? await Task.sleep(for: .milliseconds(16))
            }
            try? await Task.sleep(for: .milliseconds(60))
            postHID(.leftMouseUp, at: endPoint, flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(220))
        }
    }

    private func syntheticClick(at point: CGPoint, rightButton: Bool) async {
        isBusy = true
        defer { isBusy = false }
        let (down, up): (CGEventType, CGEventType) = rightButton ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        let button: CGMouseButton = rightButton ? .right : .left
        let origin = Mouse.location
        post(.mouseMoved, at: point, button: button)
        try? await Task.sleep(for: .milliseconds(35))
        post(down, at: point, button: button)
        try? await Task.sleep(for: .milliseconds(45))
        post(up, at: point, button: button)
        // 留出时间让目标应用在 mouseUp 回调里读取光标坐标以定位菜单或 Popover，然后再移回原位。
        try? await Task.sleep(for: .milliseconds(120))
        CGWarpMouseCursorPosition(origin)
    }

    private func withHiddenCursor(_ body: () async -> Void) async {
        let origin = Mouse.location
        CGDisplayHideCursor(CGMainDisplayID())
        await body()
        CGWarpMouseCursorPosition(origin)
        CGDisplayShowCursor(CGMainDisplayID())
    }

    private func waitForFrameChange(of windowID: CGWindowID, from initial: CGRect) async -> Bool {
        for _ in 0..<25 {
            if let frame = WindowServer.frame(of: windowID), frame.minX != initial.minX {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// The menu bar animates a move, and neighbours keep sliding after the moved
    /// item has landed. Wait until none of the windows has moved for a while.
    private func waitForLayoutToSettle(of windowIDs: [CGWindowID]) async {
        var last = windowIDs.map(WindowServer.frame(of:))
        var stableSamples = 0
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(30))
            let frames = windowIDs.map(WindowServer.frame(of:))
            stableSamples = frames == last ? stableSamples + 1 : 0
            if stableSamples == 3 { return }
            last = frames
        }
    }

    private func isOnScreen(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { $0.cgFrame.contains(frame.center) }
    }

    /// A ⌘-click event addressed to a status item window. Delivered both to the
    /// window's owner and to the session, which is what the menu bar needs to
    /// treat it as a drag of that item.
    private func postMove(_ type: CGEventType, at point: CGPoint, window: CGWindowID, pid: pid_t) {
        guard let event = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        event.flags = .maskCommand
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
        event.setIntegerValueField(.windowID, value: Int64(window))
        event.postToPid(pid)
        event.post(tap: .cgSessionEventTap)
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left) {
        postHID(type, at: point, button: button, flags: [])
    }

    private func postHID(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, flags: CGEventFlags) {
        guard let event = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }
        if !flags.isEmpty {
            event.flags = flags
        }
        if type == .leftMouseDown || type == .leftMouseUp || type == .rightMouseDown || type == .rightMouseUp {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event.post(tap: .cghidEventTap)
    }
}

private extension CGEventField {
    /// Undocumented field holding the event's target window.
    static let windowID = CGEventField(rawValue: 0x33)!
}

