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

@MainActor
final class ChatModel: ObservableObject {
    struct Exchange: Identifiable {
        enum State { case replying, complete, stopped, failed(String) }
        let id = UUID()
        let prompt: String
        var reply = ""
        var state = State.replying
    }

    @Published private(set) var account: String?
    @Published private(set) var accountError: String?
    @Published private(set) var accountStatus: AccountStatus? = .checking
    @Published private(set) var models: [ChatModelOption] = []
    @Published var selectedModel = UserDefaults.standard.string(forKey: "chatModel") ?? "" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "chatModel") }
    }
    @Published var draft = ""
    @Published private(set) var exchanges: [Exchange] = []
    @Published private(set) var activeSource: ReplySource?
    private var accountTask: Task<Void, Never>?
    private var replyTask: Task<Void, Never>?
    private let auth = ChatGPTAuth()
    private let client = ResponsesClient()

    enum AccountStatus: String { case checking = "Checking sign-in…", signingIn = "Waiting for ChatGPT sign-in…", loadingModels = "Loading models…", signingOut = "Signing out…" }

    var replying: Bool { activeSource != nil }
    var currentModel: ChatModelOption? { models.first { $0.id == selectedModel } }
    var ready: Bool { account != nil && currentModel != nil }
    var canSend: Bool {
        ready && accountStatus == nil && !replying && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        accountTask = Task {
            defer { accountStatus = nil; accountTask = nil }
            do {
                account = try await auth.account()
                if account != nil { try await loadModels() }
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
                try await loadModels()
            } catch {
                if !Task.isCancelled { accountError = Self.message(for: error) }
            }
        }
    }

    func cancelSignIn() { if accountStatus == .signingIn { accountTask?.cancel() } }

    func reloadModels() {
        guard accountTask == nil, account != nil, !replying else { return }
        accountError = nil
        accountTask = Task {
            defer { accountStatus = nil; accountTask = nil }
            do { try await loadModels() }
            catch { accountError = Self.message(for: error) }
        }
    }

    private func loadModels() async throws {
        accountStatus = .loadingModels
        let token = try await auth.accessToken()
        let available = try await client.models(token: token)
        if !available.contains(where: { $0.id == selectedModel }), let first = available.first {
            selectedModel = first.id
        }
        models = available
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
        newChat()
    }

    func newChat() {
        guard !replying else { return }
        exchanges.removeAll()
        draft = ""
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
        draft = ""
        exchanges.append(Exchange(prompt: prompt))
        let index = exchanges.count - 1
        let source = ReplySource()
        let model = selectedModel
        activeSource = source
        replyTask = Task {
            defer { activeSource = nil; replyTask = nil }
            var partial = ""
            do {
                let final = try await client.stream(model: model, turns: turns, token: auth.accessToken()) { snapshot in
                    guard !Task.isCancelled else { return }
                    partial = snapshot
                    source.update(snapshot)
                }
                try Task.checkCancellation()
                exchanges[index].reply = final
                exchanges[index].state = .complete
            } catch {
                exchanges[index].reply = partial
                exchanges[index].state = Task.isCancelled ? .stopped : .failed(Self.message(for: error))
            }
        }
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
