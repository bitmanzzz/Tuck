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
                if let image, !isBlank(image) {
                    images[id] = image
                }
            }
        }
        return images
    }

    /// Fully transparent captures happen for items that have not drawn yet.
    private static func isBlank(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return true }
        let length = CFDataGetLength(data)
        let bytesPerPixel = max(cgImage.bitsPerPixel / 8, 1)
        let alphaOffset: Int
        switch cgImage.alphaInfo {
        case .premultipliedFirst, .first, .noneSkipFirst: alphaOffset = 0
        default: alphaOffset = bytesPerPixel - 1
        }
        var index = alphaOffset
        while index < length {
            if bytes[index] > 8 { return false }
            index += bytesPerPixel * 3
        }
        return true
    }
}
