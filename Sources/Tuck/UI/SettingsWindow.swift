import AppKit
import SwiftUI

enum SettingsTab: String, Hashable {
    case general
    case layout
    case hotkeys
    case permissions
    case about
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab = .general
}

@MainActor
final class SettingsWindowController {
    private let controller: MenuBarController
    private let navigation = SettingsNavigation()
    private var window: NSWindow?

    init(controller: MenuBarController) {
        self.controller = controller
    }

    func show(_ tab: SettingsTab) {
        navigation.tab = tab
        if window == nil {
            let view = SettingsView(controller: controller, settings: controller.settings, navigation: navigation)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = String(localized: "Tuck Settings")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var controller: MenuBarController
    @ObservedObject var settings: Settings
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralPane(controller: controller, settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            LayoutPane(controller: controller, settings: settings)
                .tabItem { Label("Layout", systemImage: "menubar.rectangle") }
                .tag(SettingsTab.layout)
            HotkeysPane(settings: settings)
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
                .tag(SettingsTab.hotkeys)
            PermissionsPane()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 640, height: 470)
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var controller: MenuBarController
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            if let error = controller.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
            }
            Section("Showing hidden items") {
                Picker("Show hidden items", selection: $settings.displayMode) {
                    Text("Automatic").tag(DisplayMode.automatic)
                    Text("In the menu bar").tag(DisplayMode.inline)
                    Text("In Tuck Bar").tag(DisplayMode.bar)
                }
                Text("Automatic uses Tuck Bar on screens with a notch, where there is no room to expand items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show when hovering over an empty part of the menu bar", isOn: $settings.showOnHover)
                Toggle("Show when clicking an empty part of the menu bar", isOn: $settings.showOnClick)
                Toggle("Show and hide by scrolling in the menu bar", isOn: $settings.showOnScroll)
            }
            Section("Hiding again") {
                Picker("Hide items again", selection: $settings.rehideStrategy) {
                    Text("When the pointer leaves the menu bar").tag(RehideStrategy.smart)
                    Text("After a set time").tag(RehideStrategy.timed)
                    Text("When switching apps").tag(RehideStrategy.focusChange)
                    Text("Never").tag(RehideStrategy.never)
                }
                if settings.rehideStrategy == .timed {
                    LabeledContent("Delay") {
                        HStack {
                            Slider(value: $settings.rehideInterval, in: 2...60, step: 1)
                            Text("\(Int(settings.rehideInterval)) s")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
            Section("Sections") {
                Toggle("Enable the always-hidden section", isOn: $settings.alwaysHiddenEnabled)
                Text("Items in this section stay hidden until you ⌥-click the Tuck icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Layout

struct LayoutPane: View {
    @ObservedObject var controller: MenuBarController
    @ObservedObject var settings: Settings

    private var sections: [MenuBarSection] {
        settings.alwaysHiddenEnabled ? [.visible, .hidden, .alwaysHidden] : [.visible, .hidden]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !Permissions.accessibility {
                PermissionNotice()
            } else {
                Text("Drag icons between the rows to rearrange your menu bar. Items in each row appear in menu bar order, left to right.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(sections) { section in
                    SectionRow(controller: controller, section: section)
                }
                HStack {
                    if let error = controller.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                    if controller.isArranging {
                        ProgressView().controlSize(.small)
                        Text("Moving…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !Permissions.screenRecording {
                        Text("Grant Screen Recording to see real icons.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Refresh") {
                        Task { await controller.refreshItems(captureImages: true) }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .task {
            await controller.refreshItems(captureImages: true)
        }
    }
}

private struct SectionRow: View {
    @ObservedObject var controller: MenuBarController
    let section: MenuBarSection
    @State private var isTargeted = false

    private var items: [MenuBarItem] {
        controller.items[section] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(items) { item in
                        tile(for: item)
                    }
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 40)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isTargeted ? 2 : 1)
            )
            .dropDestination(for: String.self) { keys, _ in
                drop(keys, before: nil)
            } isTargeted: { isTargeted = $0 }
        }
        .disabled(controller.isArranging)
    }

    @ViewBuilder
    private func tile(for item: MenuBarItem) -> some View {
        let tile = ItemTile(item: item, image: controller.images[item.windowID], height: 22)
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            .overlay {
                if item.isTuck {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .help(item.name)
            .contextMenu {
                ForEach(MenuBarSection.allCases.filter { $0 != section && !item.isTuck && (controller.settings.alwaysHiddenEnabled || $0 != .alwaysHidden) }) { target in
                    Button {
                        Task { await controller.move(item, to: target, before: nil) }
                    } label: {
                        Text("Move to \(String(localized: target.title))")
                    }
                }
            }
            .dropDestination(for: String.self) { keys, _ in
                drop(keys, before: item)
            }
        if item.isMovable {
            tile.draggable(String(item.windowID))
        } else {
            tile.opacity(0.6)
        }
    }

    private func drop(_ keys: [String], before target: MenuBarItem?) -> Bool {
        guard
            let key = keys.first,
            let windowID = CGWindowID(key),
            let item = controller.items.values.joined().first(where: { $0.windowID == windowID }),
            item.windowID != target?.windowID,
            !item.isTuck || section == .visible
        else { return false }
        Task { await controller.move(item, to: section, before: target) }
        return true
    }
}

// MARK: - Hotkeys

struct HotkeysPane: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section {
                row("Show or hide hidden items", .toggleHidden)
                row("Show or hide always-hidden items", .toggleAlwaysHidden)
                row("Show or hide Tuck Bar", .toggleBar)
            } footer: {
                Text("Click a field, then press the shortcut. Press Esc to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: LocalizedStringKey, _ action: HotkeyAction) -> some View {
        LabeledContent(title) {
            HotkeyRecorder(combo: Binding(
                get: { settings.hotkeys[action] },
                set: { settings.hotkeys[action] = $0 }
            ))
        }
    }
}

struct HotkeyRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Group {
                    if isRecording {
                        Text("Press shortcut…")
                    } else if let combo {
                        Text(verbatim: combo.displayString)
                    } else {
                        Text("Record Shortcut")
                    }
                }
                .frame(minWidth: 130)
            }
            if combo != nil, !isRecording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stop()
            } else if let recorded = KeyCombo(event: event) {
                combo = recorded
                stop()
            }
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

// MARK: - Permissions

struct PermissionsPane: View {
    @State private var accessibility = Permissions.accessibility
    @State private var screenRecording = Permissions.screenRecording
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                permissionRow(
                    title: "Accessibility",
                    detail: "Required to identify, open and rearrange other apps' menu bar items, and for hover and click triggers. Basic hiding works without it.",
                    granted: accessibility,
                    action: Permissions.requestAccessibility
                )
                permissionRow(
                    title: "Screen Recording",
                    detail: "Optional. Shows the real icons of hidden items in Tuck Bar and the layout editor. Tuck never records your screen. Without it, app icons are shown.",
                    granted: screenRecording,
                    action: Permissions.requestScreenRecording
                )
            } footer: {
                HStack {
                    Text("macOS may require a relaunch before new permissions take effect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Relaunch Tuck", action: Permissions.relaunch)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            accessibility = Permissions.accessibility
            screenRecording = Permissions.screenRecording
        }
    }

    private func permissionRow(title: LocalizedStringKey, detail: LocalizedStringKey, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Text("Granted").foregroundStyle(.secondary)
            } else {
                Button("Grant…", action: action)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PermissionNotice: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("The layout editor needs the Accessibility permission.")
            Button("Grant Accessibility…", action: Permissions.requestAccessibility)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - About

struct AboutPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Tuck").font(.largeTitle.weight(.semibold))
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("A tiny, native menu bar manager for macOS.")
                .foregroundStyle(.secondary)
            Link("github.com/bitmanzzz/Tuck", destination: URL(string: "https://github.com/bitmanzzz/Tuck")!)
                .padding(.top, 6)
            Text("Inspired by Ice by Jordan Baird.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
