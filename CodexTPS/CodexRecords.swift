import Darwin
import Foundation
import SQLite3

struct CodexPaths {
    let home: URL

    static var local: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]
        return Self(home: configured.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex", isDirectory: true))
    }

    var index: URL { home.appendingPathComponent("state_5.sqlite") }
    var log: URL { home.appendingPathComponent("logs_2.sqlite") }
    var sharedSocket: URL { home.appendingPathComponent("app-server-control/app-server-control.sock") }
}

struct SendMarker: Equatable {
    let turn: String
    let at: Date
}

struct RecordedUsage: Equatable {
    let id: String
    let turn: String
    let at: Date
    let output: Int?
    let input: Int?
    let cached: Int?
}

struct TurnStart: Equatable {
    let id: String
    let at: Date
}

struct TurnEnd: Equatable {
    let id: String
    let at: Date
    let phase: TurnPhase
}

struct ReplyMetrics {
    struct Reply {
        let usage: RecordedUsage
        let elapsed: TimeInterval?

        var speed: Double? {
            guard let output = usage.output, output > 0, let elapsed, elapsed > 0 else { return nil }
            return Double(output) / elapsed
        }
    }

    let replies: [Reply]
    let average: Double?
    let cacheHit: Double?

    init(usage: [RecordedUsage], sends: [SendMarker]) {
        var seen = Set<String>()
        let records = usage.sorted { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
            .filter { seen.insert($0.id).inserted }
        let byTurn = Dictionary(grouping: sends, by: \.turn)
        var lastEnd: [String: Date] = [:]
        var replies: [Reply] = []
        var output = 0.0
        var elapsed = 0.0
        var cached = 0.0
        var input = 0.0
        var completeCacheCounts = true
        for usage in records {
            let lower = lastEnd[usage.turn] ?? .distantPast
            let candidates = byTurn[usage.turn, default: []].filter { $0.at > lower && $0.at < usage.at }
            let duration = candidates.count == 1 ? usage.at.timeIntervalSince(candidates[0].at) : nil
            let reply = Reply(usage: usage, elapsed: duration)
            replies.append(reply)
            if let value = usage.output, value > 0, let duration, duration > 0 {
                output += Double(value)
                elapsed += duration
            }
            if let total = usage.input, let hit = usage.cached, total >= hit, hit >= 0 {
                input += Double(total)
                cached += Double(hit)
            } else {
                completeCacheCounts = false
            }
            lastEnd[usage.turn] = usage.at
        }
        self.replies = replies
        average = elapsed > 0 ? output / elapsed : nil
        cacheHit = completeCacheCounts && input > 0 ? cached / input : nil
    }

    var lastRate: Double? { replies.reversed().lazy.compactMap(\.speed).first }
}

struct ChatMetadata: Equatable {
    let id: String
    let title: String
    let client: CodexClient
    let rollout: URL
    let updated: Date
}

struct History: Equatable {
    var usage: [String: RecordedUsage] = [:]
    var lastStart: TurnStart?
    var lastEnd: TurnEnd?
    private var latestStartEnd: TurnEnd?
    private var watchedTurn: String?
    private(set) var watchedEnd: TurnEnd?
    var context: ContextUsage?
    var savedAssistantAt: Date?
    private var erroredTurn: String?

    var openTurn: TurnStart? {
        guard let start = lastStart, latestStartEnd?.id != start.id, lastEnd?.id != start.id,
              watchedEnd?.id != start.id else { return nil }
        return start
    }

    func end(of id: String) -> TurnEnd? {
        [latestStartEnd, watchedEnd, lastEnd].compactMap { $0 }.first { $0.id == id }
    }

    mutating func watch(_ id: String?) {
        guard watchedTurn != id else { return }
        watchedTurn = id
        watchedEnd = lastEnd?.id == id ? lastEnd : nil
    }

    mutating func resetForReplay() {
        let id = watchedTurn
        self = History()
        watch(id)
    }

