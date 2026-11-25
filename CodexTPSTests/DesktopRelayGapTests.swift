import Foundation
import XCTest
@testable import CodexTPS

final class DesktopRelayGapTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let thread = "fixture"

    func testReceiverBuffersTextBurstDuringMonitorWork() throws {
        let packets = try capture(count: 100) { _, sender, queue in
            queue.suspend()
            for _ in 0..<100 { sender.emit(text(40, at: 2)) }
            queue.resume()
        }
        XCTAssertEqual(packets.map(\.sequence), Array(1...100))
    }

    func testDroppingTextFromThisThreadWaitsAndStillSettles() throws {
        let packets = try replayTextLoss(in: thread)
        try verifyTextLoss(packets, lostThread: thread)
        verifyReadouts(packets, expected: [.live(10), .waiting, .waiting, .waiting])
    }

    func testDroppingTextFromAnotherThreadKeepsUpdatingThisThreadAndSettles() throws {
        let packets = try replayTextLoss(in: "other")
        let gap = try verifyTextLoss(packets, lostThread: "other")
        XCTAssertTrue(gap.impact(on: thread).isEmpty)
        verifyReadouts(packets, expected: [.live(10), .live(10), .live(15), .live(24)])
    }

    func testOversizedRPCResponseKeepsTextCompleteAndStillSettles() throws {
        // The response contains notification-shaped data nested inside its result.
        let packets = try replayOversizedFrame(
            prefix: #"{"jsonrpc":"2.0","id":7,"result":{"method":"item/agentMessage/delta","data":""#,
            suffix: #""}}"#
        )
        guard packets.count == 4 else { return }
        let gap = try XCTUnwrap(packets[1].gap(after: packets[0]))
        XCTAssertTrue(gap.continuousOutput)
        XCTAssertTrue(gap.fullyReported)
        XCTAssertTrue(gap.impact(on: thread).isEmpty)
        XCTAssertEqual(gap.report?.losses, [RelayLoss(reason: .oversizedFrame, impact: [], event: "response")])
        verifyReadouts(packets, expected: [.live(10), .live(10), .live(15), .live(24)])
    }

    func testOversizedFrameWithoutRecognizableHeaderWaitsAndStillSettles() throws {
        let packets = try replayOversizedFrame(
            prefix: #"{"params":{"threadId":"fixture","result":{},"method":"item/completed","delta":""#,
            suffix: #""},"method":"item/agentMessage/delta"}"#
        )
        guard packets.count == 4 else { return }
        let gap = try XCTUnwrap(packets[1].gap(after: packets[0]))
        XCTAssertFalse(gap.continuousOutput)
        XCTAssertEqual(gap.impact(on: thread), .unknown)
        verifyReadouts(packets, expected: [.live(10), .elapsed(0), .waiting, .waiting])
    }

    func testIncompleteReportCannotProveThatAnotherThreadCausedTheWholeGap() throws {
        let packets = try replayTextLoss(in: "other")
        guard packets.count == 4 else { return }
        // A receiver that missed the preceding text has a larger gap than the report covers.
        let previous = RelayPacket(session: packets[0].session, sequence: 0,
                                   outputSequence: 0, signal: .init(kind: .heartbeat))
        let gap = try XCTUnwrap(packets[1].gap(after: previous))
        XCTAssertFalse(gap.fullyReported)
        XCTAssertEqual(gap.impact(on: thread), .unknown)
    }

    private func capture(count: Int, send: (URL, RelaySender, DispatchQueue) throws -> Void) throws -> [RelayPacket] {
        let root = URL(fileURLWithPath: "/tmp/codex-tps-gap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let queue = DispatchQueue(label: "local.codex-tps.test.relay-burst")
        let receiver = DesktopReceiver()
        defer {
            queue.sync { receiver.stop() }
            try? FileManager.default.removeItem(at: root)
        }

        let received = expectation(description: "Receiver gets \(count) packets")
        received.expectedFulfillmentCount = count
        var packets: [RelayPacket] = []
        let endpoint = try queue.sync {
            receiver.onPacket = { packet in
                packets.append(packet)
                received.fulfill()
            }
            return try receiver.start(on: queue)
        }
        let sender = try XCTUnwrap(RelaySender(endpoint: endpoint))
        XCTAssertTrue(sender.register())
        try send(root, sender, queue)
        wait(for: [received], timeout: 2)
        return queue.sync { packets }
    }

    private func replayTextLoss(in lostThread: String) throws -> [RelayPacket] {
        try capture(count: 4) { _, sender, _ in
            sender.emit(text(80, at: 2))
            sender.skip(RelayLoss(reason: .sendFailed, impact: .output, event: "text",
                                  thread: lostThread, errorCode: -1))
            sendRemainder(sender)
        }
    }

    private func replayOversizedFrame(prefix: String, suffix: String) throws -> [RelayPacket] {
        try capture(count: 4) { root, sender, _ in
            let input = root.appendingPathComponent("in.jsonl")
            let output = root.appendingPathComponent("out.jsonl")
            let bytes = Data((prefix + String(repeating: "x", count: 2_097_153) + suffix + "\n").utf8)
            try bytes.write(to: input)
            try Data().write(to: output)
            let source = try FileHandle(forReadingFrom: input)
            let destination = try FileHandle(forWritingTo: output)
            sender.emit(text(80, at: 2))
            try DesktopRelay.forwardObserved(source, to: destination, listening: { sender.hasListener },
                                             emit: sender.emit, skip: sender.skip)
            try destination.close()
            XCTAssertEqual(try Data(contentsOf: output), bytes)
            sendRemainder(sender)
        }
    }

    @discardableResult
    private func verifyTextLoss(_ packets: [RelayPacket], lostThread: String) throws -> RelayGap {
        XCTAssertEqual(packets.map(\.sequence), [1, 3, 4, 5])
        let before = try XCTUnwrap(packets.first)
        let after = try XCTUnwrap(packets.dropFirst().first)
        let gap = try XCTUnwrap(after.gap(after: before))
        XCTAssertTrue(gap.fullyReported)
        XCTAssertFalse(gap.continuousOutput)
        let loss = try XCTUnwrap(gap.report?.losses.first)
        XCTAssertEqual(gap.report?.count, 1)
        XCTAssertEqual(loss.reason, .sendFailed)
        XCTAssertEqual(loss.event, "text")
        XCTAssertEqual(loss.thread, lostThread)
        XCTAssertEqual(gap.impact(on: lostThread), .output)
        XCTAssertNotNil(loss.errorCode)
        XCTAssertTrue(loss.summary.contains("scope=thread/"))
        XCTAssertFalse(loss.summary.contains(lostThread))
        XCTAssertNil(packets.last?.lossReport)
        return gap
    }

    private func sendRemainder(_ sender: RelaySender) {
        sender.emit(.init(kind: .heartbeat, at: start.addingTimeInterval(3.5)))
        sender.emit(text(160, at: 4))
        sender.emit(text(240, at: 5))
    }

    private func text(_ characters: Int, at seconds: TimeInterval) -> CodexSignal {
        .init(kind: .text, thread: thread, turn: "turn", item: "reply", at: start.addingTimeInterval(seconds),
              characters: characters)
    }

    private func verifyReadouts(_ packets: [RelayPacket], expected: [ConversationRow.Readout]) {
        let chat = ChatMetadata(id: thread, title: "Fixture", client: .desktop,
                                rollout: URL(fileURLWithPath: "/tmp/fixture.jsonl"), updated: start)
        let sends = [SendMarker(turn: "turn", at: start)]
        var history = History()
        var live = LiveTurn(id: "turn", began: start, observedSince: start)
        var previous: RelayPacket?
        var readouts: [ConversationRow.Readout?] = []
        for packet in packets {
            let now = packet.signal.at
            if let previous, let gap = packet.gap(after: previous) {
                live.interruptCoverage(at: now, impact: gap.impact(on: thread))
            }
            if packet.signal.thread == thread { live.apply(packet.signal, now: now) }
            readouts.append(projectConversation(chat, history: history, sends: sends, live: live,
                                                terminalEvent: nil, canShowLive: true, connected: true, now: now).row?.readout)
            previous = packet
        }
        XCTAssertEqual(readouts, expected.map(Optional.some))

        let end = start.addingTimeInterval(10)
        history.lastEnd = TurnEnd(id: "turn", at: end, phase: .completed)
        history.usage["actual"] = RecordedUsage(id: "actual", turn: "turn", at: end, output: 600, input: 1_000, cached: 800)
        let completed = projectConversation(chat, history: history, sends: sends, live: live,
                                            terminalEvent: nil, canShowLive: true, connected: true, now: end)
        XCTAssertEqual(completed.row?.readout, .settled(60))
        XCTAssertEqual(completed.row?.phase, .completed)
        XCTAssertEqual(completed.row?.active, false)
    }
}
