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

enum ShortcutAction: CaseIterable {
    case newChat
    case continueChat

    var title: String {
        switch self {
        case .newChat: "New Chat"
        case .continueChat: "Continue Chat"
        }
    }

    fileprivate var settingsPrefix: String {
        switch self {
        case .newChat: "QuickChat.shortcut"
        case .continueChat: "QuickChat.continueShortcut"
        }
    }

    fileprivate var defaultShortcut: GlobalShortcut {
        switch self {
        case .newChat: GlobalShortcut(keyCode: UInt32(kVK_ANSI_RightBracket), modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘]")
        case .continueChat: GlobalShortcut(keyCode: UInt32(kVK_ANSI_LeftBracket), modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘[")
        }
    }
}

struct GlobalShortcutStore {
    let defaults: UserDefaults

    func load(_ action: ShortcutAction) -> GlobalShortcut? {
        let prefix = action.settingsPrefix
        if defaults.bool(forKey: prefix + ".disabled") { return nil }
        guard let label = defaults.string(forKey: prefix + ".label"), !label.isEmpty,
              let keyCode = defaults.object(forKey: prefix + ".keyCode") as? Int,
              (0...Int(UInt16.max)).contains(keyCode),
              let rawModifiers = defaults.object(forKey: prefix + ".modifiers") as? Int,
              let modifiers = UInt32(exactly: rawModifiers) else { return action.defaultShortcut }
        return GlobalShortcut(keyCode: UInt32(keyCode), modifiers: modifiers, label: label)
    }

    func save(_ shortcut: GlobalShortcut?, for action: ShortcutAction) {
        let prefix = action.settingsPrefix
        defaults.set(shortcut == nil, forKey: prefix + ".disabled")
        defaults.set(shortcut.map { Int($0.keyCode) }, forKey: prefix + ".keyCode")
        defaults.set(shortcut.map { Int($0.modifiers) }, forKey: prefix + ".modifiers")
        defaults.set(shortcut?.label, forKey: prefix + ".label")
    }
}

@MainActor
final class ShortcutController: ObservableObject {
    @Published private(set) var shortcuts: [ShortcutAction: GlobalShortcut] = [:]
    @Published private(set) var errors: [ShortcutAction: String] = [:]

    private static let signature: OSType = 0x51434854 // 'QCHT'
    private let store = GlobalShortcutStore(defaults: .standard)
    private struct Registration {
        let id: UInt32
        let reference: EventHotKeyRef
    }

    private var registrations: [ShortcutAction: Registration] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var onPress: ((ShortcutAction) -> Void)?
    var onShortcutChange: (() -> Void)?

    func install(onPress: @escaping (ShortcutAction) -> Void) {
        self.onPress = onPress
        guard eventHandler == nil else { return }

        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, OSType(kEventParamDirectObject), OSType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr else {
                return OSStatus(eventNotHandledErr)
            }
            let controller = Unmanaged<ShortcutController>.fromOpaque(userData).takeUnretainedValue()
            let signature = identifier.signature
            let id = identifier.id
            DispatchQueue.main.async {
                controller.handlePress(signature: signature, id: id)
            }
            return noErr
        }, 1, &type, pointer, &eventHandler)
        if status != noErr { eventHandler = nil }

        for action in ShortcutAction.allCases {
            guard let saved = store.load(action) else { continue }
            shortcuts[action] = saved
            errors[action] = register(saved, for: action)
        }
        onShortcutChange?()
    }

    /// Saves and registers a new shortcut. A conflicting shortcut is rejected and the
    /// previously registered shortcut keeps working.
    func set(_ candidate: GlobalShortcut?, for action: ShortcutAction) {
        if let candidate {
            let previous = shortcuts[action]
            if registrations[action] == nil || previous?.keyCode != candidate.keyCode || previous?.modifiers != candidate.modifiers,
               let message = register(candidate, for: action) {
                errors[action] = message
                onShortcutChange?()
                return
            }
        } else if let registration = registrations.removeValue(forKey: action) {
            UnregisterEventHotKey(registration.reference)
        }

        shortcuts[action] = candidate
        store.save(candidate, for: action)
        errors[action] = nil
        onShortcutChange?()
    }

    func deactivate() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.reference)
        }
        registrations.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
        onPress = nil
    }

    private func register(_ candidate: GlobalShortcut, for action: ShortcutAction) -> String? {
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
        if let previous = registrations.updateValue(Registration(id: identifier.id, reference: reference), forKey: action) {
            UnregisterEventHotKey(previous.reference)
        }
        return nil
    }

    private func handlePress(signature: OSType, id: UInt32) {
        guard signature == Self.signature,
              let action = registrations.first(where: { $0.value.id == id })?.key else { return }
        onPress?(action)
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
    var label: String
    var onRecord: (GlobalShortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderField {
        let field = ShortcutRecorderField()
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: ShortcutRecorderField, context: Context) {
        field.setAccessibilityLabel(label)
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