    mutating func ingest(_ bytes: Data) {
        guard let row = JSON.object(bytes), let payload = row["payload"] as? [String: Any],
              let time = row["timestamp"] as? String, let at = Self.parse(time) else { return }
        let turn = payload["turn_id"] as? String
        if row["type"] as? String == "token_usage_record",
           let id = payload["response_id"] as? String, usage[id] == nil,
           let turn, let counters = payload["usage"] as? [String: Any] {
            usage[id] = RecordedUsage(id: id, turn: turn, at: at,
                                     output: counters["output_tokens"] as? Int,
                                     input: counters["input_tokens"] as? Int,
                                     cached: counters["cached_input_tokens"] as? Int)
            return
        }

        switch payload["type"] as? String {
        case "task_started", "turn_started":
            if let turn, (lastStart?.at ?? .distantPast) <= at {
                if lastStart?.id != turn { latestStartEnd = nil }
                lastStart = TurnStart(id: turn, at: at)
                erroredTurn = nil
            }
        case "task_complete", "turn_complete", "turn_aborted":
            if let id = turn ?? lastStart?.id {
                let phase: TurnPhase
                if payload["type"] as? String == "turn_aborted" { phase = .interrupted }
                else if erroredTurn == id || payload["status"] as? String == "failed" { phase = .failed }
                else { phase = .completed }
                let end = TurnEnd(id: id, at: at, phase: phase)
                if id == lastStart?.id { latestStartEnd = end }
                if (lastEnd?.at ?? .distantPast) <= at { lastEnd = end }
                if id == watchedTurn { watchedEnd = end }
            }
        case "error":
            erroredTurn = turn ?? lastStart?.id
        case "token_count":
            if let info = payload["info"] as? [String: Any] {
                let used = (info["last_token_usage"] as? [String: Any])?["total_tokens"] as? Int
                let capacity = info["model_context_window"] as? Int
                if used != nil || capacity != nil { context = ContextUsage(used: used, capacity: capacity) }
            }
        case "agent_message", "message":
            if payload["type"] as? String == "agent_message" || payload["role"] as? String == "assistant" {
                savedAssistantAt = at
            }
        default: break
        }
    }

    private static func parse(_ time: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(time))
            ?? (try? Date.ISO8601FormatStyle().parse(time))
    }
}

enum JSON {
    static func object(_ bytes: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }
}

final class ReadOnlyDatabase {
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ file: stat) {
            device = file.st_dev
            inode = file.st_ino
        }
    }

    private struct ReadFailure: Error {
        let status: Int32
    }

    private static let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
    private let path: URL
    private var identity: FileIdentity?
    private var handle: OpaquePointer?

    init(_ path: URL) { self.path = path }
    deinit { if let handle { sqlite3_close(handle) } }

    var isMissing: Bool {
        var file = stat()
        return stat(path.path, &file) != 0 && errno == ENOENT
    }

    func query<T>(_ sql: String, bindings: [String] = [], row: (OpaquePointer) -> T?) -> [T]? {
        do {
            guard let handle = try liveConnection() else { return nil }
            return try read(sql, bindings: bindings, in: handle, row: row)
        } catch let failure as ReadFailure where failure.status & 0xff == SQLITE_CANTOPEN {
            return readCheckpoint(sql, bindings: bindings, row: row)
        } catch {
            return nil
        }
    }

    private func liveConnection() throws -> OpaquePointer? {
        var file = stat()
        guard stat(path.path, &file) == 0 else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            return nil
        }
        let current = FileIdentity(file)
        if identity == current, let handle { return handle }
        if let handle { sqlite3_close(handle) }
        handle = nil
        let opened = try Self.open(path.path, flags: Self.flags)
        sqlite3_busy_timeout(opened, 120)
        identity = current
        handle = opened
        return opened
    }

    private func readCheckpoint<T>(_ sql: String, bindings: [String], row: (OpaquePointer) -> T?) -> [T]? {
        let source = path.resolvingSymlinksInPath()
        guard let before = Self.checkpointedFile(at: source.path),
              var uri = URLComponents(url: source, resolvingAgainstBaseURL: false) else { return nil }
        uri.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        guard let filename = uri.string,
              let reader = try? Self.open(filename, flags: Self.flags | SQLITE_OPEN_URI) else { return nil }
        defer { sqlite3_close(reader) }
        let rows = try? read(sql, bindings: bindings, in: reader, row: row)

        // Accept only a stable main file and never retain this connection across queries.
        guard let after = Self.checkpointedFile(at: source.path), Self.sameVersion(before, after) else { return nil }
        return rows
    }

    private static func checkpointedFile(at path: String) -> stat? {
        var file = stat()
        for suffix in ["-wal", "-shm", "-journal"] {
            guard lstat(path + suffix, &file) != 0, errno == ENOENT else { return nil }
        }
        guard lstat(path, &file) == 0, file.st_mode & S_IFMT == S_IFREG else { return nil }
        return file
    }

    private static func sameVersion(_ before: stat, _ after: stat) -> Bool {
        FileIdentity(before) == FileIdentity(after) && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    private static func open(_ name: String, flags: Int32) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(name, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw ReadFailure(status: status)
        }
        return handle
    }

    private func read<T>(_ sql: String, bindings: [String], in handle: OpaquePointer,
                         row: (OpaquePointer) -> T?) throws -> [T] {
        var prepared: OpaquePointer?
        var status = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
        guard status == SQLITE_OK, let prepared else { throw ReadFailure(status: status) }
        defer { sqlite3_finalize(prepared) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in bindings.enumerated() {
            status = sqlite3_bind_text(prepared, Int32(i + 1), value, -1, transient)
            guard status == SQLITE_OK else { throw ReadFailure(status: status) }
        }
        var result: [T] = []
        status = sqlite3_step(prepared)
        while status == SQLITE_ROW {
            if let value = row(prepared) { result.append(value) }
            status = sqlite3_step(prepared)
        }
        guard status == SQLITE_DONE else { throw ReadFailure(status: status) }
        return result
    }

    static func string(_ row: OpaquePointer, _ field: Int32) -> String? {
        sqlite3_column_text(row, field).map { String(cString: $0) }
    }
}

