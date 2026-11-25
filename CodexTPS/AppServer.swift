import CryptoKit
import Foundation
import Network

enum SignalKind: String, Codable {
    case heartbeat, active, idle, turnStarted, turnEnded, itemStarted, text
    case reasoning, reasoningEnded, toolStarted, toolEnded, lost
}

struct CodexSignal: Codable {
    var kind: SignalKind
    var thread: String = ""
    var turn: String?
    var item: String?
    var at = Date()
    var characters: Int?
    var phase: TurnPhase?
    var fromThreadRead: Bool? = nil

    static func from(_ packet: [String: Any]) -> Self? {
        guard let method = packet["method"] as? String,
              let p = packet["params"] as? [String: Any],
              let id = p["threadId"] as? String else { return nil }
        let turn = p["turn"] as? [String: Any]
        let turnID = p["turnId"] as? String ?? turn?["id"] as? String
        let item = p["item"] as? [String: Any]
        let itemID = p["itemId"] as? String ?? item?["id"] as? String
        let now = Date()
        switch method {
        case "thread/status/changed":
            return status(p["status"] as? [String: Any], thread: id)
        case "turn/started":
            let at = (turn?["startedAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? now
            return .init(kind: .turnStarted, thread: id, turn: turnID, at: at)
        case "turn/completed":
            let phase: TurnPhase
            switch turn?["status"] as? String {
            case "failed": phase = .failed
            case "interrupted", "cancelled": phase = .interrupted
            default: phase = .completed
            }
            return .init(kind: .turnEnded, thread: id, turn: turnID, phase: phase)
        case "item/agentMessage/delta":
            guard let text = p["delta"] as? String, !text.isEmpty else { return nil }
            return .init(kind: .text, thread: id, turn: turnID, item: itemID,
                         characters: text.unicodeScalars.count)
        case "item/reasoning/summaryPartAdded", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            return .init(kind: .reasoning, thread: id, turn: turnID, item: itemID)
        case "item/started", "item/completed":
            let started = method == "item/started"
            switch item?["type"] as? String {
            case "agentMessage" where started:
                let at = (p["startedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? now
                return .init(kind: .itemStarted, thread: id, turn: turnID, item: itemID, at: at)
            case "reasoning":
                return .init(kind: started ? .reasoning : .reasoningEnded, thread: id, turn: turnID, item: itemID)
            case "commandExecution" where started:
                let actions = item?["commandActions"] as? [[String: Any]] ?? []
                let inspection = !actions.isEmpty && actions.allSatisfy {
                    ["read", "listFiles", "search"].contains($0["type"] as? String ?? "")
                }
                return .init(kind: .toolStarted, thread: id, turn: turnID, item: itemID,
                             phase: inspection ? .reading : .runningTool)
            case "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch":
                return .init(kind: started ? .toolStarted : .toolEnded,
                             thread: id, turn: turnID, item: itemID)
            default: return nil
            }
        case "thread/closed":
            return .init(kind: .lost, thread: id)
        default: return nil
        }
    }

    static func status(_ value: [String: Any]?, thread: String) -> Self? {
        switch value?["type"] as? String {
        case "active":
            let flags = value?["activeFlags"] as? [String] ?? []
            let phase: TurnPhase? = flags.contains("waitingOnApproval") ? .awaitingApproval
                : flags.contains("waitingOnUserInput") ? .awaitingInput : nil
            return .init(kind: .active, thread: thread, phase: phase)
        case "idle":
            return .init(kind: .idle, thread: thread)
        case "notLoaded", "systemError":
            return .init(kind: .lost, thread: thread)
        default: return nil
        }
    }
}

protocol CLITransport: AnyObject {
    var onReady: (() -> Void)? { get set }
    var onMessage: ((Data) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    func start(on queue: DispatchQueue)
    func send(_ object: [String: Any])
    func close()
}

/// A WebSocket upgrade over the shared daemon's Unix stream. Network.framework
/// supplies the local byte stream; its automatic WebSocket upgrade expects an IP endpoint.
private final class UnixWebSocket: CLITransport {
    private let connection: NWConnection
    private let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    private var buffer = Data()
    private var multipart: Data?
    private var upgraded = false
    private var closed = false
    private let limit = 4_194_304
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onClose: (() -> Void)?

    init(path: String) {
        connection = NWConnection(to: .unix(path: path), using: .tcp)
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let header = ["GET / HTTP/1.1", "Host: localhost", "Upgrade: websocket",
                              "Connection: Upgrade", "Sec-WebSocket-Key: \(key)", "Sec-WebSocket-Version: 13",
                              "", ""].joined(separator: "\r\n")
                send(Data(header.utf8))
                read()
            case .failed, .cancelled:
                close()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ object: [String: Any]) {
        guard upgraded, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        frame(opcode: 1, payload: data)
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?()
    }

    private func send(_ bytes: Data) {
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    private func frame(opcode: UInt8, payload: Data) {
        var header: [UInt8] = [0x80 | opcode]
        if payload.count < 126 {
            header.append(0x80 | UInt8(payload.count))
        } else if payload.count <= 65_535 {
            header += [0xfe, UInt8(payload.count >> 8), UInt8(truncatingIfNeeded: payload.count)]
        } else {
            header.append(0xff)
            for shift in stride(from: 56, through: 0, by: -8) {
                header.append(UInt8(truncatingIfNeeded: UInt64(payload.count) >> shift))
            }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        var data = Data(header + mask)
        data.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        send(data)
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] bytes, _, done, error in
            guard let self, !closed else { return }
            if let bytes {
                buffer.append(bytes)
                consume()
            }
            if error != nil || done { close() }
            if !closed { read() }
        }
    }

    private func consume() {
        if !upgraded {
            guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 16_384 { close() }
                return
            }
            let header = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self)
                .components(separatedBy: "\r\n")
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
                .base64EncodedString()
            let expected = header.dropFirst().contains { field in
                let parts = field.split(separator: ":", maxSplits: 1)
                return parts.count == 2 && parts[0].lowercased() == "sec-websocket-accept"
                    && parts[1].trimmingCharacters(in: .whitespaces) == accept
            }
            guard header.first?.split(separator: " ").dropFirst().first == "101", expected else {
                close()
                return
            }
            buffer.removeSubrange(..<boundary.upperBound)
            upgraded = true
            onReady?()
        }
        while !closed && buffer.count >= 2 {
            let header = Array(buffer.prefix(10))
            let finite = header[0] & 0x80 != 0
            let opcode = header[0] & 15
            guard header[0] & 0x70 == 0, header[1] & 0x80 == 0 else { close(); return }
            let lengthCode = Int(header[1] & 127)
            let extra = lengthCode == 127 ? 8 : lengthCode == 126 ? 2 : 0
            guard header.count >= 2 + extra else { return }
            let length = extra == 0 ? UInt64(lengthCode) : header[2..<(2 + extra)]
                .reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard length <= limit, (opcode < 8 || (length <= 125 && finite)) else { close(); return }
            let start = 2 + extra
            let count = start + Int(length)
            guard buffer.count >= count else { return }
            let payload = Data(buffer.prefix(count).dropFirst(start))
            buffer.removeFirst(count)
            switch opcode {
            case 0:
                guard var message = multipart, message.count + payload.count <= limit else { close(); return }
                message.append(payload)
                multipart = finite ? nil : message
                if finite { onMessage?(message) }
            case 1, 2:
                guard multipart == nil else { close(); return }
                if finite { onMessage?(payload) } else { multipart = payload }
            case 8:
                close()
            case 9:
                frame(opcode: 10, payload: payload)
            case 10:
                break
            default:
                close()
            }
        }
    }
}

/// Subscribes only to known local CLI chats which the existing daemon already owns.
final class CLIStream {
    private struct PendingRequest {
        let subscriptionThread: String?
        let deadline: DispatchTime
        let reply: ([String: Any]?) -> Void
    }

    private static let responseTimeout: DispatchTimeInterval = .seconds(6)
    private static let subscriptionRetryDelay: DispatchTimeInterval = .seconds(2)
    private let location: URL
    private let queue: DispatchQueue
    private let makeTransport: (String) -> any CLITransport
    private let clock: () -> DispatchTime
    private var socket: (any CLITransport)?
    private var pending: [Int: PendingRequest] = [:]
    private var nextID = 1
    private var known = Set<String>()
    private var subscribed = Set<String>()
    private var attaching = Set<String>()
    private var changedDuringSnapshot = Set<String>()
    private var retryAfter: [String: DispatchTime] = [:]
    private var loading = false
    private var nextConnect: DispatchTime?
    private var replyDeadline = DispatchTime.distantFuture
    private(set) var connected = false
    private(set) var loadedThreads = Set<String>()
    var onEvent: ((CodexSignal) -> Void)?

    init(location: URL, queue: DispatchQueue,
         makeTransport: @escaping (String) -> any CLITransport = { UnixWebSocket(path: $0) },
         clock: @escaping () -> DispatchTime = { .now() }) {
        self.location = location
        self.queue = queue
        self.makeTransport = makeTransport
        self.clock = clock
    }

    func poll(known: Set<String>) {
        let now = clock()
        self.known = known
        if let socket, now >= replyDeadline {
            socket.close()
        }
        let expired = pending.compactMap { id, request in request.deadline <= now ? id : nil }
        for id in expired {
            pending.removeValue(forKey: id)?.reply(nil)
        }
        if socket == nil, now >= (nextConnect ?? now) {
            nextConnect = now + .milliseconds(1_500)
            guard FileManager.default.fileExists(atPath: location.path) else { return }
            attach(now: now)
        }
        if connected && !loading {
            loading = true
            list(cursor: nil, accumulated: [])
        }
    }

    func retry() {
        socket?.close()
        nextConnect = nil
    }

    private func attach(now: DispatchTime) {
        let wire = makeTransport(location.resolvingSymlinksInPath().path)
        socket = wire
        replyDeadline = now + Self.responseTimeout
        wire.onReady = { [weak self, weak wire] in
            guard let self, let wire, socket === wire else { return }
            // The first client sets the shared CLI daemon's originator.
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
            let clientInfo = ["name": "codex-tui", "title": "Codex TPS", "version": version]
            request("initialize", ["clientInfo": clientInfo]) { [weak self] result in
                guard let self, result != nil else { self?.socket?.close(); return }
                self.socket?.send(["method": "initialized"])
                self.connected = true
            }
        }
        wire.onMessage = { [weak self, weak wire] bytes in
            guard let self, let wire, socket === wire else { return }
            receive(bytes)
        }
        wire.onClose = { [weak self, weak wire] in
            guard let self, let wire, socket === wire else { return }
            socket = nil
            connected = false
            loading = false
            for id in subscribed.union(attaching) { onEvent?(.init(kind: .lost, thread: id)) }
            pending.removeAll()
            subscribed.removeAll()
            attaching.removeAll()
            changedDuringSnapshot.removeAll()
            retryAfter.removeAll()
            loadedThreads.removeAll()
        }
        wire.start(on: queue)
    }

    private func request(_ method: String, _ params: [String: Any] = [:],
                         subscriptionThread: String? = nil,
                         reply: @escaping ([String: Any]?) -> Void) {
        guard let socket else { return }
        let id = nextID
        nextID += 1
        let deadline = subscriptionThread == nil ? .distantFuture : clock() + Self.responseTimeout
        pending[id] = PendingRequest(subscriptionThread: subscriptionThread, deadline: deadline, reply: reply)
        socket.send(["id": id, "method": method, "params": params])
    }

    private func receive(_ bytes: Data) {
        guard let message = JSON.object(bytes) else { return }
        if message["method"] == nil, let id = message["id"] as? Int {
            guard let request = pending.removeValue(forKey: id) else { return }
            let now = clock()
            replyDeadline = now + Self.responseTimeout
            request.reply(now < request.deadline ? message["result"] as? [String: Any] : nil)
        } else if let event = CodexSignal.from(message),
                  subscribed.contains(event.thread) || attaching.contains(event.thread) {
            if message["method"] as? String == "thread/closed" {
                loadedThreads.remove(event.thread)
                retire(event.thread)
                return
            }
            if attaching.contains(event.thread) { changedDuringSnapshot.insert(event.thread) }
            onEvent?(event)
        }
    }

    private func list(cursor: String?, accumulated: Set<String>, visited: Set<String> = []) {
        let params = cursor.map { ["cursor": $0] } ?? [:]
        request("thread/loaded/list", params) { [weak self] reply in
            guard let self else { return }
            guard let reply, let list = reply["data"] as? [String] else {
                socket?.close()
                return
            }
            let loaded = accumulated.union(list)
            if let next = reply["nextCursor"] as? String {
                guard !visited.contains(next) else { socket?.close(); return }
                self.list(cursor: next, accumulated: loaded, visited: visited.union([next]))
                return
            }
            loading = false
            loadedThreads = loaded
            for id in subscribed.union(attaching).subtracting(loaded) { retire(id) }
            let candidates = loaded.intersection(known)
            retryAfter = retryAfter.filter { candidates.contains($0.key) }
            let now = clock()
            for id in candidates.subtracting(subscribed).subtracting(attaching) where (retryAfter[id] ?? now) <= now {
                subscribe(id)
            }
        }
    }

    private func subscribe(_ id: String) {
        attaching.insert(id)
        request("thread/read", ["threadId": id, "includeTurns": false],
                subscriptionThread: id) { [weak self] reply in
            guard let self else { return }
            guard loadedThreads.contains(id), known.contains(id),
                  let thread = reply?["thread"] as? [String: Any],
                  let status = CodexSignal.status(thread["status"] as? [String: Any], thread: id),
                  status.kind != .lost else {
                subscriptionFailed(id)
                return
            }
            let hasNewerEvent = changedDuringSnapshot.remove(id) != nil
            if status.kind == .active, !hasNewerEvent {
                var observation = status
                observation.fromThreadRead = true
                onEvent?(observation)
            }
            request("thread/resume", ["threadId": id, "excludeTurns": true],
                    subscriptionThread: id) { [weak self] reply in
                guard let self else { return }
                guard loadedThreads.contains(id), known.contains(id),
                      let thread = reply?["thread"] as? [String: Any],
                      let event = CodexSignal.status(thread["status"] as? [String: Any], thread: id),
                      event.kind != .lost else {
                    subscriptionFailed(id)
                    return
                }
                attaching.remove(id)
                subscribed.insert(id)
                retryAfter[id] = nil
                if changedDuringSnapshot.remove(id) == nil { onEvent?(event) }
            }
        }
    }

    private func subscriptionFailed(_ id: String) {
        attaching.remove(id)
        changedDuringSnapshot.remove(id)
        if loadedThreads.contains(id), known.contains(id) {
            retryAfter[id] = clock() + Self.subscriptionRetryDelay
        }
        onEvent?(.init(kind: .lost, thread: id))
    }

    private func retire(_ id: String) {
        subscribed.remove(id)
        attaching.remove(id)
        changedDuringSnapshot.remove(id)
        retryAfter.removeValue(forKey: id)
        pending = pending.filter { $0.value.subscriptionThread != id }
        onEvent?(.init(kind: .lost, thread: id))
    }
}
