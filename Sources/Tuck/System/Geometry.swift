import AppKit

extension NSScreen {
    /// Height of the primary display, the pivot between Cocoa and CoreGraphics coordinates.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Screen frame in CoreGraphics global coordinates.
    var cgFrame: CGRect {
        frame.flipped
    }

    var menuBarHeight: CGFloat {
        let height = frame.maxY - visibleFrame.maxY
        return height > 0 ? max(height, NSStatusBar.system.thickness) : NSStatusBar.system.thickness
    }

    /// The menu bar strip in CoreGraphics global coordinates.
    var cgMenuBarFrame: CGRect {
        let screen = cgFrame
        return CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: menuBarHeight)
    }

    var hasNotch: Bool {
        safeAreaInsets.top > 0
    }

    /// The notch area in CoreGraphics global coordinates, if any.
    var cgNotchFrame: CGRect? {
        guard hasNotch, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        let screen = cgFrame
        return CGRect(x: left.maxX, y: screen.minY, width: right.minX - left.maxX, height: menuBarHeight)
    }
}

extension CGRect {
    /// Converts between Cocoa (bottom-left origin) and CoreGraphics (top-left origin)
    /// global coordinates. The conversion is its own inverse.
    var flipped: CGRect {
        CGRect(x: minX, y: NSScreen.primaryHeight - maxY, width: width, height: height)
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

extension CGPoint {
    var flipped: CGPoint {
        CGPoint(x: x, y: NSScreen.primaryHeight - y)
    }
}

enum Mouse {
    /// Current cursor location in CoreGraphics global coordinates.
    static var location: CGPoint {
        CGEvent(source: nil)?.location ?? NSEvent.mouseLocation.flipped
    }
}