/// Keeps an incremental cursor at the last complete record, including through a partial write.
private final class Rollout {
    var history = History()
    private var offset: UInt64 = 0
    private var identity: NSNumber?
    private var pending = Data()
    private var skippingLargeLine = false
    private static let fields = ["token_usage_record", "task_started", "task_complete", "turn_started",
                                 "turn_complete", "turn_aborted", "token_count", "agent_message",
                                 "\"role\":\"assistant\"", "\"type\":\"error\""].map { Data($0.utf8) }

    func update(_ path: URL, budget: Int) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let file = attributes[.systemFileNumber] as? NSNumber,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return 0 }
        if file != identity || size < offset {
            identity = file
            offset = 0
            pending.removeAll()
            skippingLargeLine = false
            history.resetForReplay()
        }
        guard offset < size, let file = try? FileHandle(forReadingFrom: path) else { return 0 }
        defer { try? file.close() }
        do {
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: budget), !data.isEmpty else { return 0 }
            offset += UInt64(data.count)
            var start = data.startIndex
            while let newline = data[start...].firstIndex(of: 10) {
                if !skippingLargeLine, pending.count + newline - start <= 2_097_152 {
                    pending.append(contentsOf: data[start..<newline])
                    if Self.fields.contains(where: { pending.range(of: $0) != nil }) { history.ingest(pending) }
                }
                pending.removeAll(keepingCapacity: true)
                skippingLargeLine = false
                start = newline + 1
            }
            if !skippingLargeLine {
                if pending.count + data.endIndex - start <= 2_097_152 { pending.append(contentsOf: data[start...]) }
                else { pending.removeAll(); skippingLargeLine = true }
            }
            return data.count
        } catch { return 0 }
    }
}

final class CodexRecords {
    private enum IndexState { case missing, ready, unreadable }

    private let index: ReadOnlyDatabase
    private let logs: ReadOnlyDatabase
    private var indexState = IndexState.missing
    private var rollouts: [String: Rollout] = [:]
    private(set) var chats: [String: ChatMetadata] = [:]

    var indexAvailable: Bool { indexState == .ready }
    var indexReadFailed: Bool { indexState == .unreadable }

    init(paths: CodexPaths) {
        index = ReadOnlyDatabase(paths.index)
        logs = ReadOnlyDatabase(paths.log)
    }

