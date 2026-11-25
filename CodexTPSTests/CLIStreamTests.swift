import Foundation
import XCTest
@testable import CodexTPS

final class CLIStreamTests: XCTestCase {
    func testCLIHandshakeUsesTUIOriginatorAndAppIdentity() throws {
        let wire = CLITransportFixture()
        wire.onRequest = { wire, request in
            switch request.method {
            case "initialize": wire.reply(to: request, result: [:])
            case "thread/loaded/list": wire.reply(to: request, result: ["data": []])
            default: XCTFail("Unexpected request: \(request.method)")
            }
        }
        let stream = CLIStream(location: FileManager.default.temporaryDirectory,
                               queue: DispatchQueue(label: "local.codex-tps.test.cli-identity"),
                               makeTransport: { _ in wire })
        stream.poll(known: [])
        XCTAssertEqual(wire.requests.first?.method, "initialize")
        XCTAssertEqual(wire.requests.first?.clientInfo?["name"], "codex-tui")
        XCTAssertEqual(wire.requests.first?.clientInfo?["title"], "Codex TPS")
        let version = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        XCTAssertEqual(wire.requests.first?.clientInfo?["version"], version)
        XCTAssertTrue(stream.connected)
    }

    func testCLIRetriesOnlyTheChatWithAnUnansweredRead() throws {
        try verifySubscriptionRecovery(missing: "thread/read", lateBeforePoll: false)
    }

    func testCLIRetriesOnlyTheChatWithAnExpiredResume() throws {
        try verifySubscriptionRecovery(missing: "thread/resume", lateBeforePoll: true)
    }

    func testCLIResubscribesAfterACloseAndReopenBetweenPolls() throws {
        try verifyReopeningChat(holdOldResume: false)
    }

    func testCLIIgnoresAnOldResumeReplyAfterTheChatReopens() throws {
        try verifyReopeningChat(holdOldResume: true)
    }

    private func verifyReopeningChat(holdOldResume: Bool) throws {
        let reopened = "reopened"
        let healthy = "healthy"
        let chats: Set<String> = [reopened, healthy]
        let wire = CLITransportFixture()
        var reopening = false
        var original: CLITransportFixture.Request?
        var replacement: CLITransportFixture.Request?
        wire.onRequest = { wire, request in
            switch request.method {
            case "initialize": wire.reply(to: request, result: [:])
            case "thread/loaded/list": wire.reply(to: request, result: ["data": chats.sorted()])
            case "thread/read": wire.status("active", for: request)
            case "thread/resume":
                if holdOldResume && request.thread == reopened {
                    if reopening { replacement = request } else { original = request }
                } else {
                    wire.status("active", for: request)
                }
            default: XCTFail("Unexpected request: \(request.method)")
            }
        }
        let stream = CLIStream(location: FileManager.default.temporaryDirectory,
                               queue: DispatchQueue(label: "local.codex-tps.test.reopen"), makeTransport: { _ in wire })
        var events: [CodexSignal] = []
        stream.onEvent = { events.append($0) }
        stream.poll(known: chats)
        wire.delta(healthy)
        wire.threadClosed(reopened)
        reopening = true
        // The chat has reloaded by the time the next list result arrives.
        stream.poll(known: chats)
        wire.delta(healthy)

        if holdOldResume {
            wire.status("idle", for: try XCTUnwrap(original))
            XCTAssertFalse(events.contains { $0.thread == reopened && $0.kind == .idle })
            XCTAssertEqual(events.filter { $0.thread == reopened && $0.kind == .active }.count, 2)
            wire.status("active", for: try XCTUnwrap(replacement))
        }
        stream.poll(known: chats)
        wire.delta(reopened)
        XCTAssertEqual(events.filter { $0.kind == .lost }.map(\.thread), [reopened])
        XCTAssertEqual(events.filter { $0.kind == .text }.map(\.thread), [healthy, healthy, reopened])
        XCTAssertEqual(wire.requests.filter { $0.method == "thread/resume" && $0.thread == reopened }.count, 2)
        XCTAssertEqual(wire.requests.filter { $0.method == "thread/resume" && $0.thread == healthy }.count, 1)
        XCTAssertTrue(stream.connected)
        XCTAssertEqual(wire.closeCount, 0)
    }

