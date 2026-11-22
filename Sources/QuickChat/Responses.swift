import Foundation

struct ChatTurn: Sendable {
    enum Role: String, Encodable, Sendable { case user, assistant }
    let role: Role
    let text: String
}

struct ChatServiceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ChatModelOption: Identifiable, Equatable {
    let id: String
    let name: String
}

struct ResponsesClient {
    private static let endpoint = URL(string: "https://api.openai.com/v1")!
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 300
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    func models(token: String) async throws -> [ChatModelOption] {
        let (bytes, response) = try await Self.session.bytes(for: request("models", token: token))
        defer { bytes.task.cancel() }
        try await checkHTTP(response, bytes)
        return try Self.decodeCatalog(await read(bytes, limit: 1 << 20))
    }

    static func decodeCatalog(_ data: Data) throws -> [ChatModelOption] {
        struct Catalog: Decodable {
            let models: [Entry]
            struct Entry: Decodable {
                let slug: String?
                let display_name: String?
                let visibility: String?
            }
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        var seen: [String: String] = [:]
        var options: [ChatModelOption] = []
        for entry in catalog.models where entry.visibility == "list" {
            guard let id = entry.slug, !id.isEmpty, id.utf8.count <= 256,
                  !id.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
                throw ChatServiceError("ChatGPT returned an invalid model catalog.")
            }
            let name = entry.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let label = name.isEmpty ? id : name
            if let previous = seen.updateValue(label, forKey: id) {
                guard previous == label else { throw ChatServiceError("ChatGPT returned conflicting model names.") }
                continue
            }
            options.append(ChatModelOption(id: id, name: label))
        }
        guard !options.isEmpty else { throw ChatServiceError("No chat models are available on this account.") }
        return options
    }

    func stream(model: String, turns: [ChatTurn], token: String, onSnapshot: @MainActor (String) -> Void) async throws -> String {
        var request = request("responses", token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.body(model: model, turns: turns)
        let (bytes, response) = try await Self.session.bytes(for: request)
        defer { bytes.task.cancel() }
        try await checkHTTP(response, bytes)
        guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else {
            throw ChatServiceError("ChatGPT did not return a reply stream.")
        }
        var stream = ResponsesStream()
        for try await byte in bytes {
            if let update = try stream.receive(byte) {
                switch update {
                case .snapshot(let text): await onSnapshot(text)
                case .complete(let text): return text
                }
            }
        }
        try Task.checkCancellation()
        throw ChatServiceError("The connection closed before ChatGPT finished replying.")
    }

    static func body(model: String, turns: [ChatTurn]) throws -> Data {
        struct Payload: Encodable {
            let model: String
            let input: [Message]
            let store = false
            let stream = true
        }
        struct Message: Encodable {
            let type = "message"
            let role: ChatTurn.Role
            let content: [Part]
            let status: String?
            let id: String?
        }
        struct Part: Encodable {
            let type: String
            let text: String
            let annotations: [String]?
        }
        let input = turns.enumerated().map { index, turn in
            let assistant = turn.role == .assistant
            return Message(role: turn.role,
                           content: [Part(type: assistant ? "output_text" : "input_text", text: turn.text, annotations: assistant ? [] : nil)],
                           status: assistant ? "completed" : nil,
                           id: assistant ? "msg_quickchat_\(index)" : nil)
        }
        return try JSONEncoder().encode(Payload(model: model, input: input))
    }

    private func request(_ route: String, token: String) -> URLRequest {
        var request = URLRequest(url: Self.endpoint.appendingPathComponent(route))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func checkHTTP(_ response: URLResponse, _ bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { throw ChatServiceError("ChatGPT did not return an HTTP response.") }
        guard !(200..<300).contains(http.statusCode) else { return }
        let data = try? await read(bytes, limit: 32_768)
        try Task.checkCancellation()
        let error = data.flatMap { try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: $0) }
        throw providerError(code: error?.error.code, status: http.statusCode)
    }

    private func read(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ChatServiceError("ChatGPT returned too much data.") }
            data.append(byte)
        }
        return data
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct ProviderErrorEnvelope: Decodable {
    let error: Detail
    struct Detail: Decodable { let code: String? }
}

private func providerError(code: String?, status: Int? = nil) -> ChatServiceError {
    switch code {
    case "subscription_sharing_user_not_eligible": return ChatServiceError("ChatGPT plan access is unavailable for this account or workspace.")
    case "subscription_sharing_usage_limit_exceeded": return ChatServiceError("You reached your ChatGPT plan usage limit.")
    case "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
        return ChatServiceError("ChatGPT did not authorize plan usage. Reconnect in Settings.")
    case "subscription_sharing_invalid_user": return ChatServiceError("ChatGPT did not accept this account. Reconnect in Settings.")
    case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
        return ChatServiceError("ChatGPT plan usage is temporarily unavailable. Try again later.")
    default:
        switch status {
        case 401: return ChatServiceError("ChatGPT did not accept your sign-in. Reconnect in Settings.")
        case 403: return ChatServiceError("This account is not allowed to make the request.")
        case 429: return ChatServiceError("ChatGPT rate-limited the request. Try again later.")
        case 400, 404: return ChatServiceError("ChatGPT rejected the request. Check the selected model in Settings.")
        case let status?: return ChatServiceError("ChatGPT request failed (HTTP \(status)).")
        case nil: return ChatServiceError("ChatGPT did not complete the reply.")
        }
    }
}

struct ResponsesStream {
    enum Update: Equatable { case snapshot(String), complete(String) }
    private struct Event: Decodable {
        let type: String?
        let delta: String?
        let code: String?
        let response: Reply?
    }
    private struct Reply: Decodable {
        let status: String
        let output: [Item]?
        let error: ProviderErrorEnvelope.Detail?
        struct Item: Decodable {
            let type: String
            let role: String?
            let content: [Part]?
        }
        struct Part: Decodable { let type: String; let text: String? }
    }

