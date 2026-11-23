import Foundation
import SQLite3

final class ChatHistoryStore {
    private struct DatabaseError: Error {
        let code: Int32
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let db: OpaquePointer
    private let scope: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    convenience init(scope: String) throws {
        let folder = URL.applicationSupportDirectory.appendingPathComponent("Quick Chat", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try self.init(file: folder.appendingPathComponent("history.sqlite3"), scope: scope)
    }

    init(file: URL, scope: String) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw DatabaseError(code: result)
        }
        self.db = handle
        self.scope = scope
        try check(sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS chat_history (
                scope TEXT NOT NULL,
                id TEXT NOT NULL,
                touched REAL NOT NULL,
                conversation BLOB NOT NULL,
                PRIMARY KEY (scope, id)
            ) WITHOUT ROWID;
            """, nil, nil, nil))
    }

    deinit { sqlite3_close(db) }

    func load() throws -> ChatHistory {
        try statement("SELECT conversation FROM chat_history WHERE scope = ? ORDER BY touched DESC, id") { query in
            try bind(scope, to: 1, in: query)
            var conversations: [ChatHistory.Conversation] = []
            while true {
                let result = sqlite3_step(query)
                if result == SQLITE_DONE { return ChatHistory(restoring: conversations) }
                guard result == SQLITE_ROW else { throw DatabaseError(code: result) }
                guard let bytes = sqlite3_column_blob(query, 0) else { throw DatabaseError(code: SQLITE_CORRUPT) }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
                var conversation = try decoder.decode(ChatHistory.Conversation.self, from: data)
                if let index = conversation.exchanges.indices.last, case .replying = conversation.exchanges[index].state {
                    conversation.exchanges[index].state = .stopped
                }
                conversations.append(conversation)
            }
        }
    }

    func save(_ conversation: ChatHistory.Conversation) throws {
        guard conversation.entry != nil else {
            try statement("DELETE FROM chat_history WHERE scope = ? AND id = ?") { query in
                try bind(scope, to: 1, in: query)
                try bind(conversation.id.uuidString, to: 2, in: query)
                try stepWrite(query)
            }
            return
        }

        let payload = try encoder.encode(conversation)
        try statement("""
            INSERT INTO chat_history (scope, id, touched, conversation) VALUES (?, ?, ?, ?)
            ON CONFLICT (scope, id) DO UPDATE SET touched = excluded.touched, conversation = excluded.conversation
            """) { query in
            try bind(scope, to: 1, in: query)
            try bind(conversation.id.uuidString, to: 2, in: query)
            try check(sqlite3_bind_double(query, 3, Date().timeIntervalSince1970))
            try payload.withUnsafeBytes { bytes in
                try check(sqlite3_bind_blob64(query, 4, bytes.baseAddress, UInt64(bytes.count), Self.transient))
            }
            try stepWrite(query)
        }
    }

    private func statement<T>(_ sql: String, _ run: (OpaquePointer) throws -> T) throws -> T {
        var query: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &query, nil))
        guard let query else { throw DatabaseError(code: SQLITE_ERROR) }
        defer { sqlite3_finalize(query) }
        return try run(query)
    }

    private func bind(_ text: String, to index: Int32, in query: OpaquePointer) throws {
        try check(sqlite3_bind_text(query, index, text, -1, Self.transient))
    }

    private func stepWrite(_ query: OpaquePointer) throws {
        let result = sqlite3_step(query)
        guard result == SQLITE_DONE else { throw DatabaseError(code: result) }
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw DatabaseError(code: result) }
    }
}
