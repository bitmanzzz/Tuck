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
                    ItemTile(item: item, image: controller.images[item.windowID], height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let modifiers = NSEvent.modifierFlags
                            controller.activate(item, rightClick: modifiers.contains(.option) || modifiers.contains(.control))
                        }
                        .help(item.name)
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

/// An item's captured image, or its app icon when no capture is available.
struct ItemTile: View {
    let item: MenuBarItem
    let image: NSImage?
    let height: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: image.size.width * height / max(image.size.height, 1), height: height)
            } else if let icon = item.application?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: height - 4, height: height - 4)
                    .padding(.horizontal, 6)
            } else {
                Text(String(item.name.prefix(2)))
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .frame(height: height)
            }
        }
        .padding(.vertical, 2)
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