    private func verifySubscriptionRecovery(missing method: String, lateBeforePoll: Bool) throws {
        let healthy = "healthy"
        let recovering = "recovering"
        let chats = Set([healthy, recovering])
        let wire = CLITransportFixture()
        var now = DispatchTime(uptimeNanoseconds: 1)
        var held: CLITransportFixture.Request?
        wire.onRequest = { wire, request in
            switch request.method {
            case "initialize":
                wire.reply(to: request, result: [:])
            case "thread/loaded/list":
                wire.reply(to: request, result: ["data": chats.sorted()])
            case "thread/read", "thread/resume":
                if request.thread == recovering, request.method == method, held == nil {
                    held = request
                } else {
                    wire.status("active", for: request)
                }
            default:
                XCTFail("Unexpected request: \(request.method)")
            }
        }
        let stream = CLIStream(location: FileManager.default.temporaryDirectory,
                               queue: DispatchQueue(label: "local.codex-tps.test.cli"),
                               makeTransport: { _ in wire }, clock: { now })
        var events: [CodexSignal] = []
        stream.onEvent = { events.append($0) }
        stream.poll(known: chats)
        let original = try XCTUnwrap(held)
        wire.delta(healthy)
        if lateBeforePoll { wire.delta(recovering) }

        now = now + .seconds(3)
        stream.poll(known: chats)
        wire.delta(healthy)
        now = now + .seconds(3)
        if lateBeforePoll { wire.status("idle", for: original) }
        stream.poll(known: chats)
        XCTAssertTrue(stream.connected)
        XCTAssertEqual(events.filter { $0.kind == .lost }.map(\.thread), [recovering])

        now = now + .seconds(1)
        stream.poll(known: chats)
        XCTAssertEqual(wire.requests.filter { $0.method == method && $0.thread == recovering }.count, 1)

        now = now + .seconds(1)
        stream.poll(known: chats)
        wire.status("idle", for: original)
        wire.delta(healthy)
        wire.delta(recovering)

        XCTAssertEqual(wire.requests.filter { $0.method == method && $0.thread == recovering }.count, 2)
        XCTAssertEqual(wire.requests.filter { $0.method == "thread/resume" && $0.thread == healthy }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .active && $0.thread == recovering
            && $0.fromThreadRead != true }.count, 1)
        XCTAssertFalse(events.contains { $0.kind == .idle })
        XCTAssertEqual(events.filter { $0.kind == .text && $0.thread == healthy }.count, 3)
        XCTAssertEqual(events.filter { $0.kind == .text && $0.thread == recovering }.count, lateBeforePoll ? 2 : 1)
        XCTAssertEqual(wire.closeCount, 0)
    }
}

private final class CLITransportFixture: CLITransport {
    struct Request {
        let id: Int
        let method: String
        let thread: String?
        let cursor: String?
        let clientInfo: [String: String]?
    }

    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onClose: (() -> Void)?
    var onRequest: ((CLITransportFixture, Request) -> Void)?
    private(set) var requests: [Request] = []
    private(set) var closeCount = 0

    func start(on queue: DispatchQueue) { onReady?() }

    func send(_ object: [String: Any]) {
        guard let id = object["id"] as? Int, let method = object["method"] as? String else { return }
        let params = object["params"] as? [String: Any]
        let request = Request(id: id, method: method, thread: params?["threadId"] as? String,
                              cursor: params?["cursor"] as? String, clientInfo: params?["clientInfo"] as? [String: String])
        requests.append(request)
        onRequest?(self, request)
    }

    func close() {
        closeCount += 1
        onClose?()
    }

