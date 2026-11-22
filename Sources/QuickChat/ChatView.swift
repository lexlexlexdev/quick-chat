import AppKit
import SwiftUI
import SwiftStreamingMarkdown

struct ChatView: View {
    @ObservedObject var model: ChatModel
    let focusRequest: Int
    let openSettings: () -> Void
    let hide: () -> Void
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if model.exchanges.isEmpty { emptyState } else { TranscriptView(model: model) }
            if model.ready { composer }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: panelShape)
        .overlay { panelShape.strokeBorder(.white.opacity(0.16)).allowsHitTesting(false) }
        .clipShape(panelShape)
        .onChange(of: focusRequest, initial: true) { _, _ in focusComposer() }
        .onChange(of: model.ready) { _, ready in if ready { focusComposer() } }
        .onExitCommand(perform: hide)
    }

    private var panelShape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Quick Chat").font(.system(size: 17, weight: .semibold))
                Text("CHATGPT").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.exchanges.isEmpty {
                iconButton("New chat", icon: "square.and.pencil") { model.newChat(); focusComposer() }
                    .disabled(model.replying)
            }
            iconButton("Settings", icon: "gearshape", action: openSettings)
            iconButton("Hide chat", icon: "xmark", action: hide)
        }
    }

    private func iconButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 22, height: 22) }
            .buttonStyle(.borderless)
            .accessibilityLabel(label)
            .help(label)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if model.ready {
                Image(systemName: "bubble.left")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Ask a question").font(.system(size: 20, weight: .semibold))
            } else if let status = model.accountStatus {
                ProgressView().controlSize(.small)
                Text(status.rawValue).foregroundStyle(.secondary)
            } else {
                Text(model.account == nil ? "Connect ChatGPT" : "No model selected")
                    .font(.system(size: 20, weight: .semibold))
                if let error = model.accountError {
                    Text(error).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.account != nil {
                    Text("Choose a model in Settings to start chatting.").foregroundStyle(.secondary)
                }
                Button("Open Settings", action: openSettings).buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($composerFocused)
                    .accessibilityLabel("Message")
                    .frame(height: 63)
                if model.draft.isEmpty {
                    Text("Message ChatGPT…")
                        .foregroundStyle(.secondary)
                        .padding(.top, 1).padding(.leading, 5)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            HStack(spacing: 10) {
                Text(model.currentModel?.name ?? model.selectedModel).lineLimit(1).truncationMode(.middle)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.replying {
                    Button("Stop", systemImage: "stop.fill", action: model.stop)
                        .buttonStyle(.bordered)
                } else {
                    Button("Send", systemImage: "arrow.up", action: model.send)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canSend)
                }
            }
        }
        .padding(10)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.09)).allowsHitTesting(false) }
    }

    private func focusComposer() {
        guard model.ready else { return }
        composerFocused = false
        Task { @MainActor in composerFocused = true }
    }
}

private struct TranscriptView: View {
    @ObservedObject var model: ChatModel
    @State private var following = true
    @State private var height: CGFloat = 0
    private static let markdown = MarkdownRenderConfig.default.withBlockSpacing(value: 10)
        .withCodeBlockConfig(value: CodeBlockConfig(theme: .xcode, backgroundColor: .primary.opacity(0.055), foregroundColor: .secondary))
    private static let streamingMarkdown = markdown.withShouldAnimateText(value: true)

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(model.exchanges) { exchange in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("You").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(exchange.prompt).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 8) {
                                Text("ChatGPT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                reply(exchange)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 2)
                            .environment(\.openURL, OpenURLAction { url in url.scheme == "https" ? .systemAction : .discarded })
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }
                    .padding(.vertical, 2)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(key: TranscriptFrame.self, value: content.frame(in: .named("transcript")))
                        }
                    }
                }
                .coordinateSpace(name: "transcript")
                .onPreferenceChange(TranscriptFrame.self) { frame in
                    if frame.height != height {
                        height = frame.height
                        if following { reader.scrollTo("latest", anchor: .bottom) }
                    } else {
                        following = frame.maxY <= viewport.size.height + 56
                    }
                }
                .onChange(of: model.exchanges.last?.id) { _, _ in
                    following = true
                    reader.scrollTo("latest", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder private func reply(_ exchange: ChatModel.Exchange) -> some View {
        if case .replying = exchange.state, let source = model.activeSource {
            LiveReply(source: source, config: Self.streamingMarkdown)
        } else {
            if !exchange.reply.isEmpty { MarkdownView(text: exchange.reply, config: Self.markdown) }
            switch exchange.state {
            case .stopped:
                Text("Reply stopped").font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            default: EmptyView()
            }
        }
    }
}

private struct TranscriptFrame: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct LiveReply: View {
    let source: ReplySource
    let config: MarkdownRenderConfig
    @State private var hasText = false

    var body: some View {
        StreamedMarkdownView(source: source, config: config)
            .overlay(alignment: .topLeading) {
                if !hasText {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for a reply…").foregroundStyle(.secondary)
                    }.font(.callout)
                }
            }
            .frame(minHeight: hasText ? 0 : 24, alignment: .topLeading)
            .onReceive(source.hasText) { hasText = $0 }
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
                if !model.models.isEmpty {
                    Picker("Model", selection: $model.selectedModel) {
                        ForEach(model.models) { option in Text(option.name).tag(option.id) }
                    }.disabled(model.replying || model.accountStatus != nil)
                }
                HStack {
                    Button("Reload models", action: model.reloadModels)
                    Button("Reconnect", action: model.signIn)
                    Button("Sign out", action: model.signOut)
                }.disabled(model.replying || model.accountStatus != nil)
            } else if model.accountStatus == nil {
                Text("Use an eligible ChatGPT plan. No API key is required.").foregroundStyle(.secondary)
                Button("Continue with ChatGPT", action: model.signIn).buttonStyle(.borderedProminent)
            }
            if let status = model.accountStatus {
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
