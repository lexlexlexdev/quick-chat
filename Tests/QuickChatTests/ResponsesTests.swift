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

@Test func followUpSendsLocalContextWithoutRequestingProviderStorage() throws {
    let turns = [ChatTurn(role: .user, text: "Say Swift"), ChatTurn(role: .assistant, text: "Swift"), ChatTurn(role: .user, text: "Repeat it")]
    let body = try ResponsesClient.body(model: "gpt-test", turns: turns)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["store"] as? Bool == false)
    #expect(json["stream"] as? Bool == true)
    let input = try #require(json["input"] as? [[String: Any]])
    #expect(input.compactMap { $0["role"] as? String } == ["user", "assistant", "user"])
    let parts = try #require(input.map { ($0["content"] as? [[String: Any]])?.first } as? [[String: Any]])
    #expect(parts.compactMap { $0["type"] as? String } == ["input_text", "output_text", "input_text"])
    #expect(parts.compactMap { $0["text"] as? String } == ["Say Swift", "Swift", "Repeat it"])
    #expect(parts[1]["annotations"] as? [String] == [])
}

@Test func chatGPTPlanCatalogUsesVisibleSlugsAndProviderDisplayOrder() throws {
    let catalog = """
    {"models":[
      {"slug":"new-model","display_name":"New model","visibility":"list"},
      {"slug":"private-model","display_name":"Hidden","visibility":"hidden"},
      {"slug":"gpt-mini","display_name":"","visibility":"list"},
      {"slug":"new-model","display_name":"New model","visibility":"list"}
    ]}
    """
    #expect(try ResponsesClient.decodeCatalog(Data(catalog.utf8)) == [
        ChatModelOption(id: "new-model", name: "New model"),
        ChatModelOption(id: "gpt-mini", name: "gpt-mini")
    ])
}
