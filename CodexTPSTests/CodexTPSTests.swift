import AppKit
import Darwin
import XCTest
@testable import CodexTPS

final class CodexTPSTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    func testCollapsedSelectionKeepsActiveFirstAndAtMostTwoRecent() {
        let active = (1...4).map { makeRow("a\($0)", at: Double($0), active: true) }
        let recent = (1...3).map { makeRow("r\($0)", at: Double($0 + 10), active: false) }
        XCTAssertEqual(CardSelection(recent).collapsed.map(\.id), ["r3", "r2"])
        XCTAssertEqual(CardSelection(Array(active.prefix(1)) + recent).collapsed.map(\.id), ["a1", "r3", "r2"])
        XCTAssertEqual(CardSelection(Array(active.prefix(2)) + recent).collapsed.map(\.id), ["a2", "a1", "r3"])
        let expanded = CardSelection(active + recent)
        XCTAssertEqual(expanded.collapsed.map(\.id), ["a4", "a3", "a2"])
        XCTAssertEqual(expanded.active.map(\.id), ["a4", "a3", "a2", "a1"])
        XCTAssertEqual(expanded.firstHiddenActive?.id, "a1")
        XCTAssertNil(CardSelection(Array(active.prefix(3)) + recent).firstHiddenActive)
    }

    func testWaterReflectionsTravelTwelvePointsPerSecondAndRepeat() {
        let start = WaterMotion(elapsed: 0)
        let next = WaterMotion(elapsed: 1)
        XCTAssertEqual(next.backgroundOffset - start.backgroundOffset, 12, accuracy: 0.0001)
        let repeatStart = WaterMotion(elapsed: WaterMotion.duration)
        XCTAssertEqual(repeatStart.backgroundOffset, start.backgroundOffset, accuracy: 0.0001)
        XCTAssertEqual(repeatStart.foregroundOpacity, start.foregroundOpacity, accuracy: 0.0001)
    }

    @MainActor
    func testCardStyleDefaultsToGraphiteAndRestoresTheSavedChoice() throws {
        let id = "local.codex-tps.style-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defer { defaults.removePersistentDomain(forName: id) }

        let state = AppState(defaults: defaults)
        XCTAssertEqual(state.cardTheme.id, CardTheme.graphite.id)
        state.setMetric(.cache, enabled: false)
        for theme in CardTheme.builtIn {
            state.setCardTheme(theme)
            XCTAssertEqual(state.cardTheme.id, theme.id)
            let restored = AppState(defaults: defaults)
            XCTAssertEqual(restored.cardTheme.id, theme.id)
            XCTAssertEqual(restored.enabledMetrics, [.average, .context])
        }
        defaults.set("unavailable-theme", forKey: "CardTheme")
        XCTAssertEqual(AppState(defaults: defaults).cardTheme.id, CardTheme.graphite.id)
    }

    func testMeadowBreezeRepeatsEveryEightSeconds() {
        XCTAssertEqual(MeadowBreeze.frame(at: 0), 0)
        XCTAssertEqual(MeadowBreeze.frame(at: 8), 0)
        XCTAssertNotEqual(MeadowBreeze.frame(at: 2.5), 0)
        XCTAssertEqual(MeadowBreeze.frame(at: 2.5), MeadowBreeze.frame(at: 10.5))
        XCTAssertEqual(MeadowBreeze.frame(at: -0.5), MeadowBreeze.frame(at: 7.5))
    }

    @MainActor
    func testDisplaySwitchesPersistIndependentlyOfWindowState() throws {
        let id = "local.codex-tps.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defer { defaults.removePersistentDomain(forName: id) }
        let first = AppState(defaults: defaults)
        XCTAssertEqual(first.enabledMetrics, Set(Metric.allCases))
        first.setMetric(.cache, enabled: false)
        first.isPinned = true
        first.isCardVisible = false
        let again = AppState(defaults: defaults)
        XCTAssertEqual(again.enabledMetrics, [.average, .context])
        XCTAssertTrue(again.isCardVisible)
        XCTAssertFalse(again.isPinned)
    }

    @MainActor
    func testPanelUsesDesktopLevelThenPinsAndHidesWithoutBecomingKey() throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("The test host has no display.") }
        let id = "local.codex-tps.window-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defer { defaults.removePersistentDomain(forName: id) }
        let state = AppState(defaults: defaults)
        state.showFixture()
        let window = CardWindow(state: state, defaults: defaults)
        defer { window.panel.orderOut(nil) }
        XCTAssertTrue(window.panel.isVisible)
        XCTAssertEqual(window.panel.level, DesktopPanel.restingLevel)
        XCTAssertLessThan(window.panel.level.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertGreaterThan(window.panel.level.rawValue, Int(CGWindowLevelForKey(.desktopIconWindow)))
        XCTAssertFalse(window.panel.canBecomeKey)
        XCTAssertTrue(window.panel.isMovable)
        XCTAssertGreaterThan(window.panel.frame.height, 240)
        let initialFrame = window.panel.frame
        state.isPinned = true
        window.refresh()
        XCTAssertEqual(window.panel.level, .floating)
        XCTAssertFalse(window.panel.isMovable)
        XCTAssertEqual(window.panel.frame, initialFrame)
        state.isCardVisible = false
        window.refresh()
        XCTAssertFalse(window.panel.isVisible)
        state.isCardVisible = true
        state.isPinned = false
        window.refresh()
        XCTAssertTrue(window.panel.isVisible)
        XCTAssertEqual(window.panel.level, DesktopPanel.restingLevel)
        XCTAssertTrue(window.panel.isMovable)
        XCTAssertEqual(window.panel.frame, initialFrame)
    }

    func testPositionClampsToVisibleScreen() {
        let display = CGRect(x: -1440, y: 28, width: 1440, height: 820)
        let point = CardPlacement.clamped(CGPoint(x: -100, y: -20), size: CGSize(width: 360, height: 298),
                                         within: display)
        XCTAssertEqual(point, CGPoint(x: -360, y: 28))
    }

    @MainActor
    func testCardRestoresScaleAndKeepsItThroughRefresh() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        guard screen.visibleFrame.width >= 540 else { throw XCTSkip("Scale fixture needs a wider display.") }
        let id = "local.codex-tps.scale-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defer { defaults.removePersistentDomain(forName: id) }
        for (savedScale, width) in [(0.1, 324.0), (1.0, 360.0), (2.0, 540.0)] {
            defaults.set(savedScale, forKey: "CardScale")
            let state = AppState(defaults: defaults)
            state.isCardVisible = false
            let card = CardWindow(state: state, defaults: defaults)
            defer { card.panel.orderOut(nil) }
            XCTAssertEqual(card.sizeMeasurements, 0)
            state.isCardVisible = true
            card.refresh()
            let corner = CGPoint(x: card.panel.frame.minX, y: card.panel.frame.maxY)
            XCTAssertEqual(card.panel.frame.width, width, accuracy: 1)
            state.showFixture()
            card.refresh()
            XCTAssertEqual(card.panel.frame.width, width, accuracy: 1)
            XCTAssertEqual(card.panel.frame.minX, corner.x, accuracy: 1)
            XCTAssertEqual(card.panel.frame.maxY, corner.y, accuracy: 1)
        }
    }

    @MainActor
    func testPinnedCardKeepsItsViewportAtTheScreenEdge() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let visible = screen.visibleFrame
        guard visible.width >= 360, visible.height >= 360 else { throw XCTSkip("Fixture needs a larger display.") }
        let id = "local.codex-tps.pinned-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defer { defaults.removePersistentDomain(forName: id) }
        let state = AppState(defaults: defaults)
        let card = CardWindow(state: state, defaults: defaults)
        defer { card.panel.orderOut(nil) }
        let origin = CGPoint(x: visible.maxX - card.panel.frame.width, y: visible.minY + 8)
        card.panel.setFrameOrigin(origin)
        let top = card.panel.frame.maxY
        state.isPinned = true
        card.refresh()
        state.rows = (1...6).map { makeRow("active-\($0)", at: Double($0), active: true) }
        state.isExpanded = true
        card.refresh()
        XCTAssertEqual(card.panel.frame.minX, origin.x, accuracy: 1)
        XCTAssertEqual(card.panel.frame.maxY, top, accuracy: 1)
        XCTAssertGreaterThanOrEqual(card.panel.frame.minY, visible.minY - 1)
        XCTAssertEqual(card.panel.frame.width, 360, accuracy: 1)

        let pinnedFrame = card.panel.frame
        state.isPinned = false
        card.refresh()
        card.refresh()
        XCTAssertEqual(card.panel.frame, pinnedFrame)
        XCTAssertTrue(card.panel.isMovable)
    }

    @MainActor
    func testExpandingNearScreenBottomKeepsTheHeaderInPlace() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let id = "local.codex-tps.expansion-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defer { defaults.removePersistentDomain(forName: id) }
        let state = AppState(defaults: defaults)
        state.rows = (1...6).map { makeRow("active-\($0)", at: Double($0), active: true) }
        let card = CardWindow(state: state, defaults: defaults)
        defer { card.panel.orderOut(nil) }
        let visible = screen.visibleFrame
        card.panel.setFrameOrigin(CGPoint(x: visible.minX + 16, y: visible.minY + 8))
        let collapsed = card.panel.frame

        state.isExpanded = true
        card.refresh()

        XCTAssertEqual(card.panel.frame.minX, collapsed.minX, accuracy: 1)
        XCTAssertEqual(card.panel.frame.maxY, collapsed.maxY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(card.panel.frame.minY, visible.minY - 1)
        XCTAssertTrue(card.panel.isMovable)

        state.isExpanded = false
        card.refresh()
        XCTAssertEqual(card.panel.frame, collapsed)

        state.isExpanded = true
        state.rows = Array(state.rows.prefix(3))
        XCTAssertFalse(state.isExpanded)
    }

    @MainActor
    func testCardRestoresMinimumScaleAndPositionAtScreenEdge() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let screenID = try XCTUnwrap(CardPlacement.id(for: screen))
        let visible = screen.visibleFrame
        guard visible.width >= 360, visible.height >= 360 else { throw XCTSkip("Fixture needs a larger display.") }
        let id = "local.codex-tps.edge-restore-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defer { defaults.removePersistentDomain(forName: id) }
        let x = visible.maxX - 324
        let top = visible.minY + 125
        defaults.set(0.9, forKey: "CardScale")
        defaults.set(["screen": screenID, "x": x, "top": top], forKey: "CardPlacement")

        let state = AppState(defaults: defaults)
        state.showFixture()
        let card = CardWindow(state: state, defaults: defaults)
        defer { card.panel.orderOut(nil) }
        card.refresh()
        XCTAssertFalse(state.isPinned)
        XCTAssertEqual(card.panel.frame.width, 324, accuracy: 1)
        XCTAssertEqual(card.panel.frame.minX, x, accuracy: 1)
        XCTAssertEqual(card.panel.frame.maxY, top, accuracy: 1)
        XCTAssertGreaterThanOrEqual(card.panel.frame.minY, visible.minY - 1)
    }

    func testProjectionKeepsANewTurnActiveAndFindsTheLatestValidHistoryRate() {
        let oldReply = usage("last-valid", at: 10, output: 600)
        let oldEnd = TurnEnd(id: oldReply.turn, at: oldReply.at, phase: .completed)
        let newStart = start.addingTimeInterval(12)
        let visibleAt = start.addingTimeInterval(13)
        let chat = ChatMetadata(id: "chat", title: "Fixture", client: .cli,
                                rollout: URL(fileURLWithPath: "/unused"), updated: newStart)
        var history = History()
        history.usage[oldReply.id] = oldReply
        history.lastEnd = oldEnd
        history.lastStart = TurnStart(id: "next", at: newStart)
        var live = LiveTurn(id: "next", began: newStart, observedSince: newStart)
        live.apply(.init(kind: .text, turn: "next", at: visibleAt, characters: 80), now: visibleAt)
        let oldMarker = SendMarker(turn: oldReply.turn, at: start)
        let newMarker = SendMarker(turn: "next", at: newStart)
        let active = projectConversation(chat, history: history, sends: [oldMarker, newMarker], live: live,
                                         terminalEvent: nil, canShowLive: true, connected: true, now: visibleAt)
        XCTAssertEqual(active.row?.readout, .live(20))
        XCTAssertEqual(active.row?.active, true)
        XCTAssertEqual(active.row?.orderDate, newStart)
        XCTAssertEqual(active.live?.id, "next")

        let withoutTiming = projectConversation(chat, history: history, sends: nil, live: live,
                                                terminalEvent: nil, canShowLive: true, connected: true, now: visibleAt)
        XCTAssertEqual(withoutTiming.row?.readout, .waiting)
        XCTAssertEqual(withoutTiming.row?.cacheHit, 0.8)

        let end = TurnEnd(id: "next", at: start.addingTimeInterval(14), phase: .completed)
        history.usage["unmatched"] = RecordedUsage(id: "unmatched", turn: "next", at: end.at,
                                                  output: 100, input: 1000, cached: 800)
        let recent = projectConversation(chat, history: history, sends: [oldMarker], live: live,
                                         terminalEvent: end, canShowLive: true, connected: true, now: end.at)
        XCTAssertEqual(recent.row?.active, false)
        XCTAssertEqual(recent.row?.orderDate, end.at)
        XCTAssertEqual(recent.row?.readout, .settled(60))
        XCTAssertNil(recent.live)
    }

    func testToolGapIsExcludedAndReplayKeepsOneSettlementPerResponse() throws {
        let first = usage("one", at: 10, output: 600)
        let second = usage("two", at: 45, output: 200)
        let starts = [SendMarker(turn: "turn", at: start), SendMarker(turn: "turn", at: start.addingTimeInterval(40))]
        let summary = ReplyMetrics(usage: [second, first, first, second], sends: starts)
        XCTAssertEqual(summary.replies.count, 2)
        XCTAssertEqual(summary.replies[0].speed, 60)
        XCTAssertEqual(summary.lastRate, 40)
        XCTAssertEqual(try XCTUnwrap(summary.average), 53.333333, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(summary.cacheHit), 0.8, accuracy: 0.00001)
    }

    func testAmbiguousRequestUsesOnlyTheRecordedCacheCounters() {
        let markers = [0.0, 3.0].map { SendMarker(turn: "turn", at: start.addingTimeInterval($0)) }
        let result = ReplyMetrics(usage: [usage("one", at: 10, output: 600)], sends: markers)
        XCTAssertNil(result.lastRate)
        XCTAssertNil(result.average)
        XCTAssertEqual(result.cacheHit, 0.8)
        let missing = RecordedUsage(id: "two", turn: "turn", at: start.addingTimeInterval(20),
                                    output: 100, input: 1_000, cached: nil)
        XCTAssertNil(ReplyMetrics(usage: [usage("one", at: 10, output: 600), missing], sends: markers).cacheHit)
    }

    func testLateSettlementAndToolWaitPreserveTheCurrentRequest() {
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

        let sends = [SendMarker(turn: "turn", at: start), SendMarker(turn: "turn", at: at(40))]
        let summary = ReplyMetrics(usage: [usage("one", at: 10, output: 600)], sends: sends)
        var live = LiveTurn(id: "turn", began: start, observedSince: start)

        func readout(at seconds: TimeInterval) -> ConversationRow.Readout {
            live.display(turn: "turn", sends: sends, metrics: summary,
                         savedAssistantAt: nil, now: at(seconds)).readout
        }

        live.apply(.init(kind: .toolStarted, item: "command", at: at(10)), now: at(10))
        XCTAssertEqual(live.phase, .runningTool)
        XCTAssertEqual(readout(at: 12), .elapsed(2))
        live.apply(.init(kind: .active, at: at(12), phase: .awaitingApproval), now: at(12))
        XCTAssertEqual(live.phase, .awaitingApproval)
        XCTAssertEqual(readout(at: 12), .elapsed(0))
        live.apply(.init(kind: .active, at: at(14), phase: .awaitingApproval), now: at(14))
        XCTAssertEqual(readout(at: 15), .elapsed(3))
        live.apply(.init(kind: .active, at: at(16), phase: .awaitingInput), now: at(16))
        XCTAssertEqual(live.phase, .awaitingInput)
        XCTAssertEqual(readout(at: 16), .elapsed(0))
        XCTAssertEqual(readout(at: 20), .elapsed(4))
        live.apply(.init(kind: .active, at: at(21)), now: at(21))
        XCTAssertEqual(live.phase, .runningTool)
        XCTAssertEqual(readout(at: 24), .elapsed(3))

        live.apply(.init(kind: .toolEnded, item: "command", at: at(38)), now: at(38))
        live.apply(.init(kind: .text, item: "next", at: at(42), characters: 320), now: at(42))
        XCTAssertEqual(readout(at: 42), .live(40))
        XCTAssertEqual(readout(at: 47), .waiting)
    }

    func testPartialStreamAndReconnectWithLostPrefixRequireAFreshBaseline() {
        let marker = SendMarker(turn: "turn", at: start)
        let empty = ReplyMetrics(usage: [], sends: [])
        let joined = start.addingTimeInterval(2)
        let sample = start.addingTimeInterval(3)
        var live = LiveTurn(id: "turn", began: start, observedSince: joined)
        live.apply(.init(kind: .text, item: "existing", at: sample, characters: 80), now: sample)
        XCTAssertEqual(live.display(turn: "turn", sends: [marker], metrics: empty,
                                    savedAssistantAt: nil, now: sample).readout, .waiting)
        live.interruptCoverage(at: sample)
        live.apply(.init(kind: .itemStarted, item: "new", at: sample), now: sample)
        XCTAssertEqual(live.phase, .preparing)
        live.apply(.init(kind: .text, item: "new", at: sample.addingTimeInterval(1), characters: 80), now: sample)
        XCTAssertEqual(live.display(turn: "turn", sends: [marker], metrics: empty,
                                    savedAssistantAt: nil, now: sample.addingTimeInterval(1)).readout, .waiting)
    }

    func testDesktopResumesLiveSpeedAfterAGapWithCompleteOutput() {
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
        let marker = SendMarker(turn: "turn", at: at(1))
        let empty = ReplyMetrics(usage: [], sends: [])
        var live = LiveTurn(id: "turn", began: start, observedSince: start)
        live.apply(.init(kind: .reasoning, item: "thought", at: at(2)), now: at(2))
        live.interruptCoverage(at: at(3), preservingOutput: true)
        XCTAssertFalse(live.confirmed)
        XCTAssertEqual(live.display(turn: "turn", sends: [marker], metrics: empty,
                                    savedAssistantAt: nil, now: at(4)).phase, .unconfirmed)

        live.apply(.init(kind: .reasoningEnded, item: "thought", at: at(4)), now: at(4))
        live.apply(.init(kind: .itemStarted, item: "reply", at: at(5)), now: at(5))
        live.apply(.init(kind: .text, item: "reply", at: at(6), characters: 200), now: at(6))
        XCTAssertEqual(live.display(turn: "turn", sends: [marker], metrics: empty,
                                    savedAssistantAt: nil, now: at(6)).readout, .live(10))
        live.apply(.init(kind: .text, item: "reply", at: at(7), characters: 520), now: at(7))
        XCTAssertEqual(live.display(turn: "turn", sends: [marker], metrics: empty,
                                    savedAssistantAt: nil, now: at(7)).readout, .live(30))

        live.interruptCoverage(at: at(8), preservingOutput: true)
        live.apply(.init(kind: .text, item: "reply", at: at(9), characters: 400), now: at(9))
        XCTAssertEqual(live.display(turn: "turn", sends: [marker], metrics: empty,
                                    savedAssistantAt: nil, now: at(9)).readout, .live(35))
    }

    func testUnverifiedDesktopGapInvalidatesPreservedOutput() {
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
        let marker = SendMarker(turn: "turn", at: at(1))
        let empty = ReplyMetrics(usage: [], sends: [])
        var live = LiveTurn(id: "turn", began: start, observedSince: start)
        live.apply(.init(kind: .itemStarted, item: "reply", at: at(2)), now: at(2))
        live.apply(.init(kind: .text, item: "reply", at: at(3), characters: 120), now: at(3))
        live.interruptCoverage(at: at(4), preservingOutput: true)
        live.interruptCoverage(at: at(5))
        live.interruptCoverage(at: at(6), preservingOutput: true)
        XCTAssertEqual(live.display(turn: "turn", sends: [marker], metrics: empty,
                                    savedAssistantAt: nil, now: at(6)).readout, .elapsed(2))

        live.apply(.init(kind: .itemStarted, item: "later", at: at(7)), now: at(7))
        live.apply(.init(kind: .text, item: "later", at: at(8), characters: 160), now: at(8))
        XCTAssertEqual(live.display(turn: "turn", sends: [marker], metrics: empty,
                                    savedAssistantAt: nil, now: at(8)).readout, .waiting)

        let next = SendMarker(turn: "turn", at: at(10))
        let sent = [marker, next]
        let settled = ReplyMetrics(usage: [usage("reply", at: 9, output: 480)], sends: sent)
        XCTAssertEqual(settled.lastRate, 60)
        live.discardSettledSamples(before: at(9))
        live.apply(.init(kind: .itemStarted, item: "next", at: at(11)), now: at(11))
        live.apply(.init(kind: .text, item: "next", at: at(12), characters: 160), now: at(12))
        XCTAssertEqual(live.display(turn: "turn", sends: sent, metrics: settled,
                                    savedAssistantAt: nil, now: at(12)).readout, .live(20))
    }

    func testPhaseElapsedTimeTracksTransitionsAndReconnection() {
        let empty = ReplyMetrics(usage: [], sends: [])
        var live = LiveTurn(id: "turn", began: start, observedSince: start)

        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
        func value(at seconds: TimeInterval) -> String? {
            live.display(turn: "turn", sends: [], metrics: empty,
                         savedAssistantAt: nil, now: at(seconds)).readout.text
        }

        let row = ConversationRow(id: "chat", title: "Chat", client: .desktop, phase: .preparing,
                                  active: true, orderDate: start, readout: .elapsed(2))
        XCTAssertEqual(row.statusText, "Working · Desktop")
        XCTAssertEqual(value(at: 2), "2s")
        live.apply(.init(kind: .toolStarted, item: "read", at: at(3), phase: .reading), now: at(3))
        live.apply(.init(kind: .toolStarted, item: "search", at: at(5), phase: .reading), now: at(5))
        XCTAssertEqual(value(at: 7), "4s")
        live.apply(.init(kind: .toolEnded, item: "read", at: at(8)), now: at(8))
        live.apply(.init(kind: .toolEnded, item: "search", at: at(8)), now: at(8))
        live.apply(.init(kind: .reasoning, item: "reason", at: at(8)), now: at(8))
        live.apply(.init(kind: .reasoning, item: "reason", at: at(15)), now: at(15))
        XCTAssertEqual(value(at: 20), "12s")
        XCTAssertEqual(value(at: 71), "1m 3s")

        live.interruptCoverage(at: at(72))
        XCTAssertEqual(live.display(turn: "turn", sends: [], metrics: empty,
                                    savedAssistantAt: nil, now: at(74)).phase, .unconfirmed)
        XCTAssertEqual(value(at: 74), "2s")
        live.interruptCoverage(at: at(75))
        XCTAssertEqual(value(at: 77), "5s")
        live.apply(.init(kind: .active, at: at(78)), now: at(78))
        XCTAssertEqual(value(at: 80), "2s")
    }

    func testConnectionWarningClockSurvivesPollsAndRestartsOnChange() {
        var connection = ConnectionInfo(status: .connected)
        let detected = start.addingTimeInterval(5)
        connection.update(.unavailable, lastUpdate: start, now: detected)
        XCTAssertTrue(connection.status.isWarning)
        XCTAssertEqual(connection.warningSince, detected)
        XCTAssertEqual(connection.lastUpdate, start)
        connection.update(.unavailable, lastUpdate: start, now: start.addingTimeInterval(8))
        XCTAssertEqual(connection.warningSince, detected)

        let reconnected = start.addingTimeInterval(10)
        connection.update(.unconfirmed, lastUpdate: nil, now: reconnected)
        XCTAssertTrue(connection.status.isWarning)
        XCTAssertEqual(connection.warningSince, reconnected)
        connection.update(.connected, lastUpdate: nil, now: start.addingTimeInterval(12))
        XCTAssertFalse(connection.status.isWarning)
        XCTAssertNil(connection.warningSince)

        XCTAssertNil(ConversationRow.Readout.hidden.text)
        XCTAssertEqual(ConversationRow.Readout.settled(nil).text, "— tok/s")
    }

    func testCLIWarnsOnlyAfterConnectingDuringTheCurrentRun() {
        var cli = ConnectionRunState()

        let stopped = cli.status(running: false, available: true, unconfirmed: true)
        XCTAssertEqual(stopped.title, "Not running")
        XCTAssertFalse(stopped.isWarning)
        XCTAssertEqual(cli.status(running: true, available: false, unconfirmed: false), .checking)
        XCTAssertEqual(cli.status(running: true, available: true, unconfirmed: false), .connected)
        XCTAssertEqual(cli.status(running: true, available: false, unconfirmed: false), .unavailable)
        XCTAssertEqual(cli.status(running: true, available: true, unconfirmed: true), .unconfirmed)
        XCTAssertEqual(cli.status(running: false, available: false, unconfirmed: true), .notRunning)
        XCTAssertEqual(cli.status(running: true, available: false, unconfirmed: true), .checking)
    }

    func testWaitingForSpeedStartsWithVisibleTextAndEndsAtTheNextRequest() throws {
        let marker = SendMarker(turn: "turn", at: start)
        let empty = ReplyMetrics(usage: [], sends: [])
        var live = LiveTurn(id: "turn", began: start, observedSince: start)
        let at = start.addingTimeInterval(2)

        XCTAssertEqual(live.display(turn: "turn", sends: [marker], metrics: empty,
                                    savedAssistantAt: nil, now: at).phase, .preparing)
        let reason = try XCTUnwrap(CodexSignal.from([
            "method": "item/reasoning/summaryPartAdded",
            "params": ["threadId": "chat", "turnId": "turn", "itemId": "reason", "summaryIndex": 0]
        ]))
        XCTAssertNil(reason.characters)
        live.apply(reason, now: at)
        let thinking = live.display(turn: "turn", sends: [marker], metrics: empty,
                                    savedAssistantAt: nil, now: at)
        XCTAssertEqual(thinking.phase, .thinking)
        XCTAssertEqual(thinking.readout, .elapsed(0))
        let complete = try XCTUnwrap(CodexSignal.from([
            "method": "item/completed",
            "params": ["threadId": "chat", "turnId": "turn", "item": ["id": "reason", "type": "reasoning"]]
        ]))
        live.apply(complete, now: at)
        live.apply(.init(kind: .itemStarted, item: "reply", at: at), now: at)
        let beforeText = live.display(turn: "turn", sends: [marker], metrics: empty,
                                      savedAssistantAt: nil, now: at)
        XCTAssertEqual(beforeText.phase, .preparing)
        XCTAssertEqual(beforeText.readout, .elapsed(0))

        live.apply(.init(kind: .text, item: "reply", at: at, characters: 80), now: at)
        let missingTiming = live.display(turn: "turn", sends: [], metrics: empty,
                                         savedAssistantAt: nil, now: at)
        XCTAssertEqual(missingTiming.phase, .generating)
        XCTAssertEqual(missingTiming.readout, .waiting)
        XCTAssertEqual(live.display(turn: "turn", sends: [marker], metrics: empty,
                                    savedAssistantAt: nil, now: at).readout, .live(10))

        let settled = ReplyMetrics(usage: [usage("first", at: 3, output: 30)], sends: [marker])
        live.discardSettledSamples(before: start.addingTimeInterval(3))
        let lastReply = live.display(turn: "turn", sends: [marker], metrics: settled,
                                      savedAssistantAt: nil, now: start.addingTimeInterval(3))
        XCTAssertEqual(lastReply.phase, .preparing)
        XCTAssertEqual(lastReply.readout, .settled(10))
        let nextMarker = SendMarker(turn: "turn", at: start.addingTimeInterval(4))
        let next = live.display(turn: "turn", sends: [marker, nextMarker], metrics: settled,
                                savedAssistantAt: nil, now: nextMarker.at.addingTimeInterval(2))
        XCTAssertEqual(next.phase, .preparing)
        XCTAssertEqual(next.readout, .elapsed(2))
    }

    func testReadOnlyCommandActionsDisplayReadingWithApprovalTakingPrecedence() throws {
        func startCommand(_ name: String, actions: [String]) throws -> CodexSignal {
            try XCTUnwrap(CodexSignal.from([
                "method": "item/started",
                "params": [
                    "threadId": "chat", "turnId": "turn",
                    "item": ["id": name, "type": "commandExecution",
                             "commandActions": actions.map { ["type": $0] }]
                ]
            ]))
        }
        var live = LiveTurn(id: "turn", began: start, observedSince: start)
        live.apply(try startCommand("read", actions: ["read", "search"]), now: start)
        XCTAssertEqual(live.phase, .reading)
        live.apply(.init(kind: .active, phase: .awaitingApproval), now: start)
        XCTAssertEqual(live.phase, .awaitingApproval)
        live.apply(.init(kind: .active), now: start)
        XCTAssertEqual(live.phase, .reading)
        live.apply(try startCommand("unknown", actions: ["read", "unknown"]), now: start)
        XCTAssertEqual(live.phase, .runningTool)
        live.apply(.init(kind: .toolEnded, item: "unknown", at: start), now: start)
        XCTAssertEqual(live.phase, .reading)
        live.apply(.init(kind: .toolEnded, item: "read", at: start), now: start)
        XCTAssertEqual(live.phase, .preparing)
    }

    func testContextSnapshotCanDecreaseAndRetainsAKnownSide() {
        var history = History()
        history.ingest(Data(#"{"type":"event_msg","timestamp":"2026-11-22T06:00:01.123Z","payload":{"type":"token_count","info":{"model_context_window":128000,"last_token_usage":{"total_tokens":42000}}}}"#.utf8))
        XCTAssertEqual(history.context, ContextUsage(used: 42_000, capacity: 128_000))
        history.ingest(Data(#"{"type":"event_msg","timestamp":"2026-11-22T06:00:02Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":27000}}}}"#.utf8))
        XCTAssertEqual(history.context, ContextUsage(used: 27_000, capacity: nil))
    }

    func testTransportMarkerIsBoundToItsOwnTurnAndSkipsWarmup() {
        let chat = "12345678-1234-1234-abcd-123456789abc"
        let turn = "12345678-1234-1234-abcd-123456789abd"
        let marker = "conversation.id=\"\(chat)\" turn.id=\"\(turn)\" websocket.warmup=false auth_error=\"\""
        XCTAssertEqual(CodexRecords.turnInSendMarker(marker, chat: chat), turn)
        XCTAssertNil(CodexRecords.turnInSendMarker(marker, chat: turn))
        XCTAssertNil(CodexRecords.turnInSendMarker(marker.replacingOccurrences(of: "false", with: "true"), chat: chat))
    }

    func testRelayRecognizesTheDesktopConfigPrefixAndOnlyStdioServerLaunches() {
        XCTAssertTrue(DesktopRelay.isStdioLaunch(["app-server"]))
        XCTAssertTrue(DesktopRelay.isStdioLaunch(["-c", "features.example=true", "app-server",
                                                  "--startup-client-info", "{}", "--analytics-default-enabled"]))
        XCTAssertTrue(DesktopRelay.isStdioLaunch(["--config=example=true", "--enable", "example",
                                                  "app-server", "--listen=stdio://"]))
        XCTAssertTrue(DesktopRelay.isStdioLaunch(["app-server", "--listen", "stdio://"]))
        XCTAssertFalse(DesktopRelay.isStdioLaunch(["-c", "app-server"]))
        XCTAssertFalse(DesktopRelay.isStdioLaunch(["exec", "app-server"]))
        XCTAssertFalse(DesktopRelay.isStdioLaunch(["app-server", "--listen", "unix:///tmp/test"]))
        XCTAssertFalse(DesktopRelay.isStdioLaunch(["app-server", "--listen=off"]))
        XCTAssertFalse(DesktopRelay.isStdioLaunch(["app-server", "--print-startup-config"]))
        XCTAssertFalse(DesktopRelay.isStdioLaunch(["app-server", "-c", "example=true", "proxy"]))
    }

    func testSessionRuntimeEnvironmentReplacesOnlyTheLauncherForItsChild() {
        let runtime = DesktopRuntime(engine: "/Desktop runtime", launcher: "/Codex TPS", endpoint: "fixture")
        let scoped = [
            "CODEX_CLI_PATH": "/Codex TPS",
            "CODEX_APP_RUNTIME_CLI_PATH": "/Codex TPS",
            "OTHER": "kept"
        ]
        XCTAssertEqual(runtime.runtimeEnvironment(scoped), [
            "CODEX_CLI_PATH": "/Desktop runtime",
            "CODEX_APP_RUNTIME_CLI_PATH": "/Desktop runtime",
            "OTHER": "kept"
        ])
        XCTAssertEqual(runtime.runtimeEnvironment(["CODEX_CLI_PATH": "/another/codex"]),
                       ["CODEX_CLI_PATH": "/another/codex"])
    }

    func testDesktopWaitsForLaunchAndFirstConnection() {
        var desktop = DesktopConnectionState()
        func status(_ available: Bool) -> ConnectionStatus {
            desktop.status(available: available, now: start, uptime: DispatchTime(uptimeNanoseconds: 1_000_000_000))
        }
        XCTAssertEqual(status(false), .setup)

        desktop.observe(.pending)
        XCTAssertEqual(status(false), .pending)

        let opened = start.addingTimeInterval(60)
        XCTAssertTrue(desktop.observe(.running(opened)))
        XCTAssertEqual(desktop.launchedAt, opened)
        XCTAssertEqual(status(false), .checking)
        XCTAssertFalse(desktop.observe(.running(opened)))
        XCTAssertEqual(status(false), .checking)
        XCTAssertEqual(status(true), .connected)
        XCTAssertEqual(status(false), .connected)
        XCTAssertEqual(desktop.lossDetectedAt, start)

        let reopened = opened.addingTimeInterval(60)
        XCTAssertTrue(desktop.observe(.running(reopened)))
        XCTAssertFalse(desktop.connectedDuringRun)
        XCTAssertNil(desktop.lossDetectedAt)
        XCTAssertEqual(status(false), .checking)
        XCTAssertEqual(status(true), .connected)

        desktop.observe(.setup)
        let stopped = status(true)
        XCTAssertEqual(stopped, .setup)
        XCTAssertFalse(stopped.isWarning)
        XCTAssertNil(desktop.launchedAt)
    }

    func testDesktopQuitDuringDisconnectConfirmationTurnsLiveOff() {
        var desktop = DesktopConnectionState()
        desktop.observe(.running(start))
        let clock = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        XCTAssertEqual(desktop.status(available: true, now: start, uptime: clock), .connected)
        let detection = start.addingTimeInterval(1)
        XCTAssertEqual(desktop.status(available: false, now: detection, uptime: clock + .seconds(1)), .connected)

        desktop.observe(.setup)
        let stopped = desktop.status(available: false, now: detection.addingTimeInterval(1.324),
                                     uptime: clock + .milliseconds(2324))
        XCTAssertEqual(stopped, .setup)
        XCTAssertFalse(stopped.isWarning)
        XCTAssertNil(desktop.lossDetectedAt)
    }

    func testDesktopShortRecoveryClearsLossAndPersistentLossUsesTheNewDetectionTime() {
        var desktop = DesktopConnectionState()
        desktop.observe(.running(start))
        let clock = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        func status(_ available: Bool, at milliseconds: Int) -> ConnectionStatus {
            desktop.status(available: available, now: start.addingTimeInterval(Double(milliseconds) / 1000),
                           uptime: clock + .milliseconds(milliseconds))
        }
        XCTAssertEqual(status(true, at: 0), .connected)
        XCTAssertEqual(status(false, at: 500), .connected)
        XCTAssertEqual(status(true, at: 1500), .connected)
        XCTAssertNil(desktop.lossDetectedAt)

        let detection = start.addingTimeInterval(2)
        XCTAssertEqual(status(false, at: 2000), .connected)
        XCTAssertEqual(status(false, at: 3999), .connected)
        let confirmed = status(false, at: 4000)
        XCTAssertEqual(confirmed, .unavailable)
        XCTAssertEqual(desktop.lossDetectedAt, detection)

        var info = ConnectionInfo(status: .connected)
        let shown = start.addingTimeInterval(4)
        info.update(confirmed, lastUpdate: start, now: shown, warningStartedAt: desktop.lossDetectedAt)
        XCTAssertEqual(info.warningSince, detection)
        XCTAssertEqual(DisplayFormat.seconds(since: info.warningSince ?? shown, now: shown), 2)
        info.update(status(false, at: 5500), lastUpdate: start, now: start.addingTimeInterval(5.5))
        XCTAssertEqual(info.warningSince, detection)
        info.update(status(true, at: 6000), lastUpdate: nil, now: start.addingTimeInterval(6))
        XCTAssertNil(info.warningSince)
        XCTAssertNil(desktop.lossDetectedAt)
    }

    func testDesktopRowKeepsItsLastPhaseAndPausesSpeedDuringDisconnectConfirmation() throws {
        let chat = ChatMetadata(id: "desktop", title: "Test chat", client: .desktop,
                                rollout: URL(fileURLWithPath: "/unused"), updated: start)
        let marker = SendMarker(turn: "turn", at: start)
        var live = LiveTurn(id: "turn", began: start, observedSince: start)
        let sample = start.addingTimeInterval(2)
        live.apply(.init(kind: .text, turn: "turn", at: sample, characters: 80), now: sample)
        let generating = projectConversation(chat, history: History(), sends: [marker], live: live,
                                             terminalEvent: nil, canShowLive: true, connected: true, now: sample)
        XCTAssertEqual(generating.row?.phase, .generating)
        XCTAssertEqual(generating.row?.readout, .live(10))

        let loss = start.addingTimeInterval(7)
        var interrupted = try XCTUnwrap(generating.live)
        interrupted.interruptCoverage(at: loss, preservingOutput: true)
        let confirming = projectConversation(chat, history: History(), sends: [marker], live: interrupted,
                                             terminalEvent: nil, canShowLive: true, connected: false,
                                             confirmingDisconnect: true, now: loss)
        XCTAssertEqual(confirming.row?.phase, .generating)
        XCTAssertEqual(confirming.row?.readout, .hidden)
        XCTAssertEqual(confirming.row?.active, true)

        let unavailable = projectConversation(chat, history: History(), sends: [marker], live: confirming.live,
                                              terminalEvent: nil, canShowLive: true, connected: false,
                                              now: loss.addingTimeInterval(2))
        XCTAssertEqual(unavailable.row?.phase, .unavailable)
    }

    func testSessionPortsRequireRegistrationAndFallAwayWhenClosed() throws {
        let first = DesktopReceiver()
        let second = DesktopReceiver()
        let firstQueue = DispatchQueue(label: "local.codex-tps.test.first")
        let secondQueue = DispatchQueue(label: "local.codex-tps.test.second")
        let firstName = try firstQueue.sync { try first.start(on: firstQueue) }
        let secondName = try secondQueue.sync { try second.start(on: secondQueue) }
        defer {
            firstQueue.sync { first.stop() }
            secondQueue.sync { second.stop() }
        }
        XCTAssertNotEqual(firstName, secondName)
        let sender = try XCTUnwrap(RelaySender(endpoint: firstName))
        XCTAssertFalse(sender.hasListener)
        XCTAssertTrue(sender.register())
        XCTAssertTrue(sender.hasListener)
        XCTAssertTrue(secondQueue.sync { second.processes.isEmpty })

        firstQueue.sync { first.setObservation(false) }
        sender.refreshObservation()
        XCTAssertFalse(sender.hasListener)
        firstQueue.sync { first.setObservation(true) }
        sender.refreshObservation()
        XCTAssertTrue(sender.hasListener)

        let retiring = firstQueue.sync { first.finishObservation() }
        let process = try XCTUnwrap(RelayProcess(getpid()))
        XCTAssertEqual(retiring, [process])
        XCTAssertFalse(sender.register())

        firstQueue.sync { first.stop() }
        sender.refreshObservation()
        XCTAssertFalse(sender.hasListener)
        XCTAssertTrue(secondQueue.sync { second.isListening })
    }

    func testRelayDiscoveryFindsAnExecutableLaunchedBelowADesktopHelper() throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "/bin/sh -c '/bin/sleep 6 & wait' & wait"]
        try helper.run()
        defer { if helper.isRunning { helper.terminate() } }

        let executable = URL(fileURLWithPath: "/bin/sleep")
        let deadline = Date().addingTimeInterval(2)
        var relays = Set<RelayProcess>()
        while relays.isEmpty && Date() < deadline {
            relays = RelayProcess.descendants(of: helper.processIdentifier, running: executable)
            if relays.isEmpty { Thread.sleep(forTimeInterval: 0.01) }
        }
        defer { for relay in relays where relay.isRunning { _ = kill(relay.pid, SIGTERM) } }
        XCTAssertEqual(relays.count, 1)
    }

    func testRelayOutputSequenceDistinguishesMissedTextFromPhaseNotifications() throws {
        let receiver = DesktopReceiver()
        let queue = DispatchQueue(label: "local.codex-tps.test.output-sequence")
        defer { queue.sync { receiver.stop() } }
        let endpoint = try queue.sync { try receiver.start(on: queue) }
        let received = expectation(description: "Receiver gets six sequence markers")
        received.expectedFulfillmentCount = 6
        var packets: [RelayPacket] = []
        queue.sync {
            receiver.onPacket = { packet in
                packets.append(packet)
                received.fulfill()
            }
        }

        let sender = try XCTUnwrap(RelaySender(endpoint: endpoint))
        XCTAssertTrue(sender.register())
        sender.emit(.init(kind: .heartbeat))
        sender.emit(.init(kind: .reasoning, thread: "chat"))
        sender.emit(.init(kind: .text, thread: "chat", characters: 40))
        sender.emit(.init(kind: .reasoningEnded, thread: "chat"))
        sender.skip(RelayLoss(reason: .malformedFrame, impact: .unknown))
        sender.emit(.init(kind: .heartbeat))
        sender.emit(.init(kind: .text, thread: "chat", characters: 80))
        wait(for: [received], timeout: 2)
        try queue.sync {
            guard packets.count == 6 else { return XCTFail("Missing relay packets") }
            XCTAssertEqual(packets.map(\.sequence), [1, 2, 3, 4, 6, 7])
            XCTAssertEqual(packets.map(\.outputSequence), [0, 0, 1, 1, 2, 3])
            XCTAssertTrue(packets[2].hasContinuousOutput(after: packets[0]))
            XCTAssertFalse(packets[3].hasContinuousOutput(after: packets[1]))
            XCTAssertFalse(packets[4].hasContinuousOutput(after: packets[3]))
            XCTAssertTrue(packets[5].hasContinuousOutput(after: packets[4]))
            XCTAssertEqual(packets[4].gap(after: packets[3])?.impact(on: "chat"), .unknown)
            let incompletePacket = Data("""
                {"session":"\(packets[0].session)","sequence":1,"signal":{"kind":"heartbeat","thread":"","at":0}}
                """.utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(RelayPacket.self, from: incompletePacket))
        }
    }

    func testRelayMarksUninspectedOutputAsAGap() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inputURL = folder.appendingPathComponent("input")
        let outputURL = folder.appendingPathComponent("output")
        let bytes = Data("""
            {"method":"item/agentMessage/delta","params":{"threadId":"chat","delta":""}}
            discarded JSON
            {"method":"item/agentMessage/delta","params":{"delta":"unknown chat"}}
            {"method":"item/agentMessage/delta","params":{"threadId":"chat","delta":"visible"}}

            """.utf8)
        try bytes.write(to: inputURL)
        for listening in [true, false] {
            try Data().write(to: outputURL)
            let input = try FileHandle(forReadingFrom: inputURL)
            let output = try FileHandle(forWritingTo: outputURL)
            var kinds: [SignalKind] = []
            var losses: [RelayLoss] = []
            try DesktopRelay.forwardObserved(input, to: output, listening: { listening },
                                             emit: { kinds.append($0.kind) }, skip: { losses.append($0) })
            XCTAssertEqual(kinds, listening ? [.text] : [])
            XCTAssertEqual(losses.map(\.reason), listening ? [.malformedFrame, .malformedText] : [.listenerUnavailable])
            XCTAssertEqual(losses.map(\.impact), listening ? [.unknown, .output] : [.unknown])
            XCTAssertEqual(try Data(contentsOf: outputURL), bytes)
        }
    }

    func testOversizedRelayLineReportsOneGapAndPreservesForwardedBytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Data(#"{"method":"item/started","params":{"threadId":"chat","item":{"type":"commandExecution","id":"tool"}}}"#.utf8)
        let end = Data(#"{"method":"item/completed","params":{"threadId":"chat","item":{"type":"commandExecution","id":"tool"}}}"#.utf8)
        let delta = Data(#"{"method":"item/agentMessage/delta","params":{"threadId":"chat","delta":"more"}}"#.utf8)
        let limit = 2_097_152
        let overflow = (start.count + 1) * 2 + (limit + 1) + limit
        let boundary = (65_535 - overflow % 65_536 + 65_536) % 65_536
        for prefix in [Data(), Data(repeating: 32, count: boundary - 1) + Data([10])] {
            var bytes = prefix
            bytes += start + Data([10])
            bytes += end + Data(repeating: 32, count: limit - end.count) + Data([10])
            bytes += start + Data([10])
            bytes += end + Data(repeating: 32, count: limit + 1 - end.count) + Data([10])
            bytes += delta + Data([10])
            let inputURL = dir.appendingPathComponent("in")
            let outputURL = dir.appendingPathComponent("out")
            try bytes.write(to: inputURL)
            try Data().write(to: outputURL)
            let input = try FileHandle(forReadingFrom: inputURL)
            let output = try FileHandle(forWritingTo: outputURL)
            var kinds: [SignalKind] = []
            var losses: [RelayLoss] = []
            try DesktopRelay.forwardObserved(input, to: output, listening: { true },
                                             emit: { kinds.append($0.kind) }, skip: { losses.append($0) })
            XCTAssertEqual(kinds, [.toolStarted, .toolEnded, .toolStarted, .text])
            XCTAssertEqual(losses, [RelayLoss(reason: .oversizedFrame, impact: .activity, event: "item/completed")])
            XCTAssertEqual(try Data(contentsOf: outputURL), bytes)
        }
    }

    private func usage(_ id: String, at offset: TimeInterval, output: Int) -> RecordedUsage {
        RecordedUsage(id: id, turn: "turn", at: start.addingTimeInterval(offset),
                      output: output, input: 1_000, cached: 800)
    }

    private func makeRow(_ id: String, at offset: TimeInterval, active: Bool) -> ConversationRow {
        ConversationRow(id: id, title: id, client: .desktop, phase: active ? .generating : .completed,
                        active: active, orderDate: start.addingTimeInterval(offset), readout: .hidden)
    }
}