    private var line = Data()
    private var data = Data()
    private var eventName: String?
    private var text = ""
    private var byteCount = 0
    private var pendingCR = false

    mutating func receive(_ byte: UInt8) throws -> Update? {
        byteCount += 1
        guard byteCount <= 8 << 20 else { throw ChatServiceError("ChatGPT returned too much data.") }
        if pendingCR {
            pendingCR = false
            if byte == 10 { return nil }
        }
        guard byte == 10 || byte == 13 else { line.append(byte); return nil }
        pendingCR = byte == 13
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { return try finishFrame() }
        let colon = line.firstIndex(of: 58) ?? line.endIndex
        let field = line[..<colon]
        let start = colon == line.endIndex ? colon : line.index(after: colon)
        var value = line[start...]
        if value.first == 32 { value = value.dropFirst() }
        if field.elementsEqual("data".utf8) {
            if !data.isEmpty { data.append(10) }
            data.append(contentsOf: value)
        } else if field.elementsEqual("event".utf8) {
            eventName = String(decoding: value, as: UTF8.self)
        }
        return nil
    }

    private mutating func finishFrame() throws -> Update? {
        defer { data.removeAll(keepingCapacity: true); eventName = nil }
        guard !data.isEmpty else { return nil }
        let event = try JSONDecoder().decode(Event.self, from: data)
        if let eventName, !eventName.isEmpty, let type = event.type, eventName != type {
            throw ChatServiceError("ChatGPT returned an inconsistent reply stream.")
        }
        switch event.type ?? eventName {
        case "response.output_text.delta":
            guard let delta = event.delta, !delta.isEmpty else { return nil }
            text += delta
            return .snapshot(text)
        case "response.refusal.delta", "response.refusal.done":
            throw ChatServiceError("ChatGPT declined to answer this prompt.")
        case "response.failed", "error":
            throw providerError(code: event.response?.error?.code ?? event.code)
        case "response.incomplete":
            throw ChatServiceError("ChatGPT stopped before finishing the reply.")
        case "response.completed":
            guard let response = event.response, response.status == "completed", response.error == nil else {
                throw providerError(code: event.response?.error?.code)
            }
            var final = ""
            for item in response.output ?? [] where item.type == "message" && item.role == "assistant" {
                for part in item.content ?? [] where part.type == "output_text" {
                    if let text = part.text { final += text }
                }
            }
            guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, final.utf8.starts(with: text.utf8) else {
                throw ChatServiceError("ChatGPT did not return a matching final reply.")
            }
            return .complete(final)
        default: return nil
        }
    }
}
