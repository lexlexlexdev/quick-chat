import Foundation
import Testing
@testable import QuickChat

@Test func responseStreamAccumulatesUTF8AndAcceptsCanonicalCompletion() throws {
    var stream = ResponsesStream()
    let input = [
        ": keep-alive\r\n\r\n",
        "event: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\r\ndata: \"delta\":\"café ☕\"}\r\n\r\n",
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"!\"}\n\n",
        "event: response.completed\ndata: {\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\"},{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"café ☕!\"}]}]}}\n\n"
    ].joined()
    let updates = try input.utf8.compactMap { try stream.receive($0) }
    #expect(updates == [.snapshot("café ☕"), .snapshot("café ☕!"), .complete("café ☕!")])
}

@Test func streamedTextDoesNotCommitAnIncompleteReply() throws {
    var stream = ResponsesStream()
    let partial = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"
    #expect(try partial.utf8.compactMap { try stream.receive($0) } == [.snapshot("partial")])
    let incomplete = "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\"}}\n\n"
    #expect(throws: ChatServiceError.self) {
        try incomplete.utf8.compactMap { try stream.receive($0) }
    }
}

@Test func responseStreamRejectsTerminalTextThatContradictsRenderedText() throws {
    var stream = ResponsesStream()
    let input = """
    data: {"type":"response.output_text.delta","delta":"shown"}

    data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"different"}]}]}}


    """
    #expect(throws: ChatServiceError.self) {
        try input.utf8.compactMap { try stream.receive($0) }
    }
}

@Test func responseStreamReportsOnlyPublicSummaryAndThinkingActivity() throws {
    var stream = ResponsesStream()
    let input = """
    data: {"type":"response.output_item.added","item":{"type":"reasoning"}}

    data: {"type":"response.reasoning_text.delta","delta":"hidden chain of thought"}

    data: {"type":"response.reasoning_summary_text.delta","delta":"Checked "}

    data: {"type":"response.reasoning_summary_text.delta","delta":"the code"}

    data: {"type":"response.output_text.delta","delta":"Done"}

    data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","content":[{"type":"reasoning_text","text":"hidden chain of thought"}],"summary":[{"type":"summary_text","text":"Checked the code"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}]}}


    """
    let updates = try input.utf8.compactMap { try stream.receive($0) }
    #expect(updates == [
        .activity(.thinking),
        .activity(.thinking),
        .activity(.summary("Checked ")),
        .activity(.summary("Checked the code")),
        .snapshot("Done"),
        .complete("Done")
    ])
    #expect(stream.summary == "Checked the code")
}

@Test func responseStreamCollectsPublicSummaryFromCompletedOutput() throws {
    var stream = ResponsesStream()
    let input = """
    data: {"type":"response.output_text.delta","delta":"Done"}

    data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"Provider summary"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}]}}


    """
    let updates = try input.utf8.compactMap { try stream.receive($0) }
    #expect(updates == [.snapshot("Done"), .complete("Done")])
    #expect(stream.summary == "Provider summary")
}

@Test func followUpSendsLocalContextWithoutRequestingProviderStorage() throws {
    let turns = [ChatTurn(role: .user, text: "Say Swift"), ChatTurn(role: .assistant, text: "Swift"), ChatTurn(role: .user, text: "Repeat it")]
    let body = try ResponsesClient.body(model: "gpt-test", turns: turns)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["store"] as? Bool == false)
    #expect(json["stream"] as? Bool == true)
    #expect(json["reasoning"] == nil)
    let input = try #require(json["input"] as? [[String: Any]])
    #expect(input.compactMap { $0["role"] as? String } == ["user", "assistant", "user"])
    let parts = try #require(input.map { ($0["content"] as? [[String: Any]])?.first } as? [[String: Any]])
    #expect(parts.compactMap { $0["type"] as? String } == ["input_text", "output_text", "input_text"])
    #expect(parts.compactMap { $0["text"] as? String } == ["Say Swift", "Swift", "Repeat it"])
    #expect(parts[1]["annotations"] as? [String] == [])
}

