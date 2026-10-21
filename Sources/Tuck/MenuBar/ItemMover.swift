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
        guard let event = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }
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

