import Carbon
import Foundation
import Testing
@testable import QuickChat

@Test func freshInstallUsesSeparateBracketShortcuts() throws {
    let suite = "QuickChat.ShortcutTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = GlobalShortcutStore(defaults: defaults)

    let new = try #require(store.load(.newChat))
    let resume = try #require(store.load(.continueChat))
    #expect(new.keyCode == UInt32(kVK_ANSI_RightBracket))
    #expect(resume.keyCode == UInt32(kVK_ANSI_LeftBracket))
    #expect(new.modifiers == UInt32(cmdKey | shiftKey))
    #expect(resume.modifiers == UInt32(cmdKey | shiftKey))
}

@Test func removingContinueShortcutKeepsLegacyNewChatShortcut() throws {
    let suite = "QuickChat.ShortcutTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(kVK_ANSI_J, forKey: "QuickChat.shortcut.keyCode")
    defaults.set(controlKey, forKey: "QuickChat.shortcut.modifiers")
    defaults.set("⌃J", forKey: "QuickChat.shortcut.label")

    let store = GlobalShortcutStore(defaults: defaults)
    store.save(nil, for: .continueChat)
    let reopened = GlobalShortcutStore(defaults: try #require(UserDefaults(suiteName: suite)))
    #expect(reopened.load(.continueChat) == nil)
    #expect(reopened.load(.newChat) == GlobalShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey), label: "⌃J"))
}