@Test func reasoningEffortAndSummaryAreOptionalAndNeverSentForNone() throws {
    let turns = [ChatTurn(role: .user, text: "Hi")]

    let plain = try jsonObject(ResponsesClient.body(model: "gpt-test", turns: turns))
    #expect(plain["reasoning"] == nil)

    let defaultEffortWithSummary = try jsonObject(ResponsesClient.body(model: "gpt-test", turns: turns, requestSummary: true))
    let defaultReasoning = try #require(defaultEffortWithSummary["reasoning"] as? [String: Any])
    #expect(defaultReasoning["effort"] == nil)
    #expect(defaultReasoning["summary"] as? String == "auto")

    let high = try jsonObject(ResponsesClient.body(model: "gpt-test", turns: turns, reasoning: .high, requestSummary: true))
    let highReasoning = try #require(high["reasoning"] as? [String: Any])
    #expect(highReasoning["effort"] as? String == "high")
    #expect(highReasoning["summary"] as? String == "auto")

    let none = try jsonObject(ResponsesClient.body(model: "gpt-test", turns: turns, reasoning: ReasoningLevel.none, requestSummary: true))
    let noneReasoning = try #require(none["reasoning"] as? [String: Any])
    #expect(noneReasoning["effort"] as? String == "none")
    #expect(noneReasoning["summary"] == nil)
}

@Test func chatCatalogOffersOnlyVisibleLunaAndTerraInProviderOrder() throws {
    let catalog = """
    {"models":[
      {"slug":"other-model","visibility":"list"},
      {"slug":"gpt-6-luna","visibility":"hidden"},
      {"slug":"gpt-6.1-terra","visibility":"list"},
      {"slug":"gpt-6-luna","visibility":"list"},
      {"slug":"gpt-6.1-terra","visibility":"list"}
    ]}
    """
    let options = try ResponsesClient.decodeCatalog(Data(catalog.utf8))
    #expect(options.map(\.id) == ["gpt-6.1-terra", "gpt-6-luna"])
    #expect(options.map(\.name) == ["GPT-6.1 Terra", "GPT-6 Luna"])
}

@Test func catalogUsesAuthoritativeReasoningMetadataAndDropsUnknownEfforts() throws {
    let catalog = """
    {"models":[
      {"slug":"gpt-6-luna","display_name":"GPT-6-Luna","visibility":"list","supported_reasoning_levels":[
        {"effort":"none","description":"Even if supplied, only show it once"},
        {"effort":"low","description":"Fast"},
        {"effort":"medium","description":"Balanced"},
        {"effort":"high","description":"Deep"},
        {"effort":"xhigh","description":"Extra deep"},
        {"effort":"max","description":"Maximum"},
        {"effort":"ultra","description":"Unknown to this app"}
      ]},
      {"slug":"gpt-6.1-terra","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]}
    ]}
    """
    let options = try ResponsesClient.decodeCatalog(Data(catalog.utf8))
    #expect(options.map(\.id) == ["gpt-6-luna", "gpt-6.1-terra"])
    #expect(options[0].reasoningLevels == [.none, .low, .medium, .high, .xhigh, .max])
    #expect(options[1].reasoningLevels == [.none, .low, .high])
    #expect(options[1].preferredReasoning(nil) == ReasoningLevel.none)
}

@Test func catalogFallsBackToVerifiedModelFactsOnlyWhenMetadataIsMissing() throws {
    let catalog = """
    {"models":[
      {"slug":"gpt-6-luna","display_name":"GPT-6-Luna","visibility":"list"},
      {"slug":"gpt-6.1-terra","visibility":"list"}
    ]}
    """
    let options = try ResponsesClient.decodeCatalog(Data(catalog.utf8))
    #expect(options[0].reasoningLevels == [.none, .low, .medium, .high, .xhigh, .max])
    #expect(options[1].reasoningLevels == [.none, .low, .medium, .high, .xhigh, .max])
    #expect(options[0].preferredReasoning(nil) == ReasoningLevel.none)
    #expect(options[0].preferredReasoning(.minimal) == ReasoningLevel.none)
    #expect(options[0].preferredReasoning(.high) == .high)
}

