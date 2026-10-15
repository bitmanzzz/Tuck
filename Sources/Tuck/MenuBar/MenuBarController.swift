import AppKit
import Combine
import SwiftUI

/// Owns Tuck's three status items and decides what is shown.
///
/// The menu bar is split by two dividers. Items left of the hidden divider form the
/// hidden section; items left of the always-hidden divider form the always-hidden
/// section. Collapsing a divider sets its length to 10 000 pt, which pushes every
/// item to its left off the screen.
@MainActor
final class MenuBarController: ObservableObject {
    private enum Autosave {
        static let icon = "TuckIcon"
        static let hidden = "TuckHidden"
        static let alwaysHidden = "TuckAlwaysHidden"
    }

    private static let collapsedLength: CGFloat = 10_000

    let settings: Settings
    let mover = ItemMover()

    @Published private(set) var isHiddenShown = false
    @Published private(set) var isAlwaysHiddenShown = false
    @Published private(set) var items: [MenuBarSection: [MenuBarItem]] = [:]
    @Published private(set) var images: [CGWindowID: NSImage] = [:]
    @Published private(set) var isArranging = false
    @Published var lastError: String?

    var openSettings: ((SettingsTab) -> Void)?

    private let iconItem: NSStatusItem
    private let hiddenDivider: NSStatusItem
    private var alwaysHiddenDivider: NSStatusItem?
    private let bar = TuckBarPanel()
    private var eventTap: EventTap?
    private var rehideTimer: Timer?
    private var hoverTask: Task<Void, Never>?
    private var lastActivity = Date()
    private var isTemporaryReveal = false
    private var geometry = GeometryCache()
    private var cancellables = Set<AnyCancellable>()

    init(settings: Settings) {
        self.settings = settings

        // First launch: put the icon at the far right of the app items and the
        // hidden divider directly to its left.
        Self.seedPosition(0, for: Autosave.icon)
        Self.seedPosition(1, for: Autosave.hidden)

        iconItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        iconItem.autosaveName = Autosave.icon
        hiddenDivider = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        hiddenDivider.autosaveName = Autosave.hidden

        configure(iconItem, action: #selector(iconClicked), events: [.leftMouseUp, .rightMouseUp])
        configure(hiddenDivider, action: #selector(dividerClicked), events: [.leftMouseUp])
        iconItem.button?.setAccessibilityLabel("Tuck")

        settings.$alwaysHiddenEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.setAlwaysHiddenDividerEnabled(enabled) }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in self?.frontmostAppChanged() }
            .store(in: &cancellables)

        let tap = EventTap(types: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] type, event in
            self?.handle(type, event)
        }
        tap.start()
        eventTap = tap

