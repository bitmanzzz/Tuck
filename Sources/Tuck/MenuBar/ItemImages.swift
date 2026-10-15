import AppKit
import ScreenCaptureKit

/// Captures images of menu bar items, including ones pushed off-screen.
/// Requires the Screen Recording permission; callers fall back to app icons.
enum ItemImages {
    static func capture(_ items: [MenuBarItem]) async -> [CGWindowID: NSImage] {
        guard Permissions.screenRecording, !items.isEmpty else { return [:] }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
            return [:]
        }
        let windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let scale = NSScreen.main?.backingScaleFactor ?? 2

        var images: [CGWindowID: NSImage] = [:]
        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for item in items {
                guard let window = windows[item.windowID] else { continue }
                group.addTask {
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let config = SCStreamConfiguration()
                    config.width = Int(window.frame.width * scale)
                    config.height = Int(window.frame.height * scale)
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    config.captureResolution = .best
                    guard let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
                        return (item.windowID, nil)
                    }
                    return (item.windowID, NSImage(cgImage: cgImage, size: window.frame.size))
                }
            }
            for await (id, image) in group {
                guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                switch analyze(cgImage) {
                case .blank:
                    continue
                case .monochrome:
                    // Menu bar glyphs are drawn white or black to suit the menu bar,
                    // which can be invisible elsewhere. Let the UI tint them instead.
                    image.isTemplate = true
                    images[id] = image
                case .color:
                    images[id] = image
                }
            }
        }
        return images
    }

    private enum Content {
        case blank, monochrome, color
    }

    private static func analyze(_ image: CGImage) -> Content {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return .blank }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return .blank }

        var visible = 0
        var colorful = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            guard alpha > 40 else { continue }
            visible += 1
            // Un-premultiply before measuring how far the channels spread apart.
            let r = Int(pixels[index]) * 255 / alpha
            let g = Int(pixels[index + 1]) * 255 / alpha
            let b = Int(pixels[index + 2]) * 255 / alpha
            if max(r, g, b) - min(r, g, b) > 48 {
                colorful += 1
            }
        }
        if visible == 0 { return .blank }
        return colorful * 20 > visible ? .color : .monochrome
    }
}