@Test
@MainActor
func streamUsesSSEFramingDespiteMislabeledContentType() async throws {
    let host = "sse-mislabeled-\(UUID().uuidString).test"
    let payload = """
    event: response.output_item.added
    data: {"type":"response.output_item.added","item":{"type":"reasoning"}}

    event: response.reasoning_summary_text.delta
    data: {"type":"response.reasoning_summary_text.delta","delta":"Checking the reply"}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"Hello"}

    event: response.completed
    data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}]}}


    """
    let log = StubRequestLog()
    StubURLProtocol.install(host: host) { request in
        log.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/plain; charset=utf-8",
                                                      "x-request-id": "req_mislabeled"])!
        return (response, Data(payload.utf8))
    }
    defer { StubURLProtocol.remove(host: host) }
    let session = makeStubSession()
    defer { session.invalidateAndCancel() }
    let client = ResponsesClient(endpoint: URL(string: "https://\(host)/v1")!, session: session)
    var snapshots: [String] = []
    var activities: [ReplyActivity] = []

    let final = try await client.stream(model: "gpt-6-luna",
                                        turns: [ChatTurn(role: .user, text: "Hi")],
                                        token: "test-token",
                                        reasoning: .medium,
                                        requestSummary: true,
                                        onActivity: { activities.append($0) },
                                        onSnapshot: { snapshots.append($0) })

    #expect(final == "Hello")
    #expect(snapshots == ["Hello"])
    #expect(activities == [.thinking, .summary("Checking the reply")])
    let request = try #require(log.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/v1/responses")
    #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
}

@Test
@MainActor
func streamUsesSSEFramingWithoutContentTypeHeader() async throws {
    let host = "sse-no-header-\(UUID().uuidString).test"
    let payload = """
    data: {"type":"response.output_text.delta","delta":"Hello"}

    data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}]}}


    """
    StubURLProtocol.install(host: host) { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: [:])!
        return (response, Data(payload.utf8))
    }
    defer { StubURLProtocol.remove(host: host) }
    let session = makeStubSession()
    defer { session.invalidateAndCancel() }
    let client = ResponsesClient(endpoint: URL(string: "https://\(host)/v1")!, session: session)
    var snapshots: [String] = []

    let final = try await client.stream(model: "gpt-test",
                                        turns: [ChatTurn(role: .user, text: "Hi")],
                                        token: "test-token",
                                        onSnapshot: { snapshots.append($0) })

    #expect(final == "Hello")
    #expect(snapshots == ["Hello"])
}

@Test
@MainActor
func structuredErrorInSuccessfulHTTPResponsePreservesProviderCode() async throws {
    let host = "sse-structured-\(UUID().uuidString).test"
    let payload = #"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"raw provider body text"}}"#
    StubURLProtocol.install(host: host) { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/plain; charset=utf-8",
                                                      "x-request-id": "req_structured"])!
        return (response, Data(payload.utf8))
    }
    defer { StubURLProtocol.remove(host: host) }
    let session = makeStubSession()
    defer { session.invalidateAndCancel() }
    let client = ResponsesClient(endpoint: URL(string: "https://\(host)/v1")!, session: session)

    do {
        _ = try await client.stream(model: "gpt-test",
                                    turns: [ChatTurn(role: .user, text: "Hi")],
                                    token: "test-token",
                                    onSnapshot: { _ in })
        Issue.record("Expected the provider error to surface.")
    } catch let error as ChatServiceError {
        #expect(error.message == "You reached your ChatGPT plan usage limit.")
        #expect(!error.message.contains("raw provider body text"))
    }
}