    func reply(to request: Request, result: [String: Any]) {
        receive(["id": request.id, "result": result])
    }

    func status(_ type: String, flags: [String] = [], for request: Request) {
        reply(to: request, result: ["thread": ["status": ["type": type, "activeFlags": flags]]])
    }

    func delta(_ thread: String) {
        receive(["method": "item/agentMessage/delta",
                 "params": ["threadId": thread, "turnId": "turn", "itemId": "item", "delta": "text"]])
    }

    func threadClosed(_ thread: String) {
        receive(["method": "thread/closed", "params": ["threadId": thread]])
    }

    private func receive(_ object: [String: Any]) {
        do { onMessage?(try JSONSerialization.data(withJSONObject: object)) }
        catch { XCTFail("Invalid fixture message: \(error)") }
    }
}

final class ObserverRegressionTests: XCTestCase {
    func testFirstApprovalSnapshotSurvivesFailedResumeAndStaysUnconfirmedDuringRetry() {
        let wire = CLITransportFixture()
        var now = DispatchTime(uptimeNanoseconds: 1)
        var resume: CLITransportFixture.Request?
        wire.onRequest = { wire, request in
            switch request.method {
            case "initialize": wire.reply(to: request, result: [:])
            case "thread/loaded/list": wire.reply(to: request, result: ["data": ["chat"]])
            case "thread/read": wire.status("active", flags: ["waitingOnApproval"], for: request)
            case "thread/resume": resume = request
            default: XCTFail("Unexpected request")
            }
        }
        let stream = CLIStream(location: FileManager.default.temporaryDirectory,
                               queue: DispatchQueue(label: "codex-tps.test.approval"),
                               makeTransport: { _ in wire }, clock: { now })
        var events: [CodexSignal] = []
        stream.onEvent = { events.append($0) }
        stream.poll(known: ["chat"])
        XCTAssertEqual(events.map(\.kind), [.active])
        XCTAssertEqual(events.first?.phase, .awaitingApproval)
        XCTAssertEqual(events.first?.fromThreadRead, true)
        now = now + .seconds(3)
        stream.poll(known: ["chat"])
        now = now + .seconds(3)
        stream.poll(known: ["chat"])
        XCTAssertEqual(events.map(\.kind), [.active, .lost])
        now = now + .seconds(2)
        stream.poll(known: ["chat"])
        XCTAssertEqual(events.map(\.kind), [.active, .lost, .active])
        XCTAssertEqual(events.last?.fromThreadRead, true)
        if let resume { wire.status("active", flags: ["waitingOnApproval"], for: resume) }
        XCTAssertEqual(events.map(\.kind), [.active, .lost, .active, .active])
        XCTAssertNil(events.last?.fromThreadRead)
        XCTAssertTrue(stream.connected)
    }

    func testFirstSuccessfulReadPublishesApprovalAfterAnInitialTimeout() {
        let wire = CLITransportFixture()
        var now = DispatchTime(uptimeNanoseconds: 1)
        var reads = 0
        wire.onRequest = { wire, request in
            switch request.method {
            case "initialize": wire.reply(to: request, result: [:])
            case "thread/loaded/list": wire.reply(to: request, result: ["data": ["chat", "healthy"]])
            case "thread/read" where request.thread == "chat":
                reads += 1
                if reads == 2 { wire.status("active", flags: ["waitingOnApproval"], for: request) }
            case "thread/resume" where request.thread == "chat": break
            case "thread/read", "thread/resume": wire.status("active", for: request)
            default: XCTFail("Unexpected request")
            }
        }
        let stream = CLIStream(location: FileManager.default.temporaryDirectory,
                               queue: DispatchQueue(label: "codex-tps.test.read-retry"),
                               makeTransport: { _ in wire }, clock: { now })
        var events: [CodexSignal] = []
        stream.onEvent = { events.append($0) }
        stream.poll(known: ["chat", "healthy"])
        for seconds in [3, 3, 2, 3, 3] {
            now = now + .seconds(seconds)
            stream.poll(known: ["chat", "healthy"])
            wire.delta("healthy")
        }
        let recovered = events.filter { $0.thread == "chat" }
        XCTAssertEqual(recovered.map(\.kind), [.lost, .active, .lost])
        XCTAssertEqual(recovered.first(where: { $0.kind == .active })?.phase, .awaitingApproval)
        XCTAssertEqual(recovered.first(where: { $0.kind == .active })?.fromThreadRead, true)
        XCTAssertEqual(events.filter { $0.kind == .text && $0.thread == "healthy" }.count, 5)
        XCTAssertTrue(stream.connected)
    }

