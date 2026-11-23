import Testing
@testable import QuickChat

@Test func historySwitchRestoresTranscriptAndDraftWithoutReordering() {
    var history = ChatHistory()
    let first = history.active.id
    history.active.exchanges.append(.init(prompt: "First question\nMore detail", reply: "First answer", state: .complete))
    history.active.draft = "Unsent follow-up"
    history.startNew()
    let second = history.active.id
    history.active.draft = "Another draft"

    history.select(first)
    #expect(history.active.draft == "Unsent follow-up")
    #expect(history.active.exchanges.first?.reply == "First answer")
    #expect(history.entries.map(\.id) == [second, first])
    #expect(history.entries.map(\.title) == ["Another draft", "First question"])

    history.select(second)
    #expect(history.active.draft == "Another draft")
    #expect(history.active.exchanges.isEmpty)
}

@Test func switchingFromAnUntitledChatDoesNotAddItToHistory() {
    var history = ChatHistory()
    let first = history.active.id
    history.active.draft = "A draft"
    history.startNew()
    history.active.draft = " \n "
    history.select(first)
    #expect(history.entries.map(\.id) == [first])
}
