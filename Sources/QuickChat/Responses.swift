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

enum ReasoningLevel: String, CaseIterable, Codable, Hashable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var label: String {
        switch self {
        case .none: return "None"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max"
        }
    }
}

enum ReplyActivity: Equatable, Sendable {
    case waiting
    case thinking
    case summary(String)
}

struct ChatModelOption: Identifiable, Equatable {
    let id: String
    let name: String
    let reasoningLevels: [ReasoningLevel]

    init(id: String, name: String, reasoningLevels: [ReasoningLevel] = []) {
        self.id = id
        self.name = name
        self.reasoningLevels = reasoningLevels
    }
}

struct ResponsesClient {
    private static let defaultEndpoint = URL(string: "https://api.openai.com/v1")!
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 300
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private let endpoint: URL
    private let session: URLSession

    init() {
        endpoint = Self.defaultEndpoint
        session = Self.sharedSession
    }

    init(endpoint: URL, session: URLSession) {
        self.endpoint = endpoint
        self.session = session
    }

    func models(token: String) async throws -> [ChatModelOption] {
        let (bytes, response) = try await session.bytes(for: request("models", token: token))
        defer { bytes.task.cancel() }
        try await checkHTTP(response, bytes)
        return try Self.decodeCatalog(await read(bytes, limit: 1 << 20))
    }