    func testRecoveredApprovalKeepsNewerTurnVisibleWhenHistoryCatchesUp() throws {
        func date(_ second: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + second) }
        func event(_ type: String, turn: String, at time: Date) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "type": "event_msg", "timestamp": time.ISO8601Format(),
                "payload": ["type": type, "turn_id": turn],
            ])
        }

        let chat = ChatMetadata(id: "chat", title: "Fixture", client: .cli,
                                rollout: URL(fileURLWithPath: "/unused"), updated: date(0))
        var history = History()
        history.ingest(try event("task_started", turn: "A", at: date(0)))
        var live = LiveTurn(id: "A", began: date(0), observedSince: date(0))
        live.apply(.init(kind: .active, thread: chat.id, at: date(1), phase: .awaitingApproval), now: date(1))
        live.interruptCoverage(at: date(10))
        live.apply(.init(kind: .active, thread: chat.id, at: date(14), phase: .awaitingApproval,
                         fromThreadRead: true), now: date(14))
        XCTAssertFalse(live.confirmed)
        XCTAssertEqual(live.display(turn: nil, sends: [], metrics: .init(usage: [], sends: []),
                                    savedAssistantAt: nil, now: date(14)).readout, .elapsed(4))
        // A completes at 12. B starts at 13 and is waiting for approval when the CLI reconnects.
        // The ID is absent on the fresh status message and the local reader is still on the older prefix.
        live.apply(.init(kind: .active, thread: chat.id, at: date(15), phase: .awaitingApproval), now: date(15))
        let late = TurnEnd(id: "A", at: date(16), phase: .completed)
        let before = projectConversation(chat, history: history, sends: [], live: live, terminalEvent: late,
                                         canShowLive: true, connected: true, now: date(15))
        XCTAssertEqual(before.row?.phase, .awaitingApproval)
        history.watch(try XCTUnwrap(before.live?.id))
        history.ingest(try event("task_complete", turn: "A", at: date(12)))
        history.ingest(try event("task_started", turn: "B", at: date(13)))
        XCTAssertEqual(history.openTurn?.id, "B")
        let caughtUp = projectConversation(chat, history: history, sends: [], live: before.live, terminalEvent: nil,
                                          canShowLive: true, connected: true, now: date(16))
        XCTAssertEqual(caughtUp.row?.phase, .awaitingApproval, "A's completion cannot consume the freshly observed approval wait in B")
        XCTAssertEqual(caughtUp.row?.active, true)
        XCTAssertEqual(caughtUp.live?.id, "B")

        history.ingest(try event("task_complete", turn: "B", at: date(17)))
        let completed = projectConversation(chat, history: history, sends: [], live: before.live, terminalEvent: nil,
                                            canShowLive: true, connected: true, now: date(18))
        XCTAssertEqual(completed.row?.phase, .completed)
        XCTAssertEqual(completed.row?.active, false)
    }

    func testFinishedTurnAfterStatusOnlySubscription() {
        let start = Date(timeIntervalSince1970: 100)
        let end = start.addingTimeInterval(5)
        let chat = ChatMetadata(id: "ordinary", title: "Fixture", client: .cli, rollout: URL(fileURLWithPath: "/unused"), updated: start)
        var history = History()
        history.lastStart = TurnStart(id: "A", at: start)
        var observed = LiveTurn(id: nil, began: start, observedSince: start)
        observed.apply(.init(kind: .active, thread: chat.id, phase: .awaitingApproval), now: start)
        let active = projectConversation(chat, history: history, sends: [], live: observed, terminalEvent: nil,
                                         canShowLive: true, connected: true, now: start)
        XCTAssertEqual(active.row?.active, true)
        XCTAssertEqual(active.live?.id, "A")
        var disconnected = active.live
        disconnected?.interruptCoverage(at: end)
        history.lastEnd = TurnEnd(id: "A", at: end, phase: .completed)
        let finished = projectConversation(chat, history: history, sends: [], live: disconnected, terminalEvent: nil,
                                           canShowLive: true, connected: false, now: end)
        XCTAssertEqual(finished.row?.active, false, "An ended turn should be shown in history")
        history.lastEnd = nil
        history.watch("A")
        history.resetForReplay()
        for (id, date) in [("A", end), ("B", end.addingTimeInterval(2))] {
            let record = """
            {"timestamp":"\(date.ISO8601Format())","type":"event_msg","payload":{"type":"task_complete","turn_id":"\(id)"}}
            """
            history.ingest(Data(record.utf8))
        }
        XCTAssertEqual(history.lastEnd?.id, "B")
        XCTAssertEqual(history.watchedEnd?.id, "A")
        let replay = projectConversation(chat, history: history, sends: [], live: disconnected,
                                          terminalEvent: nil, canShowLive: true, connected: false, now: end)
        XCTAssertEqual(replay.row?.active, false)

        var newer = LiveTurn(id: nil, began: end.addingTimeInterval(3), observedSince: end.addingTimeInterval(3))
        newer.apply(.init(kind: .active, thread: chat.id, phase: .awaitingApproval), now: newer.began)
        let after = projectConversation(chat, history: history, sends: [], live: newer,
                                         terminalEvent: nil, canShowLive: true, connected: true, now: newer.began)
        XCTAssertEqual(after.row?.phase, .awaitingApproval)
    }

    func testReloadObservedByListWhileResumePending() throws {
        let wire = CLITransportFixture()
        var listed = ["chat"]
        var resumes: [CLITransportFixture.Request] = []
        var healthyDeltas = 0
        wire.onRequest = { wire, req in
            switch req.method {
            case "initialize": wire.reply(to: req, result: [:])
            case "thread/loaded/list":
                if req.cursor == "page-two" {
                    wire.reply(to: req, result: ["data": ["healthy"]])
                } else {
                    wire.reply(to: req, result: ["data": listed, "nextCursor": "page-two"])
                }
            case "thread/read": wire.status("active", for: req)
            case "thread/resume":
                if req.thread == "chat" { resumes.append(req) } else { wire.status("active", for: req) }
            default: XCTFail("Unexpected request")
            }
        }
        let client = CLIStream(location: FileManager.default.temporaryDirectory, queue: DispatchQueue(label: "test.fixture"), makeTransport: { _ in wire })
        var staleIdle = false
        client.onEvent = {
            if $0.kind == .idle { staleIdle = true }
            if $0.kind == .text && $0.thread == "healthy" { healthyDeltas += 1 }
        }
        let known: Set<String> = ["chat", "healthy"]
        client.poll(known: known)
        let first = try XCTUnwrap(resumes.first)
        listed = []
        client.poll(known: known)
        wire.delta("healthy")
        listed = ["chat"]
        client.poll(known: known)
        wire.status("idle", for: first)
        let fresh = try XCTUnwrap(resumes.last)
        wire.delta("chat")
        wire.status("idle", for: fresh)
        wire.status("idle", for: first)
        client.poll(known: known)
        wire.delta("healthy")
        XCTAssertEqual(resumes.count, 2, "Reopened chat should subscribe again")
        XCTAssertFalse(staleIdle, "Old subscription should no longer set status")
        XCTAssertEqual(healthyDeltas, 2)
    }
}