        // Status item windows get their real position only after the first
        // layout pass, and move whenever the user rearranges the menu bar.
        for item in [iconItem, hiddenDivider] {
            item.button?.window?.publisher(for: \.frame)
                .removeDuplicates()
                .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.apply() }
                .store(in: &cancellables)
        }

        apply()
    }

    // MARK: - Showing and hiding

    var isRevealed: Bool {
        isHiddenShown || bar.isVisible
    }

    private var usesBar: Bool {
        guard Permissions.accessibility else { return false }
        switch settings.displayMode {
        case .inline: return false
        case .bar: return true
        case .automatic: return iconScreen?.hasNotch ?? false
        }
    }

    func reveal(includeAlwaysHidden: Bool = false) {
        if usesBar {
            showBar(includeAlwaysHidden: includeAlwaysHidden)
        } else {
            showInline(includeAlwaysHidden: includeAlwaysHidden)
        }
    }

    func conceal() {
        closeBar()
        isHiddenShown = false
        isAlwaysHiddenShown = false
        isTemporaryReveal = false
        apply()
    }

    func toggle(includeAlwaysHidden: Bool = false) {
        if includeAlwaysHidden, isRevealed, !isAlwaysHiddenShown, !bar.isVisible {
            showInline(includeAlwaysHidden: true)
        } else if isRevealed {
            conceal()
        } else {
            reveal(includeAlwaysHidden: includeAlwaysHidden)
        }
    }

    func perform(_ action: HotkeyAction) {
        switch action {
        case .toggleHidden:
            toggle()
        case .toggleAlwaysHidden:
            toggle(includeAlwaysHidden: settings.alwaysHiddenEnabled)
        case .toggleBar:
            if bar.isVisible {
                closeBar()
            } else {
                showBar(includeAlwaysHidden: settings.alwaysHiddenEnabled)
            }
        }
    }

    private func showInline(includeAlwaysHidden: Bool) {
        guard iconIsRightOfDivider else {
            lastError = String(localized: "The Tuck icon must sit to the right of the divider. Hold ⌘ and drag it back.")
            openSettings?(.general)
            return
        }
        closeBar()
        isHiddenShown = true
        if includeAlwaysHidden && alwaysHiddenDivider != nil {
            isAlwaysHiddenShown = true
        }
        apply()
        lastActivity = Date()
        startRehideTimer()
        captureWhileShown()
    }

    /// Off-screen items can't be captured, so refresh their images whenever
    /// their section is on screen.
    private func captureWhileShown() {
        guard Permissions.screenRecording else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard isHiddenShown, !isArranging else { return }
            await captureKnownItems()
        }
    }

    private func captureKnownItems() async {
        let known = Array(items.values.joined())
        guard !known.isEmpty else { return }
        images.merge(await ItemImages.capture(known)) { _, new in new }
    }

    private func apply() {
        setDivider(hiddenDivider, collapsed: !isHiddenShown && iconIsRightOfDivider, image: Self.dividerImage)
        if let alwaysHiddenDivider {
            setDivider(alwaysHiddenDivider, collapsed: !isAlwaysHiddenShown, image: Self.alwaysHiddenDividerImage)
        }
        let symbol = isHiddenShown ? "chevron.right" : "chevron.left"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tuck")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        image?.isTemplate = true
        iconItem.button?.image = image
        geometry.invalidate()
    }

    private func setDivider(_ item: NSStatusItem, collapsed: Bool, image: NSImage) {
        item.length = collapsed ? Self.collapsedLength : NSStatusItem.variableLength
        item.button?.image = collapsed ? nil : image
        item.button?.cell?.isEnabled = !collapsed
        item.button?.isHighlighted = false
    }

    /// Unknown until both items have been laid out; assume the default order until then.
    private var iconIsRightOfDivider: Bool {
        guard let icon = frame(of: iconItem), let divider = frame(of: hiddenDivider) else { return true }
        return icon.minX >= divider.maxX - 1
    }

    // MARK: - Status item actions

    private func configure(_ item: NSStatusItem, action: Selector, events: NSEvent.EventTypeMask) {
        item.button?.target = self
        item.button?.action = action
        item.button?.sendAction(on: events)
    }

    @objc private func iconClicked() {
        // Accessibility presses (VoiceOver, scripts) arrive without a mouse event.
        let event = NSApp.currentEvent.flatMap { [.leftMouseUp, .rightMouseUp].contains($0.type) ? $0 : nil }
        if let event, event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
            return
        }
        let includeAlwaysHidden = (event?.modifierFlags.contains(.option) ?? false) && settings.alwaysHiddenEnabled
        toggle(includeAlwaysHidden: includeAlwaysHidden)
    }

    @objc private func dividerClicked() {
        conceal()
    }

    @objc private func alwaysHiddenDividerClicked() {
        isAlwaysHiddenShown = false
        apply()
    }

    private func showMenu() {
        let menu = NSMenu()
        let toggleTitle = isRevealed ? String(localized: "Hide Hidden Items") : String(localized: "Show Hidden Items")
        menu.addItem(withTitle: toggleTitle, action: #selector(menuToggle), keyEquivalent: "").target = self
        if settings.alwaysHiddenEnabled {
            menu.addItem(withTitle: String(localized: "Show Always-Hidden Items"), action: #selector(menuShowAlwaysHidden), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Edit Layout…"), action: #selector(menuLayout), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Tuck"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        iconItem.menu = menu
        iconItem.button?.performClick(nil)
        iconItem.menu = nil
    }

    @objc private func menuToggle() { toggle() }
    @objc private func menuShowAlwaysHidden() { showInline(includeAlwaysHidden: true) }
    @objc private func menuLayout() { openSettings?(.layout) }
    @objc private func menuSettings() { openSettings?(.general) }

    private func setAlwaysHiddenDividerEnabled(_ enabled: Bool) {
        if enabled, alwaysHiddenDivider == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = Autosave.alwaysHidden
            configure(item, action: #selector(alwaysHiddenDividerClicked), events: [.leftMouseUp])
            alwaysHiddenDivider = item
        } else if !enabled, let item = alwaysHiddenDivider {
            // Removing a status item forgets its position; keep it for next time.
            let key = "NSStatusItem Preferred Position \(Autosave.alwaysHidden)"
            let saved = UserDefaults.standard.object(forKey: key)
            NSStatusBar.system.removeStatusItem(item)
            UserDefaults.standard.set(saved, forKey: key)
            alwaysHiddenDivider = nil
            isAlwaysHiddenShown = false
        }
        apply()
    }

    // MARK: - Tuck Bar

    private func showBar(includeAlwaysHidden: Bool) {
        guard let screen = iconScreen, let anchor = iconItem.button?.window?.frame else { return }
        if isHiddenShown {
            isHiddenShown = false
            isAlwaysHiddenShown = false
            apply()
        }
        let view = TuckBarView(controller: self, includeAlwaysHidden: includeAlwaysHidden)
        bar.show(view, below: anchor, on: screen)
        Task {
            await refreshItems(captureImages: true)
            bar.fit()
        }
    }

    func closeBar() {
        bar.orderOut(nil)
    }

    /// Opens a hidden item's menu: briefly shows its section, then clicks it.
    func activate(_ item: MenuBarItem, rightClick: Bool) {
        let section = section(of: item, dividers: dividerFrames())
        closeBar()
        Task {
            isTemporaryReveal = true
            isHiddenShown = true
            if section == .alwaysHidden { isAlwaysHiddenShown = true }
            apply()
            lastActivity = Date()
            startRehideTimer()
            try? await Task.sleep(for: .milliseconds(250))
            await mover.click(item, rightButton: rightClick)
            lastActivity = Date()
        }
    }

    // MARK: - Items

    func refreshItems(captureImages: Bool) async {
        guard Permissions.accessibility, let anchor = frame(of: iconItem) else {
            items = [:]
            return
        }
        let ownFrames = [iconItem, hiddenDivider, alwaysHiddenDivider].compactMap { $0.flatMap(frame(of:)) }
        let dividers = dividerFrames()
        let scanned = await Task.detached {
            ItemScanner.scan(anchor: anchor, excluding: ownFrames)
        }.value

        var all = scanned
        if let tuck = tuckIconItem(anchor: anchor) {
            all.append(tuck)
            all.sort { $0.frame.minX < $1.frame.minX }
        }
        var grouped: [MenuBarSection: [MenuBarItem]] = [:]
        for item in all {
            grouped[section(of: item, dividers: dividers), default: []].append(item)
        }
        items = grouped

        if captureImages {
            let captured = await ItemImages.capture(all)
            images.merge(captured) { _, new in new }
        }
    }

    /// The Tuck icon as a layout item, so users can choose where it sits.
    private func tuckIconItem(anchor: CGRect) -> MenuBarItem? {
        guard let window = WindowServer.statusWindows().first(where: {
            abs($0.frame.midX - anchor.midX) < 4 && abs($0.frame.minY - anchor.minY) < 2 && abs($0.frame.width - anchor.width) < 4
        }) else { return nil }
        return MenuBarItem(
            windowID: window.windowID,
            frame: window.frame,
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleID: Bundle.main.bundleIdentifier,
            name: "Tuck",
            isMovable: true,
            axElement: nil,
            isTuck: true
        )
    }

    /// Moves an item into a section, optionally to the left of another item.
    func move(_ item: MenuBarItem, to section: MenuBarSection, before target: MenuBarItem?) async {
        guard Permissions.accessibility, !isArranging else { return }
        // The Tuck icon must stay right of the hidden divider.
        guard !item.isTuck || section == .visible else { return }
        isArranging = true
        lastError = nil
        let wasHiddenShown = isHiddenShown
        let wasAlwaysHiddenShown = isAlwaysHiddenShown
        closeBar()
        isHiddenShown = true
        isAlwaysHiddenShown = true
        apply()
        try? await Task.sleep(for: .milliseconds(350))
        await captureKnownItems()

        let destination: ItemMover.Destination?
        if let target, let frame = WindowServer.frame(of: target.windowID) {
            destination = .leftOf(frame)
        } else {
            switch section {
            case .visible:
                destination = frame(of: hiddenDivider).map { .rightOf($0) }
            case .hidden:
                destination = frame(of: hiddenDivider).map { .leftOf($0) }
            case .alwaysHidden:
                destination = (alwaysHiddenDivider.flatMap(frame(of:)) ?? frame(of: hiddenDivider)).map { .leftOf($0) }
            }
        }
        if let destination {
            do {
                try await mover.move(item, to: destination)
            } catch {
                lastError = error.localizedDescription
            }
        }

        try? await Task.sleep(for: .milliseconds(200))
        isHiddenShown = wasHiddenShown
        isAlwaysHiddenShown = wasAlwaysHiddenShown
        apply()
        isArranging = false
        try? await Task.sleep(for: .milliseconds(250))
        await refreshItems(captureImages: true)
    }

    private struct DividerFrames {
        var hidden: CGRect?
        var alwaysHidden: CGRect?
    }

    private func dividerFrames() -> DividerFrames {
        DividerFrames(hidden: frame(of: hiddenDivider), alwaysHidden: alwaysHiddenDivider.flatMap(frame(of:)))
    }

    private func section(of item: MenuBarItem, dividers: DividerFrames) -> MenuBarSection {
        if let divider = dividers.alwaysHidden, item.frame.maxX <= divider.minX + 1 {
            return .alwaysHidden
        }
        if let divider = dividers.hidden, item.frame.maxX <= divider.minX + 1 {
            return .hidden
        }
        return .visible
    }

    // MARK: - Automatic rehide

    private func startRehideTimer() {
        rehideTimer?.invalidate()
        rehideTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateRehide() }
        }
    }

    private func evaluateRehide() {
        guard isHiddenShown else {
            rehideTimer?.invalidate()
            rehideTimer = nil
            return
        }
        if mover.isBusy || isArranging {
            lastActivity = Date()
            return
        }
        let strategy: RehideStrategy = isTemporaryReveal ? .smart : settings.rehideStrategy
        let delay: TimeInterval
        switch strategy {
        case .smart: delay = 1
        case .timed: delay = settings.rehideInterval
        case .focusChange, .never: return
        }
        if let screen = iconScreen,
           screen.cgMenuBarFrame.contains(Mouse.location)
            || WindowServer.isMenuBarInterfaceOpen(menuBarHeight: screen.menuBarHeight) {
            lastActivity = Date()
            return
        }
        if Date().timeIntervalSince(lastActivity) >= delay {
            conceal()
        }
    }

    private func frontmostAppChanged() {
        geometry.invalidate()
        guard !mover.isBusy, !isArranging else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return
        }
        closeBar()
        if isHiddenShown && !isTemporaryReveal && settings.rehideStrategy == .focusChange {
            conceal()
        }
    }

    // MARK: - Pointer triggers

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        guard !mover.isBusy, !isArranging, let screen = iconScreen else { return }
        let point = event.location
        let inMenuBar = screen.cgMenuBarFrame.contains(point)
        if inMenuBar {
            lastActivity = Date()
        }

        switch type {
        case .mouseMoved:
            guard settings.showOnHover, !isRevealed, isInEmptyArea(point, on: screen) else {
                hoverTask?.cancel()
                hoverTask = nil
                return
            }
            guard hoverTask == nil else { return }
            let delay = settings.hoverDelay
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                hoverTask = nil
                if isInEmptyArea(Mouse.location, on: screen) {
                    reveal()
                }
            }

        case .leftMouseDown, .rightMouseDown:
            if bar.isVisible,
               !bar.frame.flipped.contains(point),
               !(frame(of: iconItem)?.contains(point) ?? false) {
                closeBar()
            }
            if type == .leftMouseDown, settings.showOnClick, isInEmptyArea(point, on: screen) {
                toggle()
            }

        case .scrollWheel:
            guard settings.showOnScroll, inMenuBar else { return }
            let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            if delta > 0, !isRevealed {
                reveal()
            } else if delta < 0, isRevealed {
                conceal()
            }

        default:
            break
        }
    }

    /// The empty strip between the frontmost app's menus and the first status item.
    private func isInEmptyArea(_ point: CGPoint, on screen: NSScreen) -> Bool {
        guard Permissions.accessibility, screen.cgMenuBarFrame.contains(point) else { return false }
        if let notch = screen.cgNotchFrame, notch.contains(point) { return false }
        geometry.refreshIfNeeded(screen: screen)
        guard let menusEnd = geometry.applicationMenuMaxX, let itemsStart = geometry.statusItemsMinX else { return false }
        return point.x > menusEnd + 4 && point.x < itemsStart - 2
    }

    // MARK: - Helpers

    private var iconScreen: NSScreen? {
        iconItem.button?.window?.screen ?? NSScreen.main
    }

    /// Frame of a status item's window in CoreGraphics coordinates, or nil
    /// before the menu bar has laid it out.
    private func frame(of item: NSStatusItem) -> CGRect? {
        guard let frame = item.button?.window?.frame, frame.height > 0 else { return nil }
        return frame.flipped
    }

    private static func seedPosition(_ position: CGFloat, for autosaveName: String) {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(position, forKey: key)
        }
    }

    private static let dividerImage = makeDividerImage(dashed: false)
    private static let alwaysHiddenDividerImage = makeDividerImage(dashed: true)

    private static func makeDividerImage(dashed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 6, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            if dashed {
                for y in stride(from: 1.0, to: 15.0, by: 3.5) {
                    NSBezierPath(roundedRect: NSRect(x: 2.25, y: y, width: 1.5, height: 2), xRadius: 0.75, yRadius: 0.75).fill()
                }
            } else {
                NSBezierPath(roundedRect: NSRect(x: 2.25, y: 1, width: 1.5, height: 14), xRadius: 0.75, yRadius: 0.75).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Positions in the menu bar that only change when apps or Tuck's state change.
private struct GeometryCache {
    var applicationMenuMaxX: CGFloat?
    var statusItemsMinX: CGFloat?
    private var updated = Date.distantPast

    mutating func invalidate() {
        updated = .distantPast
    }

    mutating func refreshIfNeeded(screen: NSScreen) {
        guard Date().timeIntervalSince(updated) > 1 else { return }
        updated = Date()
        applicationMenuMaxX = AXMenuBar.applicationMenuMaxX()
        let screenFrame = screen.cgFrame
        statusItemsMinX = WindowServer.statusWindows()
            .filter { abs($0.frame.minY - screenFrame.minY) < 2 && $0.frame.minX >= screenFrame.minX && $0.frame.maxX <= screenFrame.maxX }
            .map(\.frame.minX)
            .min()
    }
}
