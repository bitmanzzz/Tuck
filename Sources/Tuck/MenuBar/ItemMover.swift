import AppKit

/// Moves and clicks menu bar items by replaying what a user would do:
/// a ⌘-drag to rearrange, a click to open.
@MainActor
final class ItemMover {
    enum Destination {
        case leftOf(CGRect)
        case rightOf(CGRect)
    }

    enum MoveError: LocalizedError {
        case notMovable
        case offScreen
        case unchanged

        var errorDescription: String? {
            switch self {
            case .notMovable: String(localized: "This item can't be moved.")
            case .offScreen: String(localized: "The item isn't visible on screen, so it can't be moved.")
            case .unchanged: String(localized: "macOS didn't accept the move.")
            }
        }
    }

    private(set) var isBusy = false

    func move(_ item: MenuBarItem, to destination: Destination) async throws {
        guard item.isMovable else { throw MoveError.notMovable }
        guard let start = WindowServer.frame(of: item.windowID), isOnScreen(start) else { throw MoveError.offScreen }

        let end: CGPoint
        switch destination {
        case .leftOf(let target): end = CGPoint(x: target.minX + 2, y: target.midY)
        case .rightOf(let target): end = CGPoint(x: target.maxX - 2, y: target.midY)
        }
        if start.contains(end) { return }

        isBusy = true
        defer { isBusy = false }

        for attempt in 1...2 {
            await withHiddenCursor {
                await drag(from: start.center, to: end)
            }
            if await waitForFrameChange(of: item.windowID, from: start) { return }
            if attempt == 2 { throw MoveError.unchanged }
        }
    }

    /// Opens an item's menu. Prefers the Accessibility press action, which does
    /// not touch the cursor; falls back to a synthetic click.
    func click(_ item: MenuBarItem, rightButton: Bool = false) async {
        if !rightButton, let element = item.axElement, element.press() {
            return
        }
        guard let frame = WindowServer.frame(of: item.windowID), isOnScreen(frame) else { return }
        isBusy = true
        defer { isBusy = false }
        let point = frame.center
        let (down, up): (CGEventType, CGEventType) = rightButton ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        let button: CGMouseButton = rightButton ? .right : .left
        let origin = Mouse.location
        post(.mouseMoved, at: point, button: button)
        try? await Task.sleep(for: .milliseconds(20))
        post(down, at: point, button: button)
        try? await Task.sleep(for: .milliseconds(30))
        post(up, at: point, button: button)
        try? await Task.sleep(for: .milliseconds(20))
        CGWarpMouseCursorPosition(origin)
    }

    private func drag(from start: CGPoint, to end: CGPoint) async {
        post(.mouseMoved, at: start)
        try? await Task.sleep(for: .milliseconds(30))
        post(.leftMouseDown, at: start, flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(80))
        let steps = 10
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            post(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(12))
        }
        try? await Task.sleep(for: .milliseconds(80))
        post(.leftMouseUp, at: end, flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(50))
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

    private func isOnScreen(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { $0.cgFrame.contains(frame.center) }
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, flags: CGEventFlags = []) {
        guard let event = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }
        event.flags = flags
        if type == .leftMouseDown || type == .leftMouseUp || type == .rightMouseDown || type == .rightMouseUp {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event.post(tap: .cghidEventTap)
    }
}
