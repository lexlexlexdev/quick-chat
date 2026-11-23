import Combine
import Foundation
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

@Test func sqliteHistoryRestoresDraftsAndTranscriptWithoutMixingAccounts() throws {
    try withTemporaryHistoryFile { file in
        var history = ChatHistory()
        let firstID = history.active.id
        var exchange = ChatModel.Exchange(prompt: "What's in the café?", reply: "☕", state: .complete)
        exchange.reasoningSummary = "Public summary"
        history.active.exchanges.append(exchange)
        let secondID: UUID
        do {
            let store = try ChatHistoryStore(file: file, scope: "first")
            try store.save(history.active)
            history.active.draft = "Unsent follow-up"
            try store.save(history.active)
            history.startNew()
            secondID = history.active.id
            history.active.draft = "Second draft"
            try store.save(history.active)
        }

        let other = try ChatHistoryStore(file: file, scope: "second")
        #expect(try other.load().entries.isEmpty)
        var otherChat = ChatHistory.Conversation(id: firstID, order: 0, draft: "Another account")
        try other.save(otherChat)
        otherChat.draft = ""
        try other.save(otherChat)
        #expect(try other.load().entries.isEmpty)

        let reopened = try ChatHistoryStore(file: file, scope: "first")
        var restored = try reopened.load()
        #expect(restored.entries.map(\.id) == [secondID, firstID])
        restored.select(firstID)
        #expect(restored.active.draft == "Unsent follow-up")
        let reply = try #require(restored.active.exchanges.first)
        #expect(reply.id == exchange.id)
        #expect(reply.reply == "☕")
        #expect(reply.reasoningSummary == "Public summary")
    }
}

@Test func sqliteHistoryRestoresInterruptedReplyAsStopped() throws {
    try withTemporaryHistoryFile { file in
        let pending = ChatHistory.Conversation(order: 0, exchanges: [.init(prompt: "Preserve my prompt")])
        do {
            let store = try ChatHistoryStore(file: file, scope: "account")
            try store.save(pending)
        }
        let reopened = try ChatHistoryStore(file: file, scope: "account")
        let reply = try #require(reopened.load().active.exchanges.first)
        #expect(reply.prompt == "Preserve my prompt")
        guard case .stopped = reply.state else {
            Issue.record("A reply cannot keep running after the process exits")
            return
        }
    }
}

@Test func backgroundReplyFinishesInOriginalChatWithoutChangingCurrentDraft() throws {
    var history = ChatHistory()
    let originatingChat = history.active.id
    let exchange = ChatModel.Exchange(prompt: "First prompt")
    history.active.exchanges.append(exchange)
    history.startNew()
    let foregroundChat = history.active.id
    history.active.draft = "New draft"
    history.active.exchanges.append(.init(prompt: "Second prompt"))

    let result = history.finishReply(chatID: originatingChat, exchangeID: exchange.id,
                                     text: "First answer", summary: "", state: .complete)
    let completed = try #require(result)
    #expect(completed.id == originatingChat)
    #expect(history.active.id == foregroundChat)
    #expect(history.active.draft == "New draft")
    #expect(history.active.exchanges.last?.reply == "")
    history.select(originatingChat)
    #expect(history.active.exchanges.last?.reply == "First answer")
}

@Test func returningToStreamingChatReceivesTextProducedWhileAway() {
    let source = ReplySource()
    var first: [String] = []
    let reader = source.snapshots.sink { first.append($0) }
    source.update("Start")
    #expect(first.last == "Start")
    reader.cancel()

    source.update("Start plus background text")
    var reopened: [String] = []
    let reopenedReader = source.snapshots.sink { reopened.append($0) }
    #expect(reopened == ["Start plus background text"])
    reopenedReader.cancel()
}

private func withTemporaryHistoryFile(_ run: (URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    try run(folder.appendingPathComponent("history.sqlite3"))
}