@Test
@MainActor
func structuredErrorKeepsUnknownProviderCodeWithoutRawBody() async throws {
    let host = "sse-code-\(UUID().uuidString).test"
    let payload = #"{"error":{"code":"unsupported_reasoning_option","message":"raw provider body text"}}"#
    StubURLProtocol.install(host: host) { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json",
                                                      "x-request-id": "req_code"])!
        return (response, Data(payload.utf8))
    }
    defer { StubURLProtocol.remove(host: host) }
    let session = makeStubSession()
    defer { session.invalidateAndCancel() }
    let client = ResponsesClient(endpoint: URL(string: "https://\(host)/v1")!, session: session)

    do {
        _ = try await client.stream(model: "gpt-test",
                                    turns: [ChatTurn(role: .user, text: "Hi")],
                                    token: "test-token",
                                    onSnapshot: { _ in })
        Issue.record("Expected the provider error to surface.")
    } catch let error as ChatServiceError {
        #expect(error.message.contains("code=unsupported_reasoning_option"))
        #expect(error.message.contains("request_id=req_code"))
        #expect(!error.message.contains("raw provider body text"))
    }
}

@Test
@MainActor
func successfulNonStreamingJSONIsRejectedInsteadOfAcceptedAsAReply() async throws {
    let host = "sse-nonstream-\(UUID().uuidString).test"
    let payload = #"{"id":"resp_1","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}]}"#
    StubURLProtocol.install(host: host) { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json",
                                                      "x-request-id": "req_nonstream"])!
        return (response, Data(payload.utf8))
    }
    defer { StubURLProtocol.remove(host: host) }
    let session = makeStubSession()
    defer { session.invalidateAndCancel() }
    let client = ResponsesClient(endpoint: URL(string: "https://\(host)/v1")!, session: session)

    do {
        _ = try await client.stream(model: "gpt-test",
                                    turns: [ChatTurn(role: .user, text: "Hi")],
                                    token: "test-token",
                                    onSnapshot: { _ in })
        Issue.record("Expected a non-streaming response to fail.")
    } catch let error as ChatServiceError {
        #expect(error.message.hasPrefix("ChatGPT returned a non-streaming reply."))
        #expect(error.message.contains("request_id=req_nonstream"))
        #expect(!error.message.contains("Hello"))
    }
}

@Test
@MainActor
func malformedJSONOnSuccessfulHTTPIsNotMasked() async throws {
    let host = "sse-malformed-\(UUID().uuidString).test"
    let payload = #"{"error":"#
    StubURLProtocol.install(host: host) { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html",
                                                      "x-request-id": "req_malformed"])!
        return (response, Data(payload.utf8))
    }
    defer { StubURLProtocol.remove(host: host) }
    let session = makeStubSession()
    defer { session.invalidateAndCancel() }
    let client = ResponsesClient(endpoint: URL(string: "https://\(host)/v1")!, session: session)

    do {
        _ = try await client.stream(model: "gpt-test",
                                    turns: [ChatTurn(role: .user, text: "Hi")],
                                    token: "test-token",
                                    onSnapshot: { _ in })
        Issue.record("Expected a malformed response to fail.")
    } catch let error as ChatServiceError {
        #expect(error.message.hasPrefix("ChatGPT returned a malformed reply."))
        #expect(error.message.contains("HTTP 200"))
        #expect(error.message.contains("text/html"))
        #expect(error.message.contains("request_id=req_malformed"))
    }
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func makeStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class StubRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(request)
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handlers: [String: (URLRequest) -> (HTTPURLResponse, Data)] = [:]

    static func install(host: String, handler: @escaping (URLRequest) -> (HTTPURLResponse, Data)) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host.lowercased()] = handler
    }

    static func remove(host: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: host.lowercased())
    }

    private static func handler(for host: String) -> ((URLRequest) -> (HTTPURLResponse, Data))? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[host.lowercased()]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let handler = Self.handler(for: url.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