    static func decodeCatalog(_ data: Data) throws -> [ChatModelOption] {
        let catalog = try JSONDecoder().decode(ModelCatalog.self, from: data)
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
            options.append(ChatModelOption(id: id, name: label, reasoningLevels: reasoningLevels(for: entry)))
        }
        guard !options.isEmpty else { throw ChatServiceError("No chat models are available on this account.") }
        return options
    }

    /// Catalog metadata wins. Only a missing field falls back to facts verified on OpenAI's model pages.
    private static func reasoningLevels(for entry: ModelCatalog.Entry) -> [ReasoningLevel] {
        guard let supported = entry.supported_reasoning_levels else {
            return verifiedReasoningLevels(for: entry.slug ?? "")
        }
        var seen = Set<ReasoningLevel>()
        var levels: [ReasoningLevel] = []
        for item in supported {
            guard let raw = item.effort, let level = ReasoningLevel(rawValue: raw),
                  seen.insert(level).inserted else { continue }
            levels.append(level)
        }
        return levels
    }

    private static func verifiedReasoningLevels(for slug: String) -> [ReasoningLevel] {
        switch slug {
        case "gpt-6-luna", "gpt-6-sol", "gpt-6.1-terra":
            return [.none, .low, .medium, .high, .xhigh, .max]
        case "gpt-6-astra", "gpt-6.1-sol", "gpt-6.2-sol", "gpt-6.2-astra":
            return [.low, .medium, .high, .xhigh, .max]
        default:
            return []
        }
    }

    func stream(model: String, turns: [ChatTurn], token: String,
                reasoning: ReasoningLevel? = nil, requestSummary: Bool = false,
                onActivity: @MainActor (ReplyActivity) -> Void = { _ in },
                onSnapshot: @MainActor (String) -> Void) async throws -> String {
        var request = request("responses", token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.body(model: model, turns: turns, reasoning: reasoning, requestSummary: requestSummary)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else {
            throw ChatServiceError("ChatGPT did not return an HTTP response.")
        }
        if !(200..<300).contains(http.statusCode) {
            let data = try await readBounded(bytes, limit: 32_768)
            try Task.checkCancellation()
            let detail = try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: data)
            throw Self.providerError(code: detail?.error?.code, status: http.statusCode, requestID: Self.requestID(http))
        }

        let mediaType = Self.mediaType(http)
        let requestID = Self.requestID(http)
        // The plan transport has returned SSE as text/plain and without Content-Type,
        // so the body's framing decides the format and headers are diagnostics only.
        var stream = ResponsesStream()
        var pending = Data()
        var classified = false
        var rejection: StreamBodyKind?
        var lastActivity: ReplyActivity?

        func process(_ update: ResponsesStream.Update) async -> String? {
            switch update {
            case .activity(let activity):
                guard activity != lastActivity else { return nil }
                lastActivity = activity
                await onActivity(activity)
            case .snapshot(let text):
                await onSnapshot(text)
            case .complete(let text):
                if !stream.summary.isEmpty {
                    let activity = ReplyActivity.summary(stream.summary)
                    if activity != lastActivity {
                        lastActivity = activity
                        await onActivity(activity)
                    }
                }
                return text
            }
            return nil
        }

        for try await byte in bytes {
            if rejection != nil {
                if pending.count >= 64 << 10 { break }
                pending.append(byte)
                continue
            }
            if classified {
                if let update = try stream.receive(byte) {
                    if let text = await process(update) { return text }
                }
                continue
            }
            pending.append(byte)
            guard let kind = Self.classifyStreamBody(pending) else {
                if pending.count > 4096 { rejection = .unknown }
                continue
            }
            switch kind {
            case .sse:
                classified = true
                if pending.starts(with: [0xEF, 0xBB, 0xBF] as [UInt8]) { pending.removeFirst(3) }
                let head = pending
                pending.removeAll(keepingCapacity: true)
                for byte in head {
                    if let update = try stream.receive(byte) {
                        if let text = await process(update) { return text }
                    }
                }
            case .json, .html, .unknown:
                rejection = kind
            }
        }

        try Task.checkCancellation()
        if let rejection {
            throw Self.transportError(kind: rejection, data: pending, status: http.statusCode,
                                      mediaType: mediaType, requestID: requestID)
        }
        if !classified, pending.isEmpty || pending.allSatisfy(Self.isStreamWhitespace) {
            throw ChatServiceError("ChatGPT returned an empty reply stream."
                + Self.diagnostics(status: http.statusCode, mediaType: mediaType, requestID: requestID))
        }
        throw ChatServiceError("The connection closed before ChatGPT finished replying."
            + Self.diagnostics(status: http.statusCode, mediaType: mediaType, requestID: requestID))
    }

    static func body(model: String, turns: [ChatTurn], reasoning: ReasoningLevel? = nil, requestSummary: Bool = false) throws -> Data {
        struct Payload: Encodable {
            let model: String
            let input: [Message]
            let store = false
            let stream = true
            let reasoning: Reasoning?
        }
        struct Reasoning: Encodable {
            let effort: String?
            let summary: String?
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
        let adjusted = reasoning == nil && !requestSummary
            ? nil
            : Reasoning(effort: reasoning?.rawValue,
                        summary: requestSummary && reasoning != ReasoningLevel.none ? "auto" : nil)
        return try JSONEncoder().encode(Payload(model: model, input: input, reasoning: adjusted))
    }

    private func request(_ route: String, token: String) -> URLRequest {
        var request = URLRequest(url: endpoint.appendingPathComponent(route))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func checkHTTP(_ response: URLResponse, _ bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { throw ChatServiceError("ChatGPT did not return an HTTP response.") }
        guard !(200..<300).contains(http.statusCode) else { return }
        let data = try await readBounded(bytes, limit: 32_768)
        try Task.checkCancellation()
        let detail = try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: data)
        throw Self.providerError(code: detail?.error?.code, status: http.statusCode, requestID: Self.requestID(http))
    }

    private func read(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ChatServiceError("ChatGPT returned too much data.") }
            data.append(byte)
        }
        return data
    }

    private func readBounded(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            if data.count >= limit { break }
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

private struct ModelCatalog: Decodable {
    let models: [Entry]

    struct Entry: Decodable {
        let slug: String?
        let display_name: String?
        let visibility: String?
        let supported_reasoning_levels: [Reasoning]?
    }

    struct Reasoning: Decodable {
        let effort: String?
    }
}

private struct ProviderErrorEnvelope: Decodable {
    let error: Detail?
    struct Detail: Decodable {
        let code: String?
    }
}

private enum StreamBodyKind: Equatable {
    case sse
    case json
    case html
    case unknown
}

fileprivate extension ResponsesClient {
    static func classifyStreamBody(_ data: Data) -> StreamBodyKind? {
        var bytes = Array(data)
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes.removeFirst(3)
        } else if bytes.count < 3, ([0xEF, 0xBB, 0xBF] as [UInt8]).starts(with: bytes) {
            return nil
        }
        var index = 0
        while index < bytes.count, isStreamWhitespace(bytes[index]) { index += 1 }
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case 0x7B, 0x5B, 0x22, 0x30...0x39, 0x74, 0x66, 0x6E:
            return .json
        case 0x3C:
            return .html
        case 0x3A:
            return .sse
        case 0x64, 0x65, 0x69, 0x72:
            var line: [UInt8] = []
            var cursor = index
            while cursor < bytes.count, !isLineBreak(bytes[cursor]) {
                line.append(bytes[cursor])
                cursor += 1
            }
            if let colon = line.firstIndex(of: 0x3A) {
                return isSSEField(Array(line[..<colon])) ? .sse : .unknown
            }
            if cursor < bytes.count { return isSSEField(line) ? .sse : .unknown }
            if line.count > 5 { return .unknown }
            return nil
        default:
            return .unknown
        }
    }

    static func isStreamWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    static func isLineBreak(_ byte: UInt8) -> Bool {
        byte == 0x0A || byte == 0x0D
    }

    static func isSSEField(_ bytes: [UInt8]) -> Bool {
        bytes.elementsEqual("data".utf8) || bytes.elementsEqual("event".utf8)
            || bytes.elementsEqual("id".utf8) || bytes.elementsEqual("retry".utf8)
    }

    static func transportError(kind: StreamBodyKind, data: Data, status: Int, mediaType: String?, requestID: String?) -> ChatServiceError {
        let suffix = diagnostics(status: status, mediaType: mediaType, requestID: requestID)
        switch kind {
        case .json:
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let raw = object["error"], !(raw is NSNull) {
                let detail = raw as? [String: Any]
                return providerError(code: detail?["code"] as? String,
                                     status: status, mediaType: mediaType, requestID: requestID)
            }
            // A successful JSON response is never accepted as a reply; only the SSE
            // terminal event may complete a turn.
            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                return ChatServiceError("ChatGPT returned a non-streaming reply." + suffix)
            }
            return ChatServiceError("ChatGPT returned a malformed reply." + suffix)
        case .html:
            return ChatServiceError("ChatGPT returned a web page instead of a reply." + suffix)
        case .unknown:
            return ChatServiceError("ChatGPT returned an unexpected reply format." + suffix)
        case .sse:
            return ChatServiceError("ChatGPT returned an empty reply stream." + suffix)
        }
    }

    static func providerError(code: String?, status: Int? = nil,
                              mediaType: String? = nil, requestID: String? = nil) -> ChatServiceError {
        if let code, let mapped = mappedProviderMessage(code) {
            return ChatServiceError(mapped)
        }
        let base: String
        switch status {
        case 401: base = "ChatGPT did not accept your sign-in. Reconnect in Settings."
        case 403: base = "This account is not allowed to make the request."
        case 429: base = "ChatGPT rate-limited the request. Try again later."
        case 400, 404: base = "ChatGPT rejected the request. Check the selected model and reasoning effort."
        case 500, 502, 503, 504: base = "ChatGPT is temporarily unavailable. Try again later."
        case 200: base = "ChatGPT could not complete the reply."
        case let status?: base = "ChatGPT request failed (HTTP \(status))."
        case nil: base = "ChatGPT did not complete the reply."
        }
        var text = base
        if let code = safeCode(code) { text += " (code=\(code))" }
        if status == 200 || status == nil {
            text += diagnostics(status: status == 200 ? 200 : nil, mediaType: mediaType, requestID: requestID)
        }
        return ChatServiceError(text)
    }

    static func mappedProviderMessage(_ code: String) -> String? {
        switch code {
        case "subscription_sharing_user_not_eligible":
            return "ChatGPT plan access is unavailable for this account or workspace."
        case "subscription_sharing_usage_limit_exceeded":
            return "You reached your ChatGPT plan usage limit."
        case "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            return "ChatGPT did not authorize plan usage. Reconnect in Settings."
        case "subscription_sharing_invalid_user":
            return "ChatGPT did not accept this account. Reconnect in Settings."
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            return "ChatGPT plan usage is temporarily unavailable. Try again later."
        default:
            return nil
        }
    }

    static func diagnostics(status: Int?, mediaType: String?, requestID: String?) -> String {
        var parts: [String] = []
        if let status { parts.append("HTTP \(status)") }
        if let mediaType, !mediaType.isEmpty { parts.append(mediaType) }
        if let requestID, !requestID.isEmpty { parts.append("request_id=\(requestID)") }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    static func mediaType(_ response: HTTPURLResponse) -> String? {
        guard let raw = response.value(forHTTPHeaderField: "Content-Type") else { return nil }
        let base = raw.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let base, !base.isEmpty, base.utf8.count <= 80 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$&^_+-./")
        guard base.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return base
    }

    static func requestID(_ response: HTTPURLResponse) -> String? {
        for name in ["x-request-id", "openai-request-id", "x-oai-request-id"] {
            guard let value = response.value(forHTTPHeaderField: name)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value.utf8.count <= 64 else { continue }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
            guard value.unicodeScalars.allSatisfy(allowed.contains) else { continue }
            return value
        }
        return nil
    }

    static func safeCode(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code.utf8.count <= 64 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard code.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return code
    }
}

