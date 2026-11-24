import AppKit
import SwiftUI

@main
enum QuickChatApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

final class QuickChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = ChatModel()
    private let rootState = ChatRootState()
    private let shortcuts = ShortcutController()

    private static let defaultPanelSize = NSSize(width: 540, height: 620)
    private static let minimumPanelSize = NSSize(width: 420, height: 400)
    private static let panelSizeKey = "QuickChat.panel.contentSize"

    private var panel: QuickChatPanel?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()
        buildPanel()
        buildStatusItem()

        shortcuts.onShortcutChange = { [weak self] in self?.updateStatusItem() }
        shortcuts.install { [weak self] action in
            switch action {
            case .newChat: self?.openFreshChat()
            case .continueChat: self?.showPanel()
            }
        }
        updateStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.flushHistory()
        shortcuts.deactivate()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Panel

    private func buildPanel() {
        let content = ChatShell(
            model: model,
            state: rootState,
            openSettings: { [weak self] in self?.showSettings() },
            hide: { [weak self] in self?.hidePanel() }
        )
        let hostingView = NSHostingView(rootView: content)

        let screen = activeScreen
        let size = panelSize(on: screen)
        hostingView.frame = NSRect(origin: .zero, size: size)

        let panel = QuickChatPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Quick Chat"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isRestorable = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = hostingView
        panel.contentMinSize = Self.minimumPanelSize
        panel.setContentSize(size)

        if let screen {
            panel.setFrame(centeredFrame(for: panel.frame.size, on: screen), display: false)
        }
        self.panel = panel
        panel.delegate = self
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        let size = window.contentRect(forFrameRect: window.frame).size
        UserDefaults.standard.set(NSStringFromSize(size), forKey: Self.panelSizeKey)
    }

    private func panelSize(on screen: NSScreen?) -> NSSize {
        let saved = UserDefaults.standard.string(forKey: Self.panelSizeKey).map(NSSizeFromString)
            ?? Self.defaultPanelSize
        let available = screen?.visibleFrame.insetBy(dx: 12, dy: 12).size ?? saved
        return NSSize(width: max(Self.minimumPanelSize.width, min(saved.width, available.width)),
                      height: max(Self.minimumPanelSize.height, min(saved.height, available.height)))
    }

    private func openFreshChat() {
        model.newChat()
        showPanel()
    }

    /// Panels become key only here, on an explicit open. The nonactivating style lets the
    /// composer take typing focus without bringing the app forward.
    @objc private func showPanel() {
        guard let panel else { return }
        if let screen = activeScreen, panel.screen !== screen {
            let contentRect = NSRect(origin: .zero, size: panelSize(on: screen))
            let size = panel.frameRect(forContentRect: contentRect).size
            panel.setFrame(centeredFrame(for: size, on: screen), display: false)
        }
        rootState.focusRequest += 1
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    // MARK: - Settings

    @objc private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        }
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let size = NSSize(width: 500, height: 390)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quick Chat Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentView = NSHostingView(rootView: SettingsView(model: model, shortcuts: shortcuts))
        window.setContentSize(size)
        if let screen = activeScreen {
            window.setFrame(centeredFrame(for: window.frame.size, on: screen), display: false)
        } else {
            window.center()
        }
        return window
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Quick Chat")
            button.setAccessibilityLabel("Quick Chat")
            button.toolTip = "Quick Chat"
        }

        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Quick Chat", action: #selector(showPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Quick Chat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        if !shortcuts.errors.isEmpty {
            button.toolTip = "Quick Chat — check shortcuts in Settings"
        } else if let label = shortcuts.shortcuts[.newChat]?.label {
            button.toolTip = "Quick Chat — New Chat: \(label)"
        } else {
            button.toolTip = "Quick Chat"
        }
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Quick Chat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Screen placement

    private var activeScreen: NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(location) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func centeredFrame(for size: NSSize, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }
}

/// Keeps the hosted `ChatView` in place across opens. Only the focus request changes,
/// so the conversation and composer state survive hiding the panel.
@MainActor
private final class ChatRootState: ObservableObject {
    @Published var focusRequest = 0
}

private struct ChatShell: View {
    let model: ChatModel
    @ObservedObject var state: ChatRootState
    let openSettings: () -> Void
    let hide: () -> Void

    var body: some View {
        ChatView(model: model, focusRequest: state.focusRequest, openSettings: openSettings, hide: hide)
    }
}

private struct SettingsView: View {
    let model: ChatModel
    @ObservedObject var shortcuts: ShortcutController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AccountSettingsView(model: model)
                shortcutSection
            }
            .padding(24)
        }
        .background(.regularMaterial)
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Keyboard Shortcuts", systemImage: "keyboard")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            ForEach(ShortcutAction.allCases, id: \.self) { action in
                shortcutRow(for: action)
            }

            Text("Click a field, then press a shortcut with ⌘, ⌥, or ⌃.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.06)).allowsHitTesting(false) }
    }

    private func shortcutRow(for action: ShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(action.title)
                Spacer(minLength: 8)
                ShortcutRecorder(shortcut: shortcuts.shortcuts[action], label: "\(action.title) shortcut") { candidate in
                    shortcuts.set(candidate, for: action)
                }
                .frame(width: 145, height: 26)
                if shortcuts.shortcuts[action] != nil {
                    Button("Remove") { shortcuts.set(nil, for: action) }
                        .controlSize(.small)
                        .accessibilityLabel("Remove \(action.title) shortcut")
                }
            }

            if let error = shortcuts.errors[action] {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
