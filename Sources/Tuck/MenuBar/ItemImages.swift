import AppKit
import ScreenCaptureKit

/// Captures images of menu bar items, including ones pushed off-screen.
/// Requires the Screen Recording permission; callers fall back to app icons.
enum ItemImages {
    static func capture(_ items: [MenuBarItem]) async -> [CGWindowID: NSImage] {
        guard Permissions.screenRecording, !items.isEmpty else { return [:] }
        if MenuBarHider.usesUnifiedMenuBar {
            return await captureUnified(items)
        }
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

    /// macOS 27 统一菜单栏截图路径：截取 MenuBarAgent 合成菜单栏窗口，再按每个在屏图标的 AX 坐标裁剪。
    private static func captureUnified(_ items: [MenuBarItem]) async -> [CGWindowID: NSImage] {
        let onScreenItems = items.filter { $0.frame.width > 0 && $0.frame.height > 0 }
        guard !onScreenItems.isEmpty else { return [:] }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
            return [:]
        }

        let menuBarWindows = content.windows.filter { window in
            let bundleID = window.owningApplication?.bundleIdentifier
            return (bundleID == "com.apple.MenuBarAgent" || window.title == "Menubar")
                && window.frame.width > 100
                && window.frame.height > 0
                && window.frame.height <= 80
        }
        guard !menuBarWindows.isEmpty else { return [:] }

        // 优先选用 MenuBarAgent 透明合成窗口，避免将桌面壁纸一并裁入。
        let sortedWindows = menuBarWindows.sorted { lhs, rhs in
            let lhsAgent = lhs.owningApplication?.bundleIdentifier == "com.apple.MenuBarAgent"
            let rhsAgent = rhs.owningApplication?.bundleIdentifier == "com.apple.MenuBarAgent"
            if lhsAgent != rhsAgent { return lhsAgent }
            return lhs.frame.width > rhs.frame.width
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var images: [CGWindowID: NSImage] = [:]
        var capturedWindowStrips: [CGWindowID: (CGRect, CGImage)] = [:]

        for item in onScreenItems {
            guard let hostWindow = sortedWindows.first(where: { $0.frame.contains(item.frame.center) }) else {
                continue
            }
            let strip: (CGRect, CGImage)
            if let cached = capturedWindowStrips[hostWindow.windowID] {
                strip = cached
            } else {
                let filter = SCContentFilter(desktopIndependentWindow: hostWindow)
                let config = SCStreamConfiguration()
                config.width = Int(hostWindow.frame.width * scale)
                config.height = Int(hostWindow.frame.height * scale)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                config.captureResolution = .best
                guard let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
                    continue
                }
                let entry = (hostWindow.frame, cgImage)
                capturedWindowStrips[hostWindow.windowID] = entry
                strip = entry
            }

            let (hostFrame, stripImage) = strip
            let scaleX = CGFloat(stripImage.width) / max(hostFrame.width, 1)
            let scaleY = CGFloat(stripImage.height) / max(hostFrame.height, 1)
            let cropRect = CGRect(
                x: (item.frame.minX - hostFrame.minX) * scaleX,
                y: (item.frame.minY - hostFrame.minY) * scaleY,
                width: item.frame.width * scaleX,
                height: item.frame.height * scaleY
            ).integral.intersection(CGRect(x: 0, y: 0, width: stripImage.width, height: stripImage.height))

            guard cropRect.width > 2, cropRect.height > 2, let cropped = stripImage.cropping(to: cropRect) else {
                continue
            }
            // 若裁剪结果四角完全不透明，说明截到了实心背景而非透明菜单栏图标，跳过以回退至高清 App 图标。
            guard hasTransparentBackground(cropped) else { continue }

            let image = NSImage(cgImage: cropped, size: item.frame.size)
            switch analyze(cropped) {
            case .blank:
                continue
            case .monochrome:
                image.isTemplate = true
                images[item.windowID] = image
            case .color:
                images[item.windowID] = image
            }
        }
        return images
    }

    private static func hasTransparentBackground(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        let corners = [
            0,
            (width - 1) * 4,
            ((height - 1) * width) * 4,
            ((height - 1) * width + (width - 1)) * 4,
        ]
        return corners.contains { pixels[$0 + 3] < 200 }
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
