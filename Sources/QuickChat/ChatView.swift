import AppKit
import SwiftUI

struct ChatView: View {
    @ObservedObject var model: ChatModel
    let focusRequest: Int
    let openSettings: () -> Void
    let hide: () -> Void
    @FocusState private var composerFocused: Bool
    @State private var showingHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = model.historyError {
                HStack {
                    Label(error, systemImage: "exclamationmark.circle")
                    Spacer()
                    Button("Retry", action: model.retryHistory)
                }
                .font(.callout)
            }
            ZStack {
                TranscriptView(chatID: model.activeChatID, exchanges: model.exchanges,
                               source: model.activeSource, activity: model.replyActivity)
                if model.exchanges.isEmpty { emptyState }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.account != nil && model.historyLoaded { composer }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: PopupSurface.color), in: panelShape)
        .overlay { panelShape.strokeBorder(.primary.opacity(0.10)).allowsHitTesting(false) }
        .clipShape(panelShape)
        .onChange(of: focusRequest, initial: true) { _, _ in focusComposer() }
        .onChange(of: model.ready) { _, ready in if ready { focusComposer() } }
        .onChange(of: model.historyLoaded) { _, loaded in if loaded { focusComposer() } }
        .onChange(of: model.activeChatID) { _, _ in if !showingHistory { focusComposer() } }
        .onChange(of: showingHistory) { _, shown in if !shown { focusComposer() } }
        .onExitCommand(perform: hide)
    }

    private var panelShape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Quick Chat")
                .font(.system(size: 15, weight: .semibold))
            PanelDragRegion()
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .accessibilityHidden(true)
            iconButton("History", icon: "clock.arrow.circlepath") { showingHistory.toggle() }
                .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                    ChatHistoryList(model: model) { id in
                        model.selectChat(id)
                        if model.activeChatID == id { showingHistory = false }
                    }
                }
            iconButton("New chat", icon: "square.and.pencil") { model.newChat(); focusComposer() }
            iconButton("Settings", icon: "gearshape", action: openSettings)
            iconButton("Hide chat", icon: "xmark", action: hide)
        }
    }

    private func iconButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
            .buttonStyle(.borderless)
            .accessibilityLabel(label)
            .help(label)
    }

    private struct PanelDragRegion: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { DragView() }
        func updateNSView(_ view: NSView, context: Context) {}

        private final class DragView: NSView {
            override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

            override func mouseDown(with event: NSEvent) {
                window?.performDrag(with: event)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if let status = model.accountStatus {
                ProgressView().controlSize(.small)
                Text(status.rawValue).foregroundStyle(.secondary)
            } else if model.account == nil {
                Text("Connect ChatGPT").font(.system(size: 20, weight: .semibold))
                if let error = model.accountError {
                    Text(error).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Use an eligible ChatGPT plan. No API key is required.").foregroundStyle(.secondary)
                }
                Button("Open Settings", action: openSettings).buttonStyle(.borderedProminent)
            } else if !model.historyLoaded {
                EmptyView()
            } else if model.models.isEmpty {
                Text("No models available").font(.system(size: 20, weight: .semibold))
                Text(model.modelError ?? "Reload the model list, then pick a model in the composer.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reload models", action: model.reloadModels).buttonStyle(.bordered)
            } else if model.currentModel == nil {
                Image(systemName: "bubble.left")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Pick a model").font(.system(size: 20, weight: .semibold))
                Text("Choose one in the composer to start chatting.").foregroundStyle(.secondary)
            } else {
                Text("Ask a question")
                    .font(.system(size: 22, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var draftBinding: Binding<String> {
        Binding(get: { model.draft }, set: { model.draft = $0 })
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: draftBinding)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($composerFocused)
                    .accessibilityLabel("Message")
                    .frame(height: 42)
                    .background(ComposerReturnKeys(focused: composerFocused, send: model.send))
                if model.draft.isEmpty {
                    Text("Message ChatGPT…")
                        .foregroundStyle(.secondary)
                        .padding(.top, 1).padding(.leading, 5)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            HStack(spacing: 12) {
                ModelMenu(model: model)
                ReasoningMenu(model: model)
                Spacer(minLength: 8)
                if model.replying {
                    stopButton
                } else {
                    sendButton
                }
            }
            if !model.models.isEmpty, let error = model.modelError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.10)).allowsHitTesting(false) }
    }

    private var sendButton: some View {
        Button(action: model.send) {
            Text("Enter")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.canSend ? Color.primary : Color.secondary)
                .padding(.horizontal, 9)
                .frame(minHeight: 24)
                .background(.primary.opacity(model.canSend ? 0.085 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canSend)
        .accessibilityLabel("Send message")
        .help("Send with Enter. Use Shift–Enter for a new line.")
    }

    private var stopButton: some View {
        Button(action: model.stop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop reply")
        .help("Stop reply")
    }

    private func focusComposer() {
        guard model.account != nil else { return }
        composerFocused = false
        Task { @MainActor in composerFocused = true }
    }
}

// MARK: - Composer controls

private struct ModelMenu: View {
    @ObservedObject var model: ChatModel

    var body: some View {
        Menu {
            if !model.models.isEmpty {
                Picker("Model", selection: $model.selectedModel) {
                    ForEach(model.models) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .pickerStyle(.inline)
                Divider()
            }
            Button("Reload models", action: model.reloadModels)
        } label: {
            composerLabel(title, icon: "brain")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(model.accountStatus != nil || model.replying)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Model")
        .accessibilityValue(title)
        .help("Model")
    }

    private var title: String {
        if let current = model.currentModel { return current.name }
        if model.accountStatus == .loadingModels { return "Loading models…" }
        return model.models.isEmpty ? "No models" : "Choose model"
    }
}

private struct ReasoningMenu: View {
    @ObservedObject var model: ChatModel

    var body: some View {
        if let current = model.currentModel, let selected = model.selectedReasoning {
            Menu {
                Picker("Reasoning effort", selection: Binding(
                    get: { model.selectedReasoning ?? selected },
                    set: { model.selectedReasoning = $0 }
                )) {
                    ForEach(current.reasoningLevels, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                composerLabel(selected.label, icon: "lightbulb")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(model.replying)
            .accessibilityLabel("Reasoning effort")
            .accessibilityValue(selected.label)
            .help("Reasoning effort")
        }
    }
}

private func composerLabel(_ text: String, icon: String) -> some View {
    Label(text, systemImage: icon)
        .labelStyle(.titleAndIcon)
        .symbolVariant(.none)
        .lineLimit(1)
        .font(.caption)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
}

// MARK: - History

private struct ChatHistoryList: View {
    @ObservedObject var model: ChatModel
    let select: (UUID) -> Void
    @Namespace private var selection
    @State private var hovered: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let entries = model.history
        VStack(alignment: .leading, spacing: 2) {
            if entries.isEmpty {
                Text("No conversations yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                }
                .frame(height: min(CGFloat(entries.count) * 31, 300))
            }
        }
        .padding(6)
        .frame(width: 244)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(listShape)
        .overlay { listShape.strokeBorder(.primary.opacity(0.12)).allowsHitTesting(false) }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.activeChatID)
    }

    private var listShape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    private func row(_ entry: ChatHistoryEntry) -> some View {
        let isActive = entry.id == model.activeChatID
        return Button { select(entry.id) } label: {
            HStack {
                Text(entry.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.isStreaming(entry.id) {
                    Spacer(minLength: 4)
                    Image(systemName: "ellipsis.circle")
                        .accessibilityHidden(true)
                }
            }
                .font(.callout)
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                            .matchedGeometryEffect(id: "selection", in: selection)
                    } else if hovered == entry.id {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.primary.opacity(0.055))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = entry.id
            } else if hovered == entry.id {
                hovered = nil
            }
        }
        .accessibilityLabel(entry.title)
        .accessibilityValue(model.isStreaming(entry.id) ? "Reply in progress" : "")
        .accessibilityAddTraits(isActive ? AccessibilityTraits.isSelected : [])
        .help(entry.title)
    }
}

struct AccountSettingsView: View {
    @ObservedObject var model: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("ChatGPT account", systemImage: "person.crop.circle")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
            if let account = model.account {
                Text(account).textSelection(.enabled)
                HStack {
                    Button("Reconnect", action: model.signIn)
                    Button("Sign out", action: model.signOut)
                }.disabled(model.hasRunningReplies || model.accountStatus != nil)
            } else if model.accountStatus == nil {
                Text("Use an eligible ChatGPT plan. No API key is required.").foregroundStyle(.secondary)
                Button("Continue with ChatGPT", action: model.signIn).buttonStyle(.borderedProminent)
            }
            if let status = model.accountStatus, status != .loadingModels {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status.rawValue).foregroundStyle(.secondary)
                    if status == .signingIn { Button("Cancel", action: model.cancelSignIn) }
                }
            }
            if let error = model.accountError {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.06)).allowsHitTesting(false) }
    }
}