struct ResponsesStream {
    enum Update: Equatable {
        case snapshot(String)
        case complete(String)
        case activity(ReplyActivity)
    }

    private struct Event: Decodable {
        let type: String?
        let delta: String?
        let text: String?
        let code: String?
        let response: Reply?
        let item: Item?
        let part: Part?
        let error: ProviderErrorEnvelope.Detail?
    }
    private struct Reply: Decodable {
        let status: String?
        let output: [Item]?
        let error: ProviderErrorEnvelope.Detail?
    }
    private struct Item: Decodable {
        let type: String?
        let role: String?
        let content: [Part]?
        let summary: [Part]?
    }
    private struct Part: Decodable { let type: String?; let text: String? }

    private static let maxSummaryBytes = 8 << 10

    private var line = Data()
    private var data = Data()
    private var eventName: String?
    private var text = ""
    private var byteCount = 0
    private var pendingCR = false
    private(set) var summary = ""

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
        if data.elementsEqual("[DONE]".utf8) { return nil }
        let event: Event
        do {
            event = try JSONDecoder().decode(Event.self, from: data)
        } catch {
            throw ChatServiceError("ChatGPT returned a malformed reply stream.")
        }
        if let eventName, !eventName.isEmpty, let type = event.type, eventName != type {
            throw ChatServiceError("ChatGPT returned an inconsistent reply stream.")
        }
        switch event.type ?? eventName {
        case "response.output_item.added":
            guard event.item?.type == "reasoning", summary.isEmpty else { return nil }
            return .activity(.thinking)
        case "response.reasoning_text.delta", "response.reasoning_text.done":
            return summary.isEmpty ? .activity(.thinking) : nil
        case "response.reasoning_summary_text.delta":
            guard let delta = event.delta, !delta.isEmpty else { return nil }
            appendSummary(delta)
            return summary.isEmpty ? nil : .activity(.summary(summary))
        case "response.reasoning_summary_text.done", "response.reasoning_summary_part.done":
            let text = event.text ?? event.part?.text
            if summary.isEmpty, let text, !text.isEmpty { appendSummary(text) }
            return summary.isEmpty ? nil : .activity(.summary(summary))
        case "response.reasoning_summary_part.added":
            return summary.isEmpty ? .activity(.thinking) : nil
        case "response.output_item.done":
            guard let item = event.item, item.type == "reasoning" else { return nil }
            captureSummary(from: [item])
            return summary.isEmpty ? nil : .activity(.summary(summary))
        case "response.output_text.delta":
            guard let delta = event.delta, !delta.isEmpty else { return nil }
            text += delta
            return .snapshot(text)
        case "response.refusal.delta", "response.refusal.done":
            throw ChatServiceError("ChatGPT declined to answer this prompt.")
        case "response.failed", "error":
            let detail = event.response?.error ?? event.error
            throw ResponsesClient.providerError(code: detail?.code ?? event.code)
        case "response.incomplete":
            throw ChatServiceError("ChatGPT stopped before finishing the reply.")
        case "response.completed":
            guard let response = event.response, response.status == "completed", response.error == nil else {
                let detail = event.response?.error ?? event.error
                throw ResponsesClient.providerError(code: detail?.code ?? event.code)
            }
            captureSummary(from: response.output ?? [])
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
        default:
            return nil
        }
    }

    private mutating func appendSummary(_ value: String) {
        guard summary.utf8.count < Self.maxSummaryBytes else { return }
        let remaining = Self.maxSummaryBytes - summary.utf8.count
        if value.utf8.count <= remaining {
            summary += value
        } else {
            summary += String(decoding: value.utf8.prefix(remaining), as: UTF8.self)
        }
    }

    private mutating func captureSummary(from items: [Item]) {
        guard summary.isEmpty else { return }
        for item in items where item.type == "reasoning" {
            for part in item.summary ?? [] where part.type == "summary_text" {
                if let text = part.text, !text.isEmpty { appendSummary(text) }
            }
        }
    }
}
