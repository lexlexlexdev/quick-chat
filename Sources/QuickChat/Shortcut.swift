import AppKit
import Carbon
import SwiftUI

struct GlobalShortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    /// Reads a key event as a global shortcut. At least one of ⌘, ⌥, or ⌃ is required.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        var label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }

        let required = UInt32(controlKey | optionKey | cmdKey)
        guard (modifiers & required) != 0 else { return nil }
        guard let key = ShortcutKeyLabel.name(for: event) else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label + key)
    }
}

enum GlobalShortcutStore {
    private enum Key {
        static let keyCode = "QuickChat.shortcut.keyCode"
        static let modifiers = "QuickChat.shortcut.modifiers"
        static let label = "QuickChat.shortcut.label"
    }

    /// There is no default shortcut. A missing value means Quick Chat is only reachable from the menu bar.
    static func load() -> GlobalShortcut? {
        let defaults = UserDefaults.standard
        guard let label = defaults.string(forKey: Key.label), !label.isEmpty,
              defaults.object(forKey: Key.keyCode) != nil,
              defaults.object(forKey: Key.modifiers) != nil else { return nil }
        let keyCode = defaults.integer(forKey: Key.keyCode)
        guard (0...Int(UInt16.max)).contains(keyCode),
              let modifiers = UInt32(exactly: defaults.integer(forKey: Key.modifiers)) else { return nil }
        return GlobalShortcut(keyCode: UInt32(keyCode), modifiers: modifiers, label: label)
    }

    static func save(_ shortcut: GlobalShortcut) {
        let defaults = UserDefaults.standard
        defaults.set(Int(shortcut.keyCode), forKey: Key.keyCode)
        defaults.set(Int(shortcut.modifiers), forKey: Key.modifiers)
        defaults.set(shortcut.label, forKey: Key.label)
    }

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Key.keyCode)
        defaults.removeObject(forKey: Key.modifiers)
        defaults.removeObject(forKey: Key.label)
    }
}

@MainActor
final class ShortcutController: ObservableObject {
    @Published private(set) var shortcut: GlobalShortcut?
    @Published private(set) var error: String?

    private static let signature: OSType = 0x51434854 // 'QCHT'

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var onPress: (() -> Void)?

    /// Changes whenever the saved shortcut or its registration state changes.
    var onShortcutChange: (() -> Void)?

    var hasShortcut: Bool { shortcut != nil }

    func install(onPress: @escaping () -> Void) {
        self.onPress = onPress
        guard eventHandler == nil else { return }

        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<ShortcutController>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { controller.handlePress() }
            }
            return noErr
        }, 1, &type, pointer, &eventHandler)

        guard status == noErr else {
            eventHandler = nil
            shortcut = GlobalShortcutStore.load()
            error = "Keyboard shortcuts aren't available. Open Quick Chat from the menu bar."
            onShortcutChange?()
            return
        }
        loadSavedShortcut()
    }

    /// Saves and registers a new shortcut. A conflicting shortcut is rejected and the
    /// previously registered shortcut keeps working.
    @discardableResult
    func set(_ candidate: GlobalShortcut?) -> String? {
        guard let candidate else {
            if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
            shortcut = nil
            GlobalShortcutStore.clear()
            error = nil
            onShortcutChange?()
            return nil
        }

        if candidate == shortcut, hotKey != nil {
            error = nil
            onShortcutChange?()
            return nil
        }

        if let message = register(candidate) {
            error = message
            onShortcutChange?()
            return message
        }

        shortcut = candidate
        GlobalShortcutStore.save(candidate)
        error = nil
        onShortcutChange?()
        return nil
    }

    func deactivate() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
        onPress = nil
    }

    private func loadSavedShortcut() {
        guard let saved = GlobalShortcutStore.load() else {
            onShortcutChange?()
            return
        }
        shortcut = saved
        if let message = register(saved) {
            error = message
        }
        onShortcutChange?()
    }

    private func register(_ candidate: GlobalShortcut) -> String? {
        guard eventHandler != nil else {
            return "Keyboard shortcuts aren't available. Open Quick Chat from the menu bar."
        }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: nextID)
        nextID &+= 1
        let status = RegisterEventHotKey(candidate.keyCode, candidate.modifiers, identifier,
                                         GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            return status == eventHotKeyExistsErr
                ? "That shortcut is already in use. Choose a different combination."
                : "That shortcut is unavailable. Choose a different combination."
        }
        // The new shortcut is alive before the old one is released, so a failure above
        // never leaves the app without its previous working shortcut.
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = reference
        return nil
    }

    private func handlePress() {
        onPress?()
    }
}

