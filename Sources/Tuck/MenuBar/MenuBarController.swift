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
    /// macOS 27 从 Tuck Bar 点击单个隐藏图标时，仅临时放行该 App，避免刘海屏下展开全部图标导致目标被遮挡。
    private var temporaryAllowedBundleID: String?
    private var temporaryRevealActivatedAt: Date?
    /// macOS 27 每次展开菜单栏时的物理分区快照，用于检测用户是否通过 ⌘-拖拽跨越了分隔线。
    private var expandedPhysicalSides: [String: MenuBarSection] = [:]
    /// macOS 27 后台线程查询到的 Tuck 自身状态项 AX 坐标缓存（避免在主线程同步向自身发送 AX IPC 造成死锁超时）。
    private var ownAXFrames: [String: CGRect] = [:]
    private var didBootstrapUnifiedSections = false
    private let geometry = GeometryCache()
    private var cancellables = Set<AnyCancellable>()

    init(settings: Settings) {
        self.settings = settings

        // First launch: put the icon at the far right of the app items and the
        // hidden divider directly to its left.
        Self.restoreDividerVisibilityIfNeeded(for: Autosave.hidden)
        Self.restoreDividerVisibilityIfNeeded(for: Autosave.alwaysHidden)
        Self.seedPosition(0, for: Autosave.icon)
        Self.seedPosition(1, for: Autosave.hidden)

        iconItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        iconItem.autosaveName = Autosave.icon
        hiddenDivider = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        hiddenDivider.autosaveName = Autosave.hidden

        configure(iconItem, action: #selector(iconClicked), events: [.leftMouseUp, .rightMouseUp])
        configure(hiddenDivider, action: #selector(dividerClicked), events: [.leftMouseUp])
        iconItem.button?.setAccessibilityLabel("Tuck")
        iconItem.button?.setAccessibilityIdentifier(Autosave.icon)
        hiddenDivider.button?.setAccessibilityLabel(Autosave.hidden)
        hiddenDivider.button?.setAccessibilityIdentifier(Autosave.hidden)

        settings.$alwaysHiddenEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.setAlwaysHiddenDividerEnabled(enabled) }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in self?.frontmostAppChanged() }
            .store(in: &cancellables)

        if MenuBarHider.isSupported {
            // 清理历史上误存入的系统内置项（如 Siri com.apple.campo），系统项不可被隐藏。
            let cleaned = settings.bundleSections.filter { !ItemScanner.isSystemBundle($0.key) }
            if cleaned.count != settings.bundleSections.count {
                settings.bundleSections = cleaned
            }

            // 新应用启动时同步刷新白名单，避免未被标记为隐藏的新应用被评估断言误藏。
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didLaunchApplicationNotification)
                .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self, MenuBarHider.shared.isRestricting else { return }
                    self.apply()
                }
                .store(in: &cancellables)
        }

        let tap = EventTap(types: [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .scrollWheel]) { [weak self] type, event in
            self?.handle(type, event)
        }
        tap.start()
        eventTap = tap

        // Status item windows get their real position only after the first
        // layout pass, and move whenever the user rearranges the menu bar.
        if !MenuBarHider.usesUnifiedMenuBar {
            for item in [iconItem, hiddenDivider] {
                item.button?.window?.publisher(for: \.frame)
                    .removeDuplicates()
                    .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
                    .sink { [weak self] _ in self?.apply() }
                    .store(in: &cancellables)
            }
        }

        if MenuBarHider.isSupported {
            // 启动初期先保持展开态以扫描全量菜单栏图标及分隔线真实 AX 坐标，随后自动按分隔线位置收起。
            didBootstrapUnifiedSections = false
            apply()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard let self else { return }
                if Permissions.accessibility {
                    await self.bootstrapUnifiedSectionsIfNeeded()
                } else {
                    self.waitForAccessibilityGrant()
                }
            }
        } else {
            apply()
        }
    }

    // MARK: - Showing and hiding

    var isRevealed: Bool {
        isHiddenShown || bar.isVisible || temporaryAllowedBundleID != nil
    }

    /// 退出前恢复所有图标可见性，避免 macOS 27 评估模式断言残留。
    func prepareForTermination() {
        closeBar()
        if MenuBarHider.isSupported {
            temporaryAllowedBundleID = nil
            isHiddenShown = false
            isAlwaysHiddenShown = false
            MenuBarHider.shared.showAll()
        } else {
            conceal()
        }
    }

    /// 权限状态变更（如刚授予辅助功能权限）后立即激活 macOS 27 隐藏控制与事件监听。
    func handlePermissionsGranted() {
        eventTap?.stop()
        eventTap?.start()
        guard MenuBarHider.isSupported else { return }
        Task { [weak self] in
            await self?.bootstrapUnifiedSectionsIfNeeded()
            await self?.refreshItems(captureImages: true)
        }
    }

    /// 当启动时暂未获授辅助功能权限，在后台等待用户在系统设置中开启权限，一旦授权立即自动完成初始化与隐藏。
    private func waitForAccessibilityGrant() {
        Task { [weak self] in
            while self != nil, !Task.isCancelled, !Permissions.accessibility {
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, Permissions.accessibility else { return }
            self.handlePermissionsGranted()
        }
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
        if MenuBarHider.isSupported && isHiddenShown {
            syncDividerChangesBeforeConceal()
        }
        closeBar()
        isHiddenShown = false
        isAlwaysHiddenShown = false
        isTemporaryReveal = false
        temporaryAllowedBundleID = nil
        temporaryRevealActivatedAt = nil
        expandedPhysicalSides.removeAll()
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
        if !MenuBarHider.isSupported {
            guard iconIsRightOfDivider else {
                lastError = String(localized: "The Tuck icon must sit to the right of the divider. Hold ⌘ and drag it back.")
                openSettings?(.general)
                return
            }
        }
        closeBar()
        temporaryAllowedBundleID = nil
        let wasExpanded = isHiddenShown
        isHiddenShown = true
        if includeAlwaysHidden && alwaysHiddenDivider != nil {
            isAlwaysHiddenShown = true
        }
        if MenuBarHider.isSupported {
            AXMenuBar.clearNegativeCache()
        }
        apply()
        lastActivity = Date()
        startRehideTimer()
        if MenuBarHider.isSupported && !wasExpanded {
            captureExpandedBaseline()
        }
        captureWhileShown()
    }

    /// Off-screen items can't be captured, so refresh their images whenever
    /// their section is on screen.
    private func captureWhileShown() {
        guard Permissions.screenRecording else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard isHiddenShown, !isArranging else { return }
            if MenuBarHider.isSupported {
                await refreshItems(captureImages: true)
            } else {
                await captureKnownItems()
            }
        }
    }

    private func captureKnownItems() async {
        let known = Array(items.values.joined())
        guard !known.isEmpty else { return }
        images.merge(await ItemImages.capture(known)) { _, new in new }
    }

    private func apply() {
        if MenuBarHider.isSupported {
            applyUnified()
            return
        }
        setDivider(hiddenDivider, collapsed: !isHiddenShown && iconIsRightOfDivider, image: Self.dividerImage)
        if let alwaysHiddenDivider {
            setDivider(alwaysHiddenDivider, collapsed: !isAlwaysHiddenShown, image: Self.alwaysHiddenDividerImage)
        }
        updateIconAppearance()
        geometry.invalidate()
    }

    /// macOS 27 原生状态应用：通过 MenuBarHider 白名单控制第三方图标显隐，并按需切换分隔线可见性。
    private func applyUnified() {
        updateIconAppearance()

        guard Permissions.accessibility else {
            MenuBarHider.shared.showAll()
            setUnifiedDivider(hiddenDivider, visible: true, image: Self.dividerImage)
            if let alwaysHiddenDivider {
                setUnifiedDivider(alwaysHiddenDivider, visible: true, image: Self.alwaysHiddenDividerImage)
            }
            geometry.invalidate()
            return
        }

        if let temporaryBundleID = temporaryAllowedBundleID {
            // 临时激活单个隐藏图标时，暂时只保留 Tuck 自身与目标 App（隐藏分隔线和其他第三方图标），
            // 确保就算常驻区本来已满甚至出现系统溢出（«），目标图标也能 100% 露在刘海右侧以便点击。
            setUnifiedDivider(hiddenDivider, visible: false, image: Self.dividerImage)
            if let alwaysHiddenDivider {
                setUnifiedDivider(alwaysHiddenDivider, visible: false, image: Self.alwaysHiddenDividerImage)
            }
            let runningApps = NSWorkspace.shared.runningApplications
            let allowed = ItemScanner.relatedBundleIDs(for: temporaryBundleID, in: runningApps)
            MenuBarHider.shared.restrict(toAllowedBundleIDs: allowed)
        } else if isHiddenShown {
            setUnifiedDivider(hiddenDivider, visible: true, image: Self.dividerImage)
            if let alwaysHiddenDivider {
                setUnifiedDivider(alwaysHiddenDivider, visible: isAlwaysHiddenShown, image: Self.alwaysHiddenDividerImage)
            }
            if isAlwaysHiddenShown || alwaysHiddenDivider == nil {
                MenuBarHider.shared.showAll()
            } else {
                MenuBarHider.shared.restrict(toAllowedBundleIDs: nonAlwaysHiddenBundleIDs())
            }
        } else if didBootstrapUnifiedSections {
            // 保持主分隔线可见，防止 MenuBarAgent 销毁其 Scene 并丢失 Preferred Position，同时方便用户随时按住 ⌘ 拖入隐藏区。
            setUnifiedDivider(hiddenDivider, visible: true, image: Self.dividerImage)
            if let alwaysHiddenDivider {
                setUnifiedDivider(alwaysHiddenDivider, visible: false, image: Self.alwaysHiddenDividerImage)
            }
            MenuBarHider.shared.restrict(toAllowedBundleIDs: visibleBundleIDs())
        } else {
            // 首次初始化尚未完成前保持展开，避免在未扫描前隐藏全部图标。
            MenuBarHider.shared.showAll()
            setUnifiedDivider(hiddenDivider, visible: true, image: Self.dividerImage)
            if let alwaysHiddenDivider {
                setUnifiedDivider(alwaysHiddenDivider, visible: true, image: Self.alwaysHiddenDividerImage)
            }
        }
        geometry.invalidate()
    }

    private func updateIconAppearance() {
        let symbol = (isHiddenShown || temporaryAllowedBundleID != nil) ? "chevron.right" : "chevron.left"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tuck")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        image?.isTemplate = true
        iconItem.button?.image = image
    }

    private func setDivider(_ item: NSStatusItem, collapsed: Bool, image: NSImage) {
        item.length = collapsed ? Self.collapsedLength : NSStatusItem.variableLength
        item.button?.image = collapsed ? nil : image
        item.button?.cell?.isEnabled = !collapsed
        item.button?.isHighlighted = false
    }

    private func setUnifiedDivider(_ item: NSStatusItem, visible: Bool, image: NSImage) {
        item.length = NSStatusItem.variableLength
        if let name = item.autosaveName {
            let key = "NSStatusItem Preferred Position \(name)"
            if !visible, let pos = UserDefaults.standard.object(forKey: key) {
                UserDefaults.standard.set(pos, forKey: "TuckSavedPosition_\(name)")
            } else if visible, UserDefaults.standard.object(forKey: key) == nil,
                      let saved = UserDefaults.standard.object(forKey: "TuckSavedPosition_\(name)") {
                UserDefaults.standard.set(saved, forKey: key)
            }
        }
        if item.isVisible != visible {
            item.isVisible = visible
        }
        item.button?.image = visible ? image : nil
        item.button?.cell?.isEnabled = visible
        item.button?.isHighlighted = false
    }

    /// 计算在“收起”状态下允许显示的第三方 App Bundle ID 白名单。
    ///
    /// 采用“运行中应用全集减去已标记为隐藏/始终隐藏的集合（含同一 .app 下的关联 Helper/主进程）”的减法白名单语义，
    /// 确保无论 MenuBarAgent 校验宿主还是 Helper Bundle ID 均可生效隐藏。
    private func visibleBundleIDs() -> Set<String> {
        let runningApps = NSWorkspace.shared.runningApplications
        var allowed = Set(runningApps.compactMap(\.bundleIdentifier))
        for (bundleID, section) in settings.bundleSections where section != .visible {
            guard !ItemScanner.isSystemBundle(bundleID) else { continue }
            for related in ItemScanner.relatedBundleIDs(for: bundleID, in: runningApps) {
                allowed.remove(related)
            }
        }
        for (bundleID, section) in settings.bundleSections where section == .visible {
            guard !ItemScanner.isSystemBundle(bundleID) else { continue }
            for related in ItemScanner.relatedBundleIDs(for: bundleID, in: runningApps) {
                allowed.insert(related)
            }
        }
        return allowed
    }

    /// 计算在“仅展开隐藏分区（不含始终隐藏）”时允许显示的第三方 App Bundle ID 白名单。
    private func nonAlwaysHiddenBundleIDs() -> Set<String> {
        let runningApps = NSWorkspace.shared.runningApplications
        var allowed = Set(runningApps.compactMap(\.bundleIdentifier))
        for (bundleID, section) in settings.bundleSections where section == .alwaysHidden {
            guard !ItemScanner.isSystemBundle(bundleID) else { continue }
            for related in ItemScanner.relatedBundleIDs(for: bundleID, in: runningApps) {
                allowed.remove(related)
            }
        }
        for (bundleID, section) in settings.bundleSections where section != .alwaysHidden {
            guard !ItemScanner.isSystemBundle(bundleID) else { continue }
            for related in ItemScanner.relatedBundleIDs(for: bundleID, in: runningApps) {
                allowed.insert(related)
            }
        }
        return allowed
    }

    /// macOS 27 启动同步：等待状态栏稳定后，分批展开刘海溢出区中的图标，按分隔线位置将左侧第三方 App 归入“隐藏”、右侧归入“显示”。
    private func bootstrapUnifiedSectionsIfNeeded() async {
        guard MenuBarHider.isSupported, Permissions.accessibility else { return }
        guard !didBootstrapUnifiedSections else {
            apply()
            return
        }
        await discoverAllUnifiedItems(resetFromDivider: true)
    }

    /// 分批探测所有菜单栏图标（包括在带刘海屏幕上被 macOS 27 折叠进 menu-bar-overflow-indicator 的左侧图标）。
    ///
    /// 原理：macOS 27 对被折叠在原生溢出按钮（»）内的图标，查询其进程的 AXExtrasMenuBar 会返回 kAXErrorNoValue (-25212)。
    /// 通过分批临时隐藏右侧已发现的第三方应用，让左侧折叠图标逐批滑出到可见菜单栏，即可 100% 读取其真实 AX 坐标、截图及与分隔线的相对位置。
    func discoverAllUnifiedItems(resetFromDivider: Bool = false) async {
        guard MenuBarHider.isSupported, Permissions.accessibility, !isArranging else { return }
        isArranging = true
        let wasHiddenShown = isHiddenShown
        let wasAlwaysHiddenShown = isAlwaysHiddenShown
        closeBar()

        MenuBarHider.shared.showAll()
        setUnifiedDivider(hiddenDivider, visible: true, image: Self.dividerImage)
        if let alwaysHiddenDivider {
            setUnifiedDivider(alwaysHiddenDivider, visible: true, image: Self.alwaysHiddenDividerImage)
        }
        try? await Task.sleep(for: .milliseconds(320))

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var discoveredSections: [String: MenuBarSection] = [:]
        var discoveredBundles = Set<String>()

        for _ in 0..<6 {
            AXMenuBar.clearNegativeCache()
            ownAXFrames.removeAll()
            await refreshOwnAXFramesIfNeeded()

            guard let screen = iconScreen ?? NSScreen.main else { break }
            let screenFrame = screen.cgFrame
            let menuBarHeight = screen.menuBarHeight
            let otherScreens = Self.otherScreenFrames(excluding: screen)

            let scanned = await Task.detached {
                ItemScanner.scanAX(
                    on: screenFrame,
                    menuBarHeight: menuBarHeight,
                    otherScreenFrames: otherScreens,
                    excluding: ownPID
                )
            }.value

            if Permissions.screenRecording {
                let captured = await ItemImages.capture(scanned)
                images.merge(captured) { _, new in new }
            }

            let hasOverflow = await Task.detached { AXMenuBar.hasMenuBarOverflow() }.value
            let currentHiddenDivider = ownAXFrames[Autosave.hidden]
            let currentAlwaysHiddenDivider = ownAXFrames[Autosave.alwaysHidden]
            let currentIcon = ownAXFrames[Autosave.icon] ?? frame(of: iconItem)

            var newThirdPartyInWave = 0
            for item in scanned {
                guard let bundleID = item.bundleID, !ItemScanner.isSystemBundle(bundleID) else { continue }
                guard !discoveredBundles.contains(bundleID) else { continue }
                discoveredBundles.insert(bundleID)
                newThirdPartyInWave += 1

                let side: MenuBarSection
                if let alwaysDivider = currentAlwaysHiddenDivider, item.frame.maxX <= alwaysDivider.minX + 1 {
                    side = .alwaysHidden
                } else if let hiddenDiv = currentHiddenDivider {
                    side = item.frame.maxX <= hiddenDiv.minX + 1 ? .hidden : .visible
                } else if hasOverflow {
                    // 分隔线自身仍被折叠在左侧溢出区（»）内，说明当前在屏展开的所有图标均位于分隔线右侧。
                    side = .visible
                } else if let iconRect = currentIcon {
                    side = item.frame.maxX <= iconRect.minX + 1 ? .hidden : .visible
                } else {
                    side = .hidden
                }
                discoveredSections[bundleID] = side
            }

            if !hasOverflow || newThirdPartyInWave == 0 {
                break
            }

            // 仍有图标折叠在原生溢出按钮（»）内：临时隐藏已发现的第三方应用，腾出菜单栏空间让下一批左侧图标滑出。
            let runningApps = NSWorkspace.shared.runningApplications
            var nextWaveAllowed = Set(runningApps.compactMap(\.bundleIdentifier))
            for bid in discoveredBundles {
                for related in ItemScanner.relatedBundleIDs(for: bid, in: runningApps) {
                    nextWaveAllowed.remove(related)
                }
            }
            MenuBarHider.shared.restrict(toAllowedBundleIDs: nextWaveAllowed)
            try? await Task.sleep(for: .milliseconds(350))
        }

        if !discoveredSections.isEmpty {
            var updates: [String: MenuBarSection] = [:]
            for (bundleID, side) in discoveredSections {
                if resetFromDivider {
                    if settings.alwaysHiddenEnabled, settings.bundleSections[bundleID] == .alwaysHidden {
                        updates[bundleID] = .alwaysHidden
                    } else {
                        updates[bundleID] = (!settings.alwaysHiddenEnabled && side == .alwaysHidden) ? .hidden : side
                    }
                } else if settings.bundleSections[bundleID] == nil {
                    updates[bundleID] = (!settings.alwaysHiddenEnabled && side == .alwaysHidden) ? .hidden : side
                }
            }
            if !updates.isEmpty {
                settings.updateSections(updates)
            }
        }

        didBootstrapUnifiedSections = true
        isHiddenShown = wasHiddenShown
        isAlwaysHiddenShown = wasAlwaysHiddenShown
        isArranging = false
        apply()
        try? await Task.sleep(for: .milliseconds(300))
        ownAXFrames.removeAll()
        await refreshItems(captureImages: true)
    }

    /// 记录展开态刚渲染完成时的物理分区快照，用于后续判断用户是否手动 ⌘-拖过分隔线。
    private func captureExpandedBaseline() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, self.isHiddenShown, Permissions.accessibility else { return }
            await self.refreshOwnAXFramesIfNeeded()
            let snapshot = await self.scanPhysicalSections()
            self.expandedPhysicalSides = snapshot
            // 新启动且从未归类的 App，直接按它当前相对于分隔线的位置归档。
            var newAppSections: [String: MenuBarSection] = [:]
            for (bundleID, side) in snapshot where self.settings.bundleSections[bundleID] == nil {
                newAppSections[bundleID] = side
            }
            self.settings.updateSections(newAppSections)
        }
    }

    /// 收起前对比当前物理坐标与分隔线：将所有位于分隔线左侧的在屏图标或被用户拖跨分隔线的图标同步至持久化分区。
    private func syncDividerChangesBeforeConceal() {
        guard Permissions.accessibility, let screen = iconScreen ?? NSScreen.main else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let otherScreens = Self.otherScreenFrames(excluding: screen)
        let scanned = ItemScanner.scanAX(
            on: screen.cgFrame,
            menuBarHeight: screen.menuBarHeight,
            otherScreenFrames: otherScreens,
            excluding: ownPID
        )
        let dividers = dividerFrames()
        guard dividers.hidden != nil || dividers.alwaysHidden != nil else { return }

        var updates: [String: MenuBarSection] = [:]
        for item in scanned {
            guard let bundleID = item.bundleID, !ItemScanner.isSystemBundle(bundleID) else { continue }
            let currentSide = section(of: item, dividers: dividers)
            if currentSide != .visible {
                // 凡物理位置在分隔线左侧的图标，收起时一律归入隐藏/始终隐藏。
                updates[bundleID] = currentSide
            } else if let previousSide = expandedPhysicalSides[bundleID], currentSide != previousSide {
                updates[bundleID] = currentSide
            } else if settings.bundleSections[bundleID] == nil {
                updates[bundleID] = currentSide
            }
        }
        if !updates.isEmpty {
            didBootstrapUnifiedSections = true
            settings.updateSections(updates)
        }
    }

    private func scanPhysicalSections() async -> [String: MenuBarSection] {
        guard let screen = iconScreen ?? NSScreen.main else { return [:] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let screenFrame = screen.cgFrame
        let menuBarHeight = screen.menuBarHeight
        let dividers = dividerFrames()
        guard dividers.hidden != nil || dividers.alwaysHidden != nil else { return [:] }

        let otherScreens = Self.otherScreenFrames(excluding: screen)
        let scanned = await Task.detached {
            ItemScanner.scanAX(on: screenFrame, menuBarHeight: menuBarHeight, otherScreenFrames: otherScreens, excluding: ownPID)
        }.value

        var result: [String: MenuBarSection] = [:]
        for item in scanned {
            guard let bundleID = item.bundleID, !ItemScanner.isSystemBundle(bundleID) else { continue }
            result[bundleID] = section(of: item, dividers: dividers)
        }
        return result
    }

    /// Unknown until both items have been laid out; assume the default order until then.
    private var iconIsRightOfDivider: Bool {
        if MenuBarHider.isSupported && !hiddenDivider.isVisible { return true }
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
        if MenuBarHider.isSupported && !isHiddenShown {
            syncDividerChangesBeforeConceal()
            apply()
            return
        }
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
        menu.addItem(withTitle: String(localized: "Check for Updates…"), action: #selector(menuCheckForUpdates), keyEquivalent: "").target = self
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
    @objc private func menuCheckForUpdates() { Task { await Updater.shared.check(userInitiated: true) } }

    private func setAlwaysHiddenDividerEnabled(_ enabled: Bool) {
        if enabled, alwaysHiddenDivider == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = Autosave.alwaysHidden
            configure(item, action: #selector(alwaysHiddenDividerClicked), events: [.leftMouseUp])
            item.button?.setAccessibilityLabel(Autosave.alwaysHidden)
            item.button?.setAccessibilityIdentifier(Autosave.alwaysHidden)
            alwaysHiddenDivider = item
        } else if !enabled, let item = alwaysHiddenDivider {
            // Removing a status item forgets its position; keep it for next time.
            let key = "NSStatusItem Preferred Position \(Autosave.alwaysHidden)"
            let saved = UserDefaults.standard.object(forKey: key)
            NSStatusBar.system.removeStatusItem(item)
            UserDefaults.standard.set(saved, forKey: key)
            alwaysHiddenDivider = nil
            isAlwaysHiddenShown = false
            if MenuBarHider.isSupported {
                // 关闭“始终隐藏”分区后，将其中的 App 迁移至普通“隐藏”分区，避免用户无法再找到它们。
                var migrated: [String: MenuBarSection] = [:]
                for (bundleID, sec) in settings.bundleSections where sec == .alwaysHidden {
                    migrated[bundleID] = .hidden
                }
                settings.updateSections(migrated)
            }
        }
        apply()
    }

    // MARK: - Tuck Bar

    private func showBar(includeAlwaysHidden: Bool) {
        guard let screen = iconScreen, let cgAnchor = frame(of: iconItem) else { return }
        if isHiddenShown || temporaryAllowedBundleID != nil {
            isHiddenShown = false
            isAlwaysHiddenShown = false
            temporaryAllowedBundleID = nil
            apply()
        }
        let view = TuckBarView(controller: self, includeAlwaysHidden: includeAlwaysHidden)
        bar.show(view, below: cgAnchor.flipped, on: screen)
        Task {
            await refreshOwnAXFramesIfNeeded()
            await refreshItems(captureImages: true)
            guard bar.isVisible else { return }
            if let updatedAnchor = frame(of: iconItem), let updatedScreen = iconScreen {
                bar.reposition(below: updatedAnchor.flipped, on: updatedScreen)
            } else {
                bar.fit()
            }
        }
    }

    func closeBar() {
        bar.orderOut(nil)
    }

    /// Opens a hidden item's menu: briefly shows its section, then clicks it.
    func activate(_ item: MenuBarItem, rightClick: Bool) {
        let itemSection = sectionOfKnownItem(item)
        closeBar()
        Task {
            isTemporaryReveal = true
            temporaryRevealActivatedAt = Date()
            if MenuBarHider.isSupported, let bundleID = item.bundleID {
                // macOS 27 上仅临时放行被点击的单个 App，防止刘海屏下展开所有图标时目标被刘海遮挡。
                temporaryAllowedBundleID = bundleID
                AXMenuBar.clearNegativeCache()
            } else {
                isHiddenShown = true
                if itemSection == .alwaysHidden { isAlwaysHiddenShown = true }
            }
            apply()
            lastActivity = Date()
            startRehideTimer()
            if !MenuBarHider.isSupported {
                try? await Task.sleep(for: .milliseconds(250))
            } else {
                try? await Task.sleep(for: .milliseconds(120))
            }
            await mover.click(item, rightButton: rightClick)
            lastActivity = Date()
        }
    }

    // MARK: - Items

    func refreshItems(captureImages: Bool) async {
        if MenuBarHider.isSupported {
            await refreshItemsUnified(captureImages: captureImages)
            return
        }
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

    /// macOS 27 状态项刷新：合并在屏 AX 图标与已持久化的隐藏分区运行中 App。
    private func refreshItemsUnified(captureImages: Bool) async {
        guard Permissions.accessibility else {
            items = [:]
            return
        }
        await refreshOwnAXFramesIfNeeded()
        guard let screen = iconScreen ?? NSScreen.main else {
            items = [:]
            return
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let screenFrame = screen.cgFrame
        let menuBarHeight = screen.menuBarHeight

        let otherScreens = Self.otherScreenFrames(excluding: screen)
        let scanned = await Task.detached {
            ItemScanner.scanAX(on: screenFrame, menuBarHeight: menuBarHeight, otherScreenFrames: otherScreens, excluding: ownPID)
        }.value

        let dividers = DividerFrames(
            hidden: dividerFrames().hidden ?? frame(of: iconItem),
            alwaysHidden: dividerFrames().alwaysHidden
        )

        var grouped: [MenuBarSection: [MenuBarItem]] = [:]
        var seenBundles = Set<String>()
        var newAssignments: [String: MenuBarSection] = [:]

        for item in scanned {
            guard let bundleID = item.bundleID, !ItemScanner.isSystemBundle(bundleID) else {
                grouped[.visible, default: []].append(item)
                continue
            }
            seenBundles.insert(bundleID)
            let targetSection: MenuBarSection
            if let saved = settings.bundleSections[bundleID] {
                targetSection = (!settings.alwaysHiddenEnabled && saved == .alwaysHidden) ? .hidden : saved
            } else if dividers.hidden != nil || dividers.alwaysHidden != nil {
                let side = section(of: item, dividers: dividers)
                targetSection = (!settings.alwaysHiddenEnabled && side == .alwaysHidden) ? .hidden : side
                newAssignments[bundleID] = targetSection
            } else {
                targetSection = .hidden
                newAssignments[bundleID] = .hidden
            }
            grouped[targetSection, default: []].append(item)
        }

        if !newAssignments.isEmpty {
            settings.updateSections(newAssignments)
            didBootstrapUnifiedSections = true
            if !isHiddenShown, newAssignments.values.contains(where: { $0 != .visible }) {
                apply()
            }
        }

        // 将当前处于隐藏态但仍在运行的第三方 App 补充进对应分区，确保 Tuck Bar 与布局编辑器完整展示。
        let hiddenBundles = settings.bundleSections
            .filter { $0.value != .visible && !seenBundles.contains($0.key) && !ItemScanner.isSystemBundle($0.key) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        for (bundleID, savedSection) in hiddenBundles {
            guard let placeholder = ItemScanner.placeholderItem(bundleID: bundleID) else { continue }
            let targetSection = (!settings.alwaysHiddenEnabled && savedSection == .alwaysHidden) ? .hidden : savedSection
            grouped[targetSection, default: []].append(placeholder)
        }

        if let anchor = frame(of: iconItem) {
            let tuck = MenuBarItem(
                windowID: ItemScanner.syntheticWindowID(bundleID: Bundle.main.bundleIdentifier, pid: ownPID, slot: 0),
                frame: anchor,
                pid: ownPID,
                bundleID: Bundle.main.bundleIdentifier,
                name: "Tuck",
                isMovable: true,
                canHide: false,
                axElement: nil,
                isTuck: true
            )
            grouped[.visible, default: []].append(tuck)
            grouped[.visible]?.sort { lhs, rhs in
                // 将在屏项按从左到右排列，离屏/溢出项（frame.width == 0）排在最左侧。
                if lhs.frame.width == 0 && rhs.frame.width > 0 { return true }
                if lhs.frame.width > 0 && rhs.frame.width == 0 { return false }
                return lhs.frame.minX < rhs.frame.minX
            }
        }

        NSLog(
            "Tuck: unified scan found %d AX items (%d visible, %d hidden, %d alwaysHidden)",
            scanned.count,
            grouped[.visible]?.count ?? 0,
            grouped[.hidden]?.count ?? 0,
            grouped[.alwaysHidden]?.count ?? 0
        )

        items = grouped

        if captureImages {
            let captured = await ItemImages.capture(scanned)
            images.merge(captured) { _, new in new }
        }
    }

    /// The Tuck icon as a layout item, so users can choose where it sits.
    private func tuckIconItem(anchor: CGRect) -> MenuBarItem? {
        guard let window = statusWindow(at: anchor) else { return nil }
        return MenuBarItem(
            windowID: window.windowID,
            frame: window.frame,
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleID: Bundle.main.bundleIdentifier,
            name: "Tuck",
            isMovable: true,
            canHide: false,
            axElement: nil,
            isTuck: true
        )
    }

    /// Moves an item into a section, optionally to the left of another item.
    func move(_ item: MenuBarItem, to section: MenuBarSection, before target: MenuBarItem?) async {
        guard Permissions.accessibility, !isArranging else { return }
        if MenuBarHider.isSupported {
            await moveUnified(item, to: section, before: target)
            return
        }
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
        if let target {
            destination = .leftOf(target.windowID)
        } else {
            switch section {
            case .visible:
                destination = windowID(of: hiddenDivider).map { .rightOf($0) }
            case .hidden:
                destination = windowID(of: hiddenDivider).map { .leftOf($0) }
            case .alwaysHidden:
                destination = (alwaysHiddenDivider.flatMap(windowID(of:)) ?? windowID(of: hiddenDivider)).map { .leftOf($0) }
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

    /// macOS 27 布局移动：
    /// - 对可隐藏第三方应用，持久化目标分区并应用可见性断言；
    /// - 对同在“显示”区的图标（含 Tuck 自身及输入法/Wi-Fi/电池等系统图标），实时查询当前屏幕坐标并发送 ⌘-拖拽调整左右顺序。
    private func moveUnified(_ item: MenuBarItem, to section: MenuBarSection, before target: MenuBarItem?) async {
        guard item.isMovable, item.canHide || section == .visible else { return }
        isArranging = true
        lastError = nil
        closeBar()

        let previousSection: MenuBarSection
        if let bundleID = item.bundleID, item.canHide {
            previousSection = settings.bundleSections[bundleID] ?? .visible
            didBootstrapUnifiedSections = true
            settings.setSection(section, for: bundleID)
        } else {
            previousSection = .visible
        }

        if section == .visible, previousSection == .visible {
            await reorderVisibleUnifiedItem(item, before: target)
        }

        apply()
        isArranging = false
        try? await Task.sleep(for: .milliseconds(200))
        ownAXFrames.removeAll()
        await refreshItems(captureImages: true)
    }

    /// 在 macOS 27 “显示”分区内执行物理 ⌘-拖拽，支持将项目移到指定项目左侧，或拖到“显示”行末尾（第一个固定系统图标之前）。
    private func reorderVisibleUnifiedItem(_ item: MenuBarItem, before target: MenuBarItem?) async {
        await refreshOwnAXFramesIfNeeded()
        guard let screen = iconScreen ?? NSScreen.main else { return }
        let strip = screen.cgMenuBarFrame.insetBy(dx: -4, dy: -8)

        let visibleItems = items[.visible] ?? []
        // 若拖到“显示”行末尾（target == nil），自动定位到第一个固定系统图标（控制中心/时钟）之前。
        let effectiveTarget = target ?? visibleItems.first(where: { !$0.isMovable && $0.windowID != item.windowID })

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let screenFrame = screen.cgFrame
        let menuBarHeight = screen.menuBarHeight

        func liveFrame(for entry: MenuBarItem) async -> CGRect? {
            if entry.isTuck {
                await refreshOwnAXFramesIfNeeded()
                if let f = frame(of: iconItem), strip.contains(f.center) { return f }
                return nil
            }
            let freshList = await Task.detached {
                ItemScanner.scanAX(on: screenFrame, menuBarHeight: menuBarHeight, otherScreenFrames: [], excluding: ownPID)
            }.value
            if let exact = freshList.first(where: { $0.windowID == entry.windowID && $0.frame.width > 0 && strip.contains($0.frame.center) }) {
                return exact.frame
            }
            if let byBundle = freshList.first(where: { $0.bundleID == entry.bundleID && $0.name == entry.name && $0.frame.width > 0 && strip.contains($0.frame.center) }) {
                return byBundle.frame
            }
            return nil
        }

        // 限制拖拽终点不超过屏幕最左端固定系统图标（控制中心/时钟），避免越界失败。
        let minFixedX = visibleItems
            .filter { !$0.isMovable && $0.frame.width > 0 && strip.contains($0.frame.center) }
            .map(\.frame.minX)
            .min()

        for attempt in 0..<2 {
            guard let sourceFrame = await liveFrame(for: item) else {
                if attempt == 0 {
                    lastError = String(localized: "This item is currently hidden in the system overflow area («). Hide other items first to move it.")
                }
                return
            }

            let destinationPoint: CGPoint
            if let effectiveTarget {
                guard let targetFrame = await liveFrame(for: effectiveTarget) else {
                    if attempt == 0 {
                        lastError = String(localized: "The target item is currently in the system overflow area («). Hide other items first to move next to it.")
                    }
                    return
                }
                // 源项已在目标左侧且相邻则无需移动。
                if sourceFrame.maxX <= targetFrame.minX + 6, targetFrame.minX - sourceFrame.maxX < 18 {
                    return
                }
                // 向右拖时，源项离开原位后目标左侧会空出一截，落点需略微进入目标左侧区域；向左拖时停在目标左边缘内侧即可。
                let rawX: CGFloat
                if sourceFrame.midX < targetFrame.midX {
                    rawX = targetFrame.minX + min(6, targetFrame.width * 0.25)
                } else {
                    rawX = targetFrame.minX + min(2, targetFrame.width * 0.15)
                }
                let clampedX = minFixedX.map { min(rawX, $0 - 4) } ?? rawX
                destinationPoint = CGPoint(x: clampedX, y: targetFrame.midY)
            } else {
                // 没有固定系统图标可参照时，拖到所有在屏可移动图标最右侧。
                let maxVisibleX = visibleItems
                    .filter { $0.windowID != item.windowID && $0.frame.width > 0 && strip.contains($0.frame.center) }
                    .map(\.frame.maxX)
                    .max() ?? sourceFrame.maxX
                if sourceFrame.maxX >= maxVisibleX - 2 { return }
                let clampedX = minFixedX.map { min(maxVisibleX + 4, $0 - 4) } ?? (maxVisibleX + 4)
                destinationPoint = CGPoint(x: clampedX, y: sourceFrame.midY)
            }

            await mover.drag(from: sourceFrame, to: destinationPoint)
            try? await Task.sleep(for: .milliseconds(180))
        }
    }

    private struct DividerFrames {
        var hidden: CGRect?
        var alwaysHidden: CGRect?
    }

    private func dividerFrames() -> DividerFrames {
        DividerFrames(
            hidden: hiddenDivider.isVisible ? frame(of: hiddenDivider) : nil,
            alwaysHidden: (alwaysHiddenDivider?.isVisible == true) ? alwaysHiddenDivider.flatMap(frame(of:)) : nil
        )
    }

    private func sectionOfKnownItem(_ item: MenuBarItem) -> MenuBarSection {
        if MenuBarHider.isSupported, let bundleID = item.bundleID, let saved = settings.bundleSections[bundleID] {
            return saved
        }
        return section(of: item, dividers: dividerFrames())
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
        guard isHiddenShown || temporaryAllowedBundleID != nil else {
            rehideTimer?.invalidate()
            rehideTimer = nil
            return
        }
        if mover.isBusy || isArranging {
            lastActivity = Date()
            return
        }
        if let activatedAt = temporaryRevealActivatedAt, Date().timeIntervalSince(activatedAt) < 2.5 {
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
        var activePIDs = Set<pid_t>()
        if let tempBundleID = temporaryAllowedBundleID {
            let running = NSWorkspace.shared.runningApplications
            let related = ItemScanner.relatedBundleIDs(for: tempBundleID, in: running)
            activePIDs = Set(running.filter { $0.bundleIdentifier.map(related.contains) == true }.map(\.processIdentifier))
        }
        if let screen = iconScreen,
           screen.cgMenuBarFrame.contains(Mouse.location)
            || WindowServer.isMenuBarInterfaceOpen(menuBarHeight: screen.menuBarHeight, activePIDs: activePIDs) {
            lastActivity = Date()
            return
        }
        if Date().timeIntervalSince(lastActivity) >= delay {
            conceal()
        }
    }

    private func frontmostAppChanged() {
        geometry.invalidate()
        if let screen = iconScreen {
            geometry.refreshIfNeeded(screen: screen)
        }
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

        case .leftMouseUp:
            // macOS 27 上用户在菜单栏按住 ⌘ 拖动图标跨过分隔线松手后，自动同步最新分区并立即隐藏/显示。
            if MenuBarHider.isSupported, event.flags.contains(.maskCommand) {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard let self, !self.isArranging else { return }
                    await self.refreshOwnAXFramesIfNeeded()
                    self.syncDividerChangesBeforeConceal()
                    if !self.isHiddenShown {
                        self.apply()
                    }
                    await self.refreshItems(captureImages: true)
                }
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
        if MenuBarHider.usesUnifiedMenuBar, let iconFrame = frame(of: iconItem) {
            if let matched = NSScreen.screens.first(where: { $0.cgFrame.contains(iconFrame.center) }) {
                return matched
            }
            if let horizontalMatch = NSScreen.screens.first(where: {
                iconFrame.midX >= $0.cgFrame.minX && iconFrame.midX <= $0.cgFrame.maxX
            }) {
                return horizontalMatch
            }
        }
        return iconItem.button?.window?.screen ?? NSScreen.main
    }

    /// 在后台线程刷新 Tuck 自身状态项的 AX 坐标缓存（不能在主线程同步查自身 AX）。
    private func refreshOwnAXFramesIfNeeded() async {
        guard MenuBarHider.usesUnifiedMenuBar, Permissions.accessibility else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let targetScreen = iconItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let targetScreenFrame = targetScreen?.cgFrame
        let screenEntries: [(screenFrame: CGRect, strip: CGRect, isTarget: Bool)] = NSScreen.screens.map { scr in
            (scr.cgFrame, scr.cgMenuBarFrame.insetBy(dx: -4, dy: -8), scr == targetScreen)
        }
        let fetched = await Task.detached { () -> [String: CGRect] in
            var map: [String: CGRect] = [:]
            var fallbackMap: [String: CGRect] = [:]
            let rawItems = AXMenuBar.statusItems(for: ownPID).filter { $0.hasVisibleFrame }

            for item in rawItems {
                guard let matchedScreen = screenEntries.first(where: { $0.strip.contains(item.frame.center) }) else {
                    continue
                }
                let key: String?
                if item.identifier == Autosave.icon || item.label == "Tuck" || item.label == Autosave.icon {
                    key = Autosave.icon
                } else if item.identifier == Autosave.hidden || item.label == Autosave.hidden {
                    key = Autosave.hidden
                } else if item.identifier == Autosave.alwaysHidden || item.label == Autosave.alwaysHidden {
                    key = Autosave.alwaysHidden
                } else {
                    key = nil
                }
                guard let key else { continue }

                if matchedScreen.isTarget {
                    map[key] = item.frame
                } else if let targetScreenFrame {
                    let rightOffset = matchedScreen.screenFrame.maxX - item.frame.minX
                    fallbackMap[key] = CGRect(
                        x: targetScreenFrame.maxX - rightOffset,
                        y: targetScreenFrame.minY,
                        width: item.frame.width,
                        height: item.frame.height
                    )
                } else {
                    fallbackMap[key] = item.frame
                }
            }

            // 若系统未暴露自定义 identifier/label，则按水平位置回退（左为分隔线，右为 Tuck 图标）。
            if map[Autosave.icon] == nil && fallbackMap[Autosave.icon] == nil {
                let onTarget = rawItems
                    .filter { item in screenEntries.first(where: { $0.isTarget })?.strip.contains(item.frame.center) ?? false }
                    .sorted { $0.frame.minX < $1.frame.minX }
                if let last = onTarget.last {
                    map[Autosave.icon] = last.frame
                    if onTarget.count >= 2 {
                        map[Autosave.hidden] = onTarget[onTarget.count - 2].frame
                    }
                }
            }

            for (k, v) in fallbackMap where map[k] == nil {
                map[k] = v
            }
            return map
        }.value
        if !fetched.isEmpty {
            ownAXFrames.merge(fetched) { _, new in new }
        }
    }

    /// Frame of a status item's window in CoreGraphics coordinates, or nil
    /// before the menu bar has laid it out.
    private func frame(of item: NSStatusItem) -> CGRect? {
        if MenuBarHider.usesUnifiedMenuBar {
            guard item.isVisible else { return nil }
            if let key = item.autosaveName, let cached = ownAXFrames[key], cached.width > 0, cached.height > 0 {
                return cached
            }
            // _approximatedWindowFrame 在 macOS 27 上仅返回屏幕最右端默认坐标，不能用于判断分隔线位置。
            if item === iconItem, let approx = Self.approximatedFrame(of: item), approx.width > 0, approx.height > 0 {
                return approx.flipped
            }
            if let windowFrame = item.button?.window?.frame, windowFrame.height > 0, windowFrame.minY >= 0 {
                return windowFrame.flipped
            }
            return nil
        }
        guard let frame = item.button?.window?.frame, frame.height > 0 else { return nil }
        return frame.flipped
    }

    /// 调用 NSSceneStatusItem 的私有估算坐标（进程内零阻塞，返回 Cocoa 全局坐标）。
    private static func approximatedFrame(of item: NSStatusItem) -> CGRect? {
        let sel = NSSelectorFromString("_approximatedWindowFrame")
        guard item.responds(to: sel), let imp = item.method(for: sel) else { return nil }
        typealias FrameIMP = @convention(c) (AnyObject, Selector) -> CGRect
        let fn = unsafeBitCast(imp, to: FrameIMP.self)
        let rect = fn(item, sel)
        return rect.isEmpty ? nil : rect
    }

    /// The WindowServer window showing a frame in the menu bar. On macOS 26 status
    /// item windows belong to Control Center, so our own window numbers don't apply.
    private func statusWindow(at frame: CGRect) -> StatusWindow? {
        WindowServer.statusWindows().first {
            abs($0.frame.midX - frame.midX) < 4 && abs($0.frame.minY - frame.minY) < 2 && abs($0.frame.width - frame.width) < 4
        }
    }

    private func windowID(of item: NSStatusItem) -> CGWindowID? {
        frame(of: item).flatMap(statusWindow(at:))?.windowID
    }

    private static func otherScreenFrames(excluding screen: NSScreen) -> [(screenFrame: CGRect, menuBarStrip: CGRect)] {
        NSScreen.screens
            .filter { $0 != screen }
            .map { ($0.cgFrame, $0.cgMenuBarFrame.insetBy(dx: -4, dy: -8)) }
    }

    /// 恢复此前因 isVisible = false 被系统移除的分隔线位置与可见标记。
    private static func restoreDividerVisibilityIfNeeded(for autosaveName: String) {
        let posKey = "NSStatusItem Preferred Position \(autosaveName)"
        let savedKey = "TuckSavedPosition_\(autosaveName)"
        if UserDefaults.standard.object(forKey: posKey) == nil,
           let saved = UserDefaults.standard.object(forKey: savedKey) {
            UserDefaults.standard.set(saved, forKey: posKey)
        }
        UserDefaults.standard.removeObject(forKey: "NSStatusItem Visible \(autosaveName)")
        UserDefaults.standard.removeObject(forKey: "NSStatusItem VisibleCC \(autosaveName)")
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
/// Refreshed in the background so pointer handling never waits on another app.
@MainActor
private final class GeometryCache {
    private var menuMaxX: [pid_t: CGFloat] = [:]
    private(set) var statusItemsMinX: CGFloat?
    private var updated = Date.distantPast
    private var isRefreshing = false

    var applicationMenuMaxX: CGFloat? {
        NSWorkspace.shared.frontmostApplication.flatMap { menuMaxX[$0.processIdentifier] }
    }

    func invalidate() {
        updated = .distantPast
    }

    /// Estimates where Tuck's own menus end from their titles.
    private static func ownMenusMaxX(screen: NSScreen) -> CGFloat {
        let font = NSFont.menuBarFont(ofSize: 0)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let titles = NSApp.mainMenu?.items.compactMap { $0.submenu?.title } ?? []
        var x = screen.cgFrame.minX + 40 // Apple menu
        for (index, title) in titles.enumerated() {
            let name = index == 0 ? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Tuck") : title
            x += (name as NSString).size(withAttributes: [.font: index == 0 ? bold : font]).width + 22
        }
        return x
    }

    func refreshIfNeeded(screen: NSScreen) {
        guard !isRefreshing, Date().timeIntervalSince(updated) > 1 else { return }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        if pid == ProcessInfo.processInfo.processIdentifier {
            // Accessibility can't report the positions of our own menus.
            menuMaxX[pid] = Self.ownMenusMaxX(screen: screen)
        }
        isRefreshing = true
        let screenFrame = screen.cgFrame
        let menuBarHeight = screen.menuBarHeight
        let unified = MenuBarHider.usesUnifiedMenuBar
        Task {
            let (menus, items) = await Task.detached { () -> (CGFloat?, CGFloat?) in
                let menus = AXMenuBar.applicationMenuMaxX(pid: pid)
                let items: CGFloat?
                if unified {
                    items = AXMenuBar.allStatusItems()
                        .filter {
                            $0.frame.width > 0
                                && $0.frame.minY >= screenFrame.minY - 6
                                && $0.frame.minY <= screenFrame.minY + menuBarHeight + 4
                                && $0.frame.minX >= screenFrame.minX
                                && $0.frame.maxX <= screenFrame.maxX
                        }
                        .map(\.frame.minX)
                        .min()
                } else {
                    items = WindowServer.statusWindows()
                        .filter { abs($0.frame.minY - screenFrame.minY) < 2 && $0.frame.minX >= screenFrame.minX && $0.frame.maxX <= screenFrame.maxX }
                        .map(\.frame.minX)
                        .min()
                }
                return (menus, items)
            }.value
            // Keep the last known value if an app is briefly unresponsive.
            if let menus, pid != ProcessInfo.processInfo.processIdentifier { menuMaxX[pid] = menus }
            statusItemsMinX = items
            updated = Date()
            isRefreshing = false
        }
    }
}
