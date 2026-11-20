import AppKit
import SwiftUI

/// A panel below the menu bar that lists hidden items. Essential on screens with
/// a notch, where there is no room to expand hidden items inline.
@MainActor
final class TuckBarPanel: NSPanel {
    private var anchor: CGRect = .zero
    private weak var targetScreen: NSScreen?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// - Parameter anchor: Frame of the Tuck icon in Cocoa coordinates.
    func show<Content: View>(_ view: Content, below anchor: CGRect, on screen: NSScreen) {
        self.anchor = anchor
        self.targetScreen = screen
        contentView = FirstMouseHostingView(rootView: view)
        fit()
        orderFrontRegardless()
    }

    func reposition(below anchor: CGRect, on screen: NSScreen) {
        self.anchor = anchor
        self.targetScreen = screen
        fit()
    }

    func fit() {
        guard let contentView, let screen = targetScreen else { return }
        let size = contentView.fittingSize
        let margin: CGFloat = 6
        var x = min(anchor.maxX, screen.frame.maxX - margin) - size.width
        x = max(x, screen.frame.minX + margin)
        let y = screen.frame.maxY - screen.menuBarHeight - size.height - margin
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

/// Lets clicks land on the first try even though the panel never becomes key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct TuckBarView: View {
    @ObservedObject var controller: MenuBarController
    let includeAlwaysHidden: Bool

    private var items: [MenuBarItem] {
        var result = controller.items[.hidden] ?? []
        if includeAlwaysHidden {
            result = (controller.items[.alwaysHidden] ?? []) + result
        }
        return result
    }

    var body: some View {
        HStack(spacing: 2) {
            if items.isEmpty {
                Text("No hidden items")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            } else {
                ForEach(items) { item in
                    TuckBarItemButton(item: item, image: controller.images[item.windowID]) { rightClick in
                        controller.activate(item, rightClick: rightClick)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .background(VisualEffectBackground(material: .menu))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .fixedSize()
    }
}

/// Tuck Bar 单个隐藏图标按钮：支持悬停高亮、左键点击与鼠标右键点击，避免 SwiftUI onTapGesture 忽略右键。
private struct TuckBarItemButton: View {
    let item: MenuBarItem
    let image: NSImage?
    let onActivate: (_ rightClick: Bool) -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        ItemTile(item: item, image: image, height: 22)
            .padding(.horizontal, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                MouseClickOverlay(
                    toolTip: item.name,
                    onHoverChanged: { isHovered = $0 },
                    onPressChanged: { isPressed = $0 },
                    onClick: { rightClick in onActivate(rightClick) }
                )
            )
            .help(item.name)
    }

    private var backgroundColor: Color {
        if isPressed {
            return Color.primary.opacity(0.22)
        }
        if isHovered {
            return Color.primary.opacity(0.12)
        }
        return Color.clear
    }
}

/// 通过 AppKit NSView 接收非激活面板上的首次左键与右键点击及悬停状态。
private struct MouseClickOverlay: NSViewRepresentable {
    let toolTip: String
    let onHoverChanged: (Bool) -> Void
    let onPressChanged: (Bool) -> Void
    let onClick: (Bool) -> Void

    func makeNSView(context: Context) -> ClickCaptureView {
        let view = ClickCaptureView()
        view.toolTip = toolTip
        view.onHoverChanged = onHoverChanged
        view.onPressChanged = onPressChanged
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: ClickCaptureView, context: Context) {
        nsView.toolTip = toolTip
        nsView.onHoverChanged = onHoverChanged
        nsView.onPressChanged = onPressChanged
        nsView.onClick = onClick
    }

    final class ClickCaptureView: NSView {
        var onHoverChanged: ((Bool) -> Void)?
        var onPressChanged: ((Bool) -> Void)?
        var onClick: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChanged?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChanged?(false)
            onPressChanged?(false)
        }

        override func mouseDown(with event: NSEvent) {
            onPressChanged?(true)
        }

        override func mouseUp(with event: NSEvent) {
            onPressChanged?(false)
            let local = convert(event.locationInWindow, from: nil)
            guard bounds.contains(local) else { return }
            let rightClick = event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control)
            onClick?(rightClick)
        }

        override func rightMouseDown(with event: NSEvent) {
            onPressChanged?(true)
        }

        override func rightMouseUp(with event: NSEvent) {
            onPressChanged?(false)
            let local = convert(event.locationInWindow, from: nil)
            guard bounds.contains(local) else { return }
            onClick?(true)
        }
    }
}

/// An item's captured image, or its app icon / system symbol when no capture is available.
struct ItemTile: View {
    let item: MenuBarItem
    let image: NSImage?
    let height: CGFloat
    var showLabel = false

    var body: some View {
        HStack(spacing: 5) {
            iconView
            if showLabel {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 130, alignment: .leading)
            }
        }
        .padding(.horizontal, showLabel ? 6 : 0)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var iconView: some View {
        if let image {
            Image(nsImage: image)
                .renderingMode(image.isTemplate ? .template : .original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.primary)
                .frame(width: image.size.width * height / max(image.size.height, 1), height: height)
        } else if let symbol = item.systemSymbolName {
            Image(systemName: symbol)
                .font(.system(size: height * 0.65, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: height, height: height)
        } else if let icon = item.appIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: height - 2, height: height - 2)
                .padding(.horizontal, showLabel ? 0 : 6)
        } else {
            Text(String(item.name.prefix(2)))
                .font(.caption.weight(.medium))
                .padding(.horizontal, showLabel ? 2 : 6)
                .frame(height: height)
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