enum ShortcutKeyLabel {
    static func name(for event: NSEvent) -> String? {
        if let special = specialKeys[Int(event.keyCode)] { return special }
        let characters = event.characters(byApplyingModifiers: [])
            ?? event.charactersIgnoringModifiers
            ?? ""
        guard characters.count == 1, let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !CharacterSet.whitespacesAndNewlines.contains(scalar),
              !CharacterSet.illegalCharacters.contains(scalar) else { return nil }
        return characters.uppercased()
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩",
        kVK_ANSI_KeypadEnter: "⌤",
        kVK_Tab: "⇥",
        kVK_Space: "Space",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_DownArrow: "↓",
        kVK_UpArrow: "↑",
        kVK_Home: "↖",
        kVK_End: "↘",
        kVK_PageUp: "⇞",
        kVK_PageDown: "⇟",
        kVK_Help: "Help",
        kVK_F1: "F1",
        kVK_F2: "F2",
        kVK_F3: "F3",
        kVK_F4: "F4",
        kVK_F5: "F5",
        kVK_F6: "F6",
        kVK_F7: "F7",
        kVK_F8: "F8",
        kVK_F9: "F9",
        kVK_F10: "F10",
        kVK_F11: "F11",
        kVK_F12: "F12",
        kVK_F13: "F13",
        kVK_F14: "F14",
        kVK_F15: "F15",
        kVK_F16: "F16",
        kVK_F17: "F17",
        kVK_F18: "F18",
        kVK_F19: "F19",
        kVK_F20: "F20"
    ]
}

struct ShortcutRecorder: NSViewRepresentable {
    var shortcut: GlobalShortcut?
    var onRecord: (GlobalShortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderField {
        let field = ShortcutRecorderField()
        field.shortcut = shortcut
        field.onRecord = onRecord
        return field
    }

    func updateNSView(_ field: ShortcutRecorderField, context: Context) {
        field.onRecord = onRecord
        if field.shortcut != shortcut { field.shortcut = shortcut }
    }
}

final class ShortcutRecorderField: NSTextField {
    var shortcut: GlobalShortcut? {
        didSet { refresh() }
    }
    var onRecord: ((GlobalShortcut?) -> Void)?

    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBordered = true
        alignment = .center
        font = .systemFont(ofSize: 12)
        lineBreakMode = .byTruncatingTail
        toolTip = "Click to record a shortcut"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Quick Chat shortcut")
        setAccessibilityHelp("Click, then press a combination that includes Command, Option, or Control.")
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        guard accepted else { return false }
        isRecording = true
        stringValue = "Press shortcut…"
        textColor = .labelColor
        setAccessibilityValue("Recording")
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        refresh()
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == UInt16(kVK_Escape) {
            window?.makeFirstResponder(nil)
            return
        }

        if (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)),
           !hasCommandModifier(event) {
            onRecord?(nil)
            window?.makeFirstResponder(nil)
            return
        }

        guard let candidate = GlobalShortcut(event: event) else {
            NSSound.beep()
            stringValue = "Add ⌘, ⌥, or ⌃"
            return
        }

        onRecord?(candidate)
        window?.makeFirstResponder(nil)
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        return true
    }

    private func hasCommandModifier(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
    }

    private func refresh() {
        guard !isRecording else { return }
        if let shortcut {
            stringValue = shortcut.label
            textColor = .labelColor
            setAccessibilityValue(shortcut.label)
        } else {
            stringValue = "Set shortcut"
            textColor = .secondaryLabelColor
            setAccessibilityValue("Not set")
        }
    }
}
