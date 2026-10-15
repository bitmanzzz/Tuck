import AppKit
import Carbon.HIToolbox

struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    /// Carbon modifier flags (cmdKey, optionKey, ...).
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        // Require a modifier, except for function keys.
        let isFunctionKey = Self.functionKeys[Int(event.keyCode)] != nil
        guard carbon & ~UInt32(shiftKey) != 0 || isFunctionKey else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon)
    }

    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyName
    }

    private var keyName: String {
        if let name = Self.functionKeys[Int(keyCode)] { return name }
        guard
            let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]
}

enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case toggleHidden
    case toggleAlwaysHidden
    case toggleBar

    var id: String { rawValue }
}

/// Global hotkeys through Carbon, which needs no extra permission.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var onAction: ((HotkeyAction) -> Void)?

    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private let signature: OSType = 0x5455_434B // "TUCK"

    func apply(_ combos: [HotkeyAction: KeyCombo]) {
        installHandlerIfNeeded()
        for ref in refs.values {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let combo = combos[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: UInt32(index))
            if RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs[action] = ref
            }
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID
            )
            guard status == noErr else { return status }
            let index = Int(hotkeyID.id)
            DispatchQueue.main.async {
                guard HotkeyAction.allCases.indices.contains(index) else { return }
                HotkeyCenter.shared.onAction?(HotkeyAction.allCases[index])
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