    func update(prioritize ids: Set<String>) {
        let select = """
            SELECT id, coalesce(nullif(name, ''), title), originator, rollout_path, cwd,
                   coalesce(updated_at_ms, updated_at * 1000) AS effective_update
            FROM threads WHERE originator IN ('Codex Desktop', 'codex-tui')
                AND source NOT LIKE '%subagent%' AND agent_role IS NULL
                AND agent_path IS NULL AND attached_thread_parent_id IS NULL AND archived = 0
            """
        func metadata(_ row: OpaquePointer) -> ChatMetadata? {
            guard let id = ReadOnlyDatabase.string(row, 0),
                  let origin = ReadOnlyDatabase.string(row, 2), let client = CodexClient(originator: origin),
                  let path = ReadOnlyDatabase.string(row, 3) else { return nil }
            let title = ReadOnlyDatabase.string(row, 1)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let project = ReadOnlyDatabase.string(row, 4).map { URL(fileURLWithPath: $0).lastPathComponent }
            let fallback = "\(project ?? "Codex") · \(id.suffix(6))"
            return ChatMetadata(id: id, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? fallback,
                                client: client, rollout: URL(fileURLWithPath: path),
                                updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 5)) / 1000))
        }
        guard var rows = index.query(select + " ORDER BY effective_update DESC, id ASC LIMIT 24", row: metadata) else {
            indexState = index.isMissing ? .missing : .unreadable
            return
        }
        let missing = ids.subtracting(rows.map(\.id))
        for id in missing {
            guard let extra = index.query(select + " AND id = ?", bindings: [id], row: metadata) else {
                indexState = .unreadable
                return
            }
            rows.append(contentsOf: extra)
        }
        indexState = .ready
        chats = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        rollouts = rollouts.filter { chats[$0.key] != nil }
        let priority = rows.filter { ids.contains($0.id) } + rows.filter { !ids.contains($0.id) }
        var remaining = 12_582_912
        for chat in priority where remaining > 0 {
            let rollout = rollouts[chat.id] ?? Rollout()
            rollouts[chat.id] = rollout
            remaining -= rollout.update(chat.rollout, budget: min(remaining, 2_097_152))
        }
    }

    func history(for id: String) -> History { rollouts[id]?.history ?? History() }

    func watchTurn(_ turn: String?, in chat: String) { rollouts[chat]?.history.watch(turn) }

    func sends(for id: String) -> [SendMarker]? {
        logs.query("""
            SELECT ts, ts_nanos, feedback_log_body FROM logs
            WHERE thread_id=? AND target='feedback_tags'
                AND feedback_log_body LIKE '%responses_websocket.stream_request%'
            ORDER BY ts, ts_nanos
            """, bindings: [id]) { row in
                guard let body = ReadOnlyDatabase.string(row, 2),
                      let turn = Self.turnInSendMarker(body, chat: id) else { return nil }
                let time = Double(sqlite3_column_int64(row, 0)) + Double(sqlite3_column_int64(row, 1)) / 1e9
                return SendMarker(turn: turn, at: Date(timeIntervalSince1970: time))
            }
    }

    private static let sendChat = try! NSRegularExpression(pattern: #"conversation\.id\s*[=:]\s*"?([\da-f-]{36})"#)
    private static let sendTurn = try! NSRegularExpression(pattern: #"(?:turn\.id|turn_id)\s*[=:]\s*"?([\da-f-]{36})"#)
    private static let authError = try! NSRegularExpression(pattern: #"\bauth_error\s*=\s*"[^"]+""#)

    static func turnInSendMarker(_ body: String, chat: String) -> String? {
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        guard body.contains("websocket.warmup=false"),
              authError.firstMatch(in: body, range: range) == nil else { return nil }
        func values(_ regex: NSRegularExpression) -> Set<String> {
            Set(regex.matches(in: body, range: range).compactMap {
                Range($0.range(at: 1), in: body).map { String(body[$0]) }
            })
        }
        guard values(sendChat) == [chat] else { return nil }
        let turns = values(sendTurn)
        return turns.count == 1 ? turns.first : nil
    }
}
