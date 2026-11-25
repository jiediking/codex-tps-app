import Foundation
import SQLite3
import XCTest
@testable import CodexTPS

final class StorageRecoveryTests: XCTestCase {
    func testRecentCandidatesUseTheEffectiveTimestampAndKeepPriorityIDs() throws {
        let paths = CodexPaths(home: try temporaryFolder())
        let rollout = paths.home.appendingPathComponent("rollout.jsonl")
        let quotedPath = rollout.path.replacingOccurrences(of: "'", with: "''")
        try """
        {"timestamp":"2026-11-23T10:00:00Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn"}}

        """.write(to: rollout, atomically: true, encoding: .utf8)
        try checkpointedMainFile(at: paths.index, sql: """
            CREATE TABLE threads(id TEXT PRIMARY KEY, name TEXT, title TEXT, originator TEXT,
                rollout_path TEXT, cwd TEXT, updated_at_ms INTEGER, updated_at INTEGER, source TEXT,
                agent_role TEXT, agent_path TEXT, attached_thread_parent_id TEXT, archived INTEGER);
            WITH RECURSIVE n(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM n WHERE value < 24)
                INSERT INTO threads SELECT printf('ms%02d', value), NULL, 'History', 'codex-tui',
                    '\(quotedPath)', '/', 1000, 1, 'cli', NULL, NULL, NULL, 0 FROM n;
            INSERT INTO threads VALUES ('newest', NULL, 'Seconds only', 'codex-tui',
                '\(quotedPath)', '/', NULL, 2, 'cli', NULL, NULL, NULL, 0);
            INSERT INTO threads VALUES ('priority', NULL, 'Priority', 'codex-tui',
                '\(quotedPath)', '/', 1, 0, 'cli', NULL, NULL, NULL, 0);
            """)
        let reader = CodexRecords(paths: paths)
        reader.update(prioritize: ["priority"])
        XCTAssertEqual(Set(reader.chats.keys),
                       Set((1...23).map { String(format: "ms%02d", $0) } + ["newest", "priority"]))
        let chat = try XCTUnwrap(reader.chats["newest"])
        let projection = projectConversation(chat, history: reader.history(for: chat.id), sends: [],
                                             live: nil, terminalEvent: nil, canShowLive: false,
                                             connected: false, now: Date())
        XCTAssertEqual(projection.row?.title, "Seconds only")
        XCTAssertEqual(projection.row?.active, false)
    }

