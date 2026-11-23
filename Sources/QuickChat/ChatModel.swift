import AppKit
import Combine
import SwiftStreamingMarkdown

final class ReplySource: StreamedMarkdownSource {
    private let latest = CurrentValueSubject<String, Never>("")
    var hasText: AnyPublisher<Bool, Never> {
        latest.map { !$0.isEmpty }.removeDuplicates().eraseToAnyPublisher()
    }

    var text: AsyncStream<String> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let subscription = latest.sink { continuation.yield($0) }
            continuation.onTermination = { _ in subscription.cancel() }
        }
    }

    func update(_ snapshot: String) { latest.send(snapshot) }
}

struct ChatHistoryEntry: Identifiable {
    let id: UUID
    let title: String
}

@MainActor
final class ChatModel: ObservableObject {
    struct Exchange: Identifiable {
        enum State { case replying, complete, stopped, failed(String) }
        let id = UUID()
        let prompt: String
        var reply = ""
        var reasoningSummary = ""
        var state = State.replying
    }

    @Published private(set) var account: String?
    @Published private(set) var accountError: String?
    @Published private(set) var accountStatus: AccountStatus? = .checking
    @Published private(set) var models: [ChatModelOption] = []
    @Published private(set) var modelError: String?
    @Published var selectedModel = UserDefaults.standard.string(forKey: "chatModel") ?? "" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "chatModel") }
    }
    @Published private var conversations = ChatHistory()
    @Published private var reasoningPreferences = UserDefaults.standard.dictionary(forKey: "reasoningByModel") as? [String: String] ?? [:]
    @Published private(set) var replyActivity: ReplyActivity = .waiting
    @Published private(set) var activeSource: ReplySource?
    private var accountTask: Task<Void, Never>?
    private var replyTask: Task<Void, Never>?
    private let auth = ChatGPTAuth()
    private let client = ResponsesClient()

    enum AccountStatus: String { case checking = "Checking sign-in…", signingIn = "Waiting for ChatGPT sign-in…", loadingModels = "Loading models…", signingOut = "Signing out…" }

    var replying: Bool { activeSource != nil }
    var currentModel: ChatModelOption? { models.first { $0.id == selectedModel } }
    var selectedReasoning: ReasoningLevel? {
        get {
            guard let currentModel, let saved = reasoningPreferences[currentModel.id],
                  let level = ReasoningLevel(rawValue: saved), currentModel.reasoningLevels.contains(level) else { return nil }
            return level
        }
        set {
            guard let currentModel, newValue == nil || currentModel.reasoningLevels.contains(where: { $0 == newValue }) else { return }
            reasoningPreferences[currentModel.id] = newValue?.rawValue
            UserDefaults.standard.set(reasoningPreferences, forKey: "reasoningByModel")
        }
    }
    var draft: String {
        get { conversations.active.draft }
        set { conversations.active.draft = newValue }
    }
    var exchanges: [Exchange] { conversations.active.exchanges }
    var activeChatID: UUID { conversations.active.id }
    var history: [ChatHistoryEntry] { conversations.entries }
    var ready: Bool { account != nil && currentModel != nil }
    var canSend: Bool {
        ready && accountStatus == nil && !replying && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        accountTask = Task {
            defer { accountStatus = nil; accountTask = nil }
            do {
                account = try await auth.account()
                if account != nil { await loadModels() }
            } catch { accountError = Self.message(for: error) }
        }
    }

    func signIn() {
        guard accountTask == nil, !replying else { return }
        accountError = nil
        accountStatus = .signingIn
        accountTask = Task {
            defer { accountStatus = nil; accountTask = nil }
            do {
                account = try await auth.signIn { NSWorkspace.shared.open($0) }
                models = []
                await loadModels()
            } catch {
                if !Task.isCancelled { accountError = Self.message(for: error) }
            }
        }
    }

    func cancelSignIn() { if accountStatus == .signingIn { accountTask?.cancel() } }

    func reloadModels() {
        guard accountTask == nil, account != nil, !replying else { return }
        accountTask = Task {
            defer { accountStatus = nil; accountTask = nil }
            await loadModels()
        }
    }

    private func loadModels() async {
        accountStatus = .loadingModels
        modelError = nil
        do {
            let token = try await auth.accessToken()
            let available = try await client.models(token: token)
            if !available.contains(where: { $0.id == selectedModel }), let first = available.first {
                selectedModel = first.id
            }
            models = available
        } catch {
            modelError = Self.message(for: error)
        }
    }

    func signOut() {
        guard accountTask == nil, !replying else { return }
        accountStatus = .signingOut
        accountError = nil
        accountTask = Task {
            defer { accountStatus = nil; accountTask = nil }
            do {
                try await auth.signOut()
                clearAccount()
            } catch {
                if (try? await auth.account() == nil) == true { clearAccount() }
                accountError = Self.message(for: error)
            }
        }
    }

    private func clearAccount() {
        account = nil
        models = []
        modelError = nil
        conversations = ChatHistory()
    }

    func newChat() {
        guard !replying else { return }
        conversations.startNew()
    }

    func selectChat(_ id: UUID) {
        guard !replying else { return }
        conversations.select(id)
    }

    func send() {
        guard canSend else { return }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        var turns: [ChatTurn] = []
        for exchange in exchanges where isComplete(exchange) {
            turns.append(ChatTurn(role: .user, text: exchange.prompt))
            turns.append(ChatTurn(role: .assistant, text: exchange.reply))
        }
        turns.append(ChatTurn(role: .user, text: prompt))
        conversations.active.draft = ""
        conversations.active.exchanges.append(Exchange(prompt: prompt))
        let index = conversations.active.exchanges.count - 1
        let source = ReplySource()
        let model = selectedModel
        let reasoning = selectedReasoning
        let requestSummary = currentModel?.reasoningLevels.contains(where: { $0 != .none }) == true
            && reasoning != ReasoningLevel.none
        replyActivity = .waiting
        activeSource = source
        replyTask = Task {
            defer { activeSource = nil; replyTask = nil }
            var partial = ""
            var summary = ""
            do {
                let token = try await auth.accessToken()
                let final = try await client.stream(model: model, turns: turns, token: token,
                                                    reasoning: reasoning, requestSummary: requestSummary,
                                                    onActivity: { activity in
                    guard !Task.isCancelled, replyActivity != activity else { return }
                    replyActivity = activity
                    if case .summary(let text) = activity { summary = text }
                }) { snapshot in
                    guard !Task.isCancelled else { return }
                    partial = snapshot
                    source.update(snapshot)
                }
                try Task.checkCancellation()
                finishReply(index, text: final, summary: summary, state: .complete)
            } catch {
                finishReply(index, text: partial, summary: summary, state: Task.isCancelled ? .stopped : .failed(Self.message(for: error)))
            }
        }
    }

    private func finishReply(_ index: Int, text: String, summary: String, state: Exchange.State) {
        var exchange = conversations.active.exchanges[index]
        exchange.reply = text
        exchange.reasoningSummary = summary
        exchange.state = state
        conversations.active.exchanges[index] = exchange
    }

    func stop() { replyTask?.cancel() }

    private func isComplete(_ exchange: Exchange) -> Bool {
        if case .complete = exchange.state { return true }
        return false
    }

    private static func message(for error: Error) -> String {
        if error is DecodingError { return "ChatGPT returned data this app couldn’t read." }
        return error.localizedDescription
    }
}

struct ChatHistory {
    struct Conversation {
        let id = UUID()
        let order: Int
        var draft = ""
        var exchanges: [ChatModel.Exchange] = []

        var entry: ChatHistoryEntry? {
            let text = (exchanges.first?.prompt ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title = text.split(whereSeparator: \.isNewline).first else { return nil }
            return ChatHistoryEntry(id: id, title: String(title.prefix(120)))
        }
    }

    var active = Conversation(order: 0)
    private var archived: [Conversation] = []
    private var nextOrder = 1

    var entries: [ChatHistoryEntry] {
        var chats = archived
        chats.append(active)
        chats.sort { $0.order > $1.order }
        return chats.compactMap(\.entry)
    }

    mutating func startNew() {
        guard active.entry != nil else { return }
        archived.append(active)
        active = Conversation(order: nextOrder)
        nextOrder += 1
    }

    mutating func select(_ id: UUID) {
        guard let index = archived.firstIndex(where: { $0.id == id }) else { return }
        let selected = archived.remove(at: index)
        if active.entry != nil { archived.append(active) }
        active = selected
    }
}