    func testCheckpointedHistoryAndTimingLoadWithOnlyTheMainFiles() throws {
        let paths = CodexPaths(home: try temporaryFolder())
        let reader = CodexRecords(paths: paths)
        reader.update(prioritize: [])
        XCTAssertFalse(reader.indexReadFailed)

        let chat = "12345678-1234-4000-8000-123456789abc"
        let turn = "23456789-1234-4000-8000-123456789abc"
        let rollout = paths.home.appendingPathComponent("rollout.jsonl")
        let start = 1_790_000_000
        let end = Date(timeIntervalSince1970: Double(start + 10)).ISO8601Format()
        let records = """
        {"timestamp":"\(end)","type":"token_usage_record","payload":{"turn_id":"\(turn)","response_id":"reply","usage":{"output_tokens":600,"input_tokens":1000,"cached_input_tokens":800}}}
        {"timestamp":"\(end)","type":"event_msg","payload":{"type":"task_complete","turn_id":"\(turn)"}}
        """
        try (records + "\n").write(to: rollout, atomically: true, encoding: .utf8)
        let quotedPath = rollout.path.replacingOccurrences(of: "'", with: "''")
        try checkpointedMainFile(at: paths.index, sql: """
            CREATE TABLE threads(id TEXT PRIMARY KEY, name TEXT, title TEXT, originator TEXT,
                rollout_path TEXT, cwd TEXT, updated_at_ms INTEGER, updated_at INTEGER, source TEXT,
                agent_role TEXT, agent_path TEXT, attached_thread_parent_id TEXT, archived INTEGER);
            INSERT INTO threads VALUES ('\(chat)', NULL, 'History fixture', 'Codex Desktop',
                '\(quotedPath)', '/', \(start * 1000), \(start), 'cli', NULL, NULL, NULL, 0);
            """)
        try checkpointedMainFile(at: paths.log, sql: """
            CREATE TABLE logs(thread_id TEXT, target TEXT, feedback_log_body TEXT, ts INTEGER, ts_nanos INTEGER);
            INSERT INTO logs VALUES ('\(chat)', 'feedback_tags',
                'responses_websocket.stream_request conversation.id=\(chat) turn.id=\(turn) websocket.warmup=false',
                \(start), 0);
            """)

        reader.update(prioritize: [])
        XCTAssertTrue(reader.indexAvailable)
        XCTAssertFalse(reader.indexReadFailed)
        let metadata = try XCTUnwrap(reader.chats[chat])
        let history = reader.history(for: chat)
        XCTAssertEqual(history.lastEnd?.id, turn)
        let presentation = projectConversation(metadata, history: history, sends: reader.sends(for: chat),
                                               live: nil, terminalEvent: nil, canShowLive: false,
                                               connected: false, now: Date(timeIntervalSince1970: Double(start + 11)))
        XCTAssertEqual(presentation.row?.title, "History fixture")
        XCTAssertEqual(presentation.row?.active, false)
        XCTAssertEqual(presentation.row?.readout, .settled(60))
        XCTAssertEqual(presentation.row?.cacheHit, 0.8)
        XCTAssertEqual(reader.sends(for: "unrecorded"), [])
        for url in [paths.index, paths.log] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
        }
        try withWriter(at: paths.index) { writer in
            try execute("ALTER TABLE threads RENAME TO previous_threads", in: writer)
            reader.update(prioritize: [])
            XCTAssertFalse(reader.indexAvailable)
            XCTAssertTrue(reader.indexReadFailed)
            XCTAssertEqual(reader.chats[chat], metadata)
            try execute("CREATE TABLE threads AS SELECT * FROM previous_threads WHERE 0", in: writer)
            reader.update(prioritize: [])
            XCTAssertTrue(reader.indexAvailable)
            XCTAssertFalse(reader.indexReadFailed)
            XCTAssertTrue(reader.chats.isEmpty)
        }
    }

    func testCheckpointReaderSeesNewUncheckpointedRowsWhenAWriterReturns() throws {
        let path = try temporaryFolder().appendingPathComponent("timing.sqlite")
        try checkpointedMainFile(at: path, sql: """
            CREATE TABLE starts(value INTEGER);
            INSERT INTO starts VALUES (40);
            """)
        let reader = ReadOnlyDatabase(path)
        func read(_ sql: String) -> [Int]? {
            reader.query(sql) { Int(sqlite3_column_int($0, 0)) }
        }
        let select = "SELECT value FROM starts ORDER BY value"
        XCTAssertEqual(read(select), [40])

        try withWriter(at: path) { writer in
            try execute("PRAGMA wal_autocheckpoint=0; INSERT INTO starts VALUES (60)", in: writer)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path + "-wal"))
            XCTAssertEqual(read(select), [40, 60])
            XCTAssertEqual(read("SELECT value FROM starts WHERE value=100"), [])
            XCTAssertNil(read("SELECT value FROM missing_table"))
        }
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Codex TPS #?% \(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func checkpointedMainFile(at target: URL, sql: String) throws {
        let seed = target.appendingPathExtension("seed")
        try withWriter(at: seed) { writer in
            try execute("PRAGMA journal_mode=WAL;\n" + sql, in: writer)
            XCTAssertEqual(sqlite3_wal_checkpoint_v2(writer, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil), SQLITE_OK)
        }
        // The closed, fully checkpointed fixture can be copied without its sidecars.
        try FileManager.default.copyItem(at: seed, to: target)
    }

    private func withWriter(at path: URL, _ body: (OpaquePointer) throws -> Void) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open(path.path, &handle)
        defer { if let handle { sqlite3_close(handle) } }
        guard status == SQLITE_OK, let handle else { throw NSError(domain: "SQLite", code: Int(status)) }
        try body(handle)
    }

    private func execute(_ sql: String, in handle: OpaquePointer) throws {
        let status = sqlite3_exec(handle, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw NSError(domain: "SQLite", code: Int(status)) }
    }
}
