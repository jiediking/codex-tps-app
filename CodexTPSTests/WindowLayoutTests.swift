import AppKit
import SwiftUI
import XCTest
@testable import CodexTPS

final class WindowLayoutTests: XCTestCase {
    @MainActor
    func testHiddenCardAndClosedMenuSkipMeasurementsDuringLiveUpdates() async throws {
        _ = try XCTUnwrap(NSScreen.screens.first)
        let defaults = try isolatedDefaults()
        let state = AppState(defaults: defaults)
        let card = CardWindow(state: state, defaults: defaults)
        defer { card.panel.orderOut(nil) }
        let menu = makeMenu(state)
        state.isCardVisible = false
        await drainLayout()
        let hiddenFrame = card.panel.frame
        let cardStart = card.sizeMeasurements
        let menuStart = menu.sizeMeasurements

        await publishSpeeds(to: state)

        let cardDelta = card.sizeMeasurements - cardStart
        let menuDelta = menu.sizeMeasurements - menuStart
        print("24 live snapshots with five conversations: hidden card measured \(cardDelta), closed menu measured \(menuDelta)")
        XCTAssertEqual(cardDelta, 0)
        XCTAssertEqual(menuDelta, 0)
        XCTAssertEqual(card.panel.frame, hiddenFrame)

        state.isCardVisible = true
        await drainLayout()
        XCTAssertTrue(card.panel.isVisible)
        XCTAssertGreaterThan(card.panel.frame.height, hiddenFrame.height)
        XCTAssertEqual(card.sizeMeasurements - cardStart, 1)
    }

    @MainActor
    func testOpenMenuSizesItsSectionsWithoutMeasuringLiveSpeedUpdates() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let panel = NSPanel(contentRect: CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY,
                                               width: 28, height: 28),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let anchor = try XCTUnwrap(panel.contentView)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        let state = AppState(defaults: try isolatedDefaults())
        let menu = makeMenu(state)
        menu.showPopover(relativeTo: anchor)
        defer { if menu.isShown { menu.togglePopover() } }
        XCTAssertTrue(menu.isShown)
        await drainLayout()
        let collapsed = menu.contentSize.height
        let beforeSpeeds = menu.sizeMeasurements

        await publishSpeeds(to: state)

        let delta = menu.sizeMeasurements - beforeSpeeds
        print("24 live snapshots with the menu open: measured \(delta)")
        XCTAssertEqual(delta, 0)
        XCTAssertEqual(menu.contentSize.height, collapsed)

        state.cardStylesOpen = true
        await assertEventually("The style list did not expand.") { menu.contentSize.height > collapsed }
        let styles = menu.contentSize.height
        state.connectionsOpen = true
        await assertEventually("The connection list did not expand.") { menu.contentSize.height > styles }
        let connections = menu.contentSize.height

        state.desktopDetailsOpen = true
        state.connections[.desktop] = .init(status: .paused)
        await assertEventually("The popover did not fit the pause and resume details.") {
            menu.contentSize.height > connections + 20
        }
        state.connectionMessage = String(repeating: "The fixture needs more information to finish connecting. ", count: 7)
        await assertEventually("The popover did not fit the wrapped message.") {
            menu.contentSize.height > connections + 60
        }

        let beforeReopen = menu.sizeMeasurements
        menu.togglePopover()
        menu.showPopover(relativeTo: anchor)
        XCTAssertTrue(menu.isShown)
        XCTAssertEqual(menu.contentSize.height, collapsed, accuracy: 1)
        XCTAssertEqual(menu.sizeMeasurements - beforeReopen, 1)
    }

    @MainActor
    func testVisibleCardCoalescesUpdatesAndFitsExpandedAndWrappedContent() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        guard screen.visibleFrame.width >= 540, screen.visibleFrame.height >= 540 else {
            throw XCTSkip("Fixture needs room to expand and scale the card.")
        }
        let defaults = try isolatedDefaults()
        let state = AppState(defaults: defaults)
        state.rows = liveRows(rate: 40)
        let card = CardWindow(state: state, defaults: defaults)
        defer { card.panel.orderOut(nil) }
        await drainLayout()
        let collapsed = card.panel.frame
        let beforeBurst = card.sizeMeasurements

        state.rows = liveRows(rate: 41)
        state.connections[.desktop] = .init(status: .connected)
        state.isExpanded = true
        await drainLayout()

        let delta = card.sizeMeasurements - beforeBurst
        print("Visible card with three changes in one batch: measured \(delta)")
        XCTAssertEqual(delta, 1)
        XCTAssertGreaterThan(card.panel.frame.height, collapsed.height)
        XCTAssertEqual(card.panel.frame.maxY, collapsed.maxY, accuracy: 1)

        state.rows = liveRows(rate: 40, count: 1)
        await drainLayout()
        XCTAssertFalse(state.isExpanded)
        let oneRowHeight = card.panel.frame.height
        let short = try XCTUnwrap(state.rows.first)
        state.rows = [
            .init(id: short.id, title: short.title, client: .desktop, phase: .unconfirmed, active: true,
                  orderDate: short.orderDate, readout: .live(1_234_567_890_123_456),
                  average: 1_234_567_890_123, cacheHit: 0.98, context: .init(used: Int.max / 2, capacity: Int.max))
        ]
        await drainLayout()
        let wrapped = card.panel.frame.height
        XCTAssertGreaterThan(wrapped, oneRowHeight + 20)
        let host = try XCTUnwrap(card.panel.contentView as? NSHostingView<DesktopCard>)
        XCTAssertEqual(wrapped, ceil(host.fittingSize.height), accuracy: 1)

        state.setMetric(.context, enabled: false)
        state.setMetric(.average, enabled: false)
        await drainLayout()
        XCTAssertLessThan(card.panel.frame.height, wrapped)

        let frame = card.panel.frame
        let handle = CGPoint(x: frame.width - 14, y: 13)
        let destination = CGPoint(x: handle.x + 54, y: handle.y)
        let resize = try XCTUnwrap(host.rootView.resize)
        resize(try mouse(.leftMouseDown, in: card.panel, at: handle))
        state.rows = liveRows(rate: 55)
        resize(try mouse(.leftMouseDragged, in: card.panel, at: destination))
        resize(try mouse(.leftMouseUp, in: card.panel, at: destination))
        await drainLayout()
        XCTAssertEqual(card.panel.frame.width, frame.width + 54, accuracy: 1)
        XCTAssertEqual(card.panel.frame.minX, frame.minX, accuracy: 1)
        XCTAssertEqual(card.panel.frame.maxY, frame.maxY, accuracy: 1)
        XCTAssertEqual(defaults.double(forKey: "CardScale"), 1.15, accuracy: 0.01)
    }

    @MainActor
    func testCardAnimationPausesUnderAFullCoverAndResumesOnReveal() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        guard screen.visibleFrame.width >= 420, screen.visibleFrame.height >= 400 else {
            throw XCTSkip("Fixture needs room for the card and its cover.")
        }
        let defaults = try isolatedDefaults()
        let state = AppState(defaults: defaults)
        state.isPinned = true
        state.setCardTheme(.sunlitLeaf)
        state.rows = liveRows(rate: 40)
        let card = CardWindow(state: state, defaults: defaults)
        card.panel.ignoresMouseEvents = true
        defer { card.panel.orderOut(nil) }
        await assertEventually("Animation did not start when the card appeared.") { state.shouldAnimateCard }

        let cover = NSPanel(contentRect: card.panel.frame.insetBy(dx: -10, dy: -10),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        cover.backgroundColor = .white
        cover.isOpaque = true
        cover.hasShadow = false
        cover.hidesOnDeactivate = false
        cover.ignoresMouseEvents = true
        cover.animationBehavior = .none
        cover.level = NSWindow.Level(rawValue: card.panel.level.rawValue + 1)
        defer { cover.orderOut(nil) }

        let beforeCover = card.sizeMeasurements
        cover.orderFrontRegardless()
        await assertEventually("Animation continued while the card was fully covered.") {
            card.panel.isVisible && !state.shouldAnimateCard
        }
        XCTAssertEqual(card.sizeMeasurements, beforeCover)

        var partialFrame = cover.frame
        partialFrame.size.width *= 0.7
        cover.setFrame(partialFrame, display: true)
        await assertEventually("Animation did not resume when part of the card appeared.") {
            state.shouldAnimateCard
        }
        cover.orderOut(nil)
        state.isCardVisible = false
        await assertEventually("Hiding the card did not stop the animation.") {
            !card.panel.isVisible && !state.shouldAnimateCard
        }
        state.isCardVisible = true
        await assertEventually("Animation did not resume after showing the card.") { state.shouldAnimateCard }
    }

    @MainActor
    func testDisplayRefreshKeepsInMemoryDragPositionOnTheSameDisplay() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let visible = screen.visibleFrame
        guard visible.width >= 650, visible.height >= 420 else {
            throw XCTSkip("Fixture needs room on the display.")
        }
        let state = AppState(defaults: try isolatedDefaults())
        let card = CardWindow(state: state)
        defer { card.panel.orderOut(nil) }
        let size = card.panel.frame.size
        let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        card.panel.setFrameOrigin(origin)
        let dragged = card.panel.frame

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        await drainLayout()

        XCTAssertEqual(card.panel.frame.minX, dragged.minX, accuracy: 1)
        XCTAssertEqual(card.panel.frame.maxY, dragged.maxY, accuracy: 1)
    }

    @MainActor
    func testCardRetainsSavedCornerWhenDisplayIDIsUnavailable() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let visible = screen.visibleFrame
        guard visible.width >= 650, visible.height >= 420 else {
            throw XCTSkip("Fixture needs room on the display.")
        }
        let displayIDs = Set(NSScreen.screens.compactMap(CardPlacement.id(for:)))
        let missingID = try XCTUnwrap((1...UInt32(displayIDs.count + 1)).first { !displayIDs.contains($0) })
        let topLeft = CGPoint(x: visible.minX + visible.width / 4, y: visible.maxY - visible.height / 4)
        let defaults = try isolatedDefaults()
        defaults.set(["screen": missingID, "x": topLeft.x, "top": topLeft.y], forKey: "CardPlacement")

        let card = CardWindow(state: AppState(defaults: defaults), defaults: defaults)
        defer { card.panel.orderOut(nil) }

        XCTAssertEqual(card.panel.frame.minX, topLeft.x, accuracy: 1)
        XCTAssertEqual(card.panel.frame.maxY, topLeft.y, accuracy: 1)

        // A delayed move notification from the fallback layout must keep the original display preference.
        card.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: card.panel))
        XCTAssertEqual(defaults.dictionary(forKey: "CardPlacement")?["screen"] as? UInt32, missingID)
    }

    @MainActor
    func testWakeRestoresDraggedCardAfterTheWindowServerMovesIt() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let visible = screen.visibleFrame
        guard visible.width >= 650, visible.height >= 420 else {
            throw XCTSkip("Fixture needs room on the display.")
        }
        let workspace = NSWorkspace.shared
        for pinned in [false, true] {
            let defaults = try isolatedDefaults()
            let state = AppState(defaults: defaults)
            let card = CardWindow(state: state, defaults: defaults)
            defer { card.panel.orderOut(nil) }
            let initial = card.panel.frame
            let dragged = CGPoint(x: visible.midX - initial.width / 2, y: visible.midY - initial.height / 2)
            let moved = Notification(name: NSWindow.didMoveNotification, object: card.panel)
            card.panel.setFrameOrigin(dragged)
            card.windowDidMove(moved)

            state.isPinned = pinned
            card.refresh()
            let beforeSleep = card.panel.frame

            workspace.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: workspace)
            card.panel.setFrameOrigin(initial.origin)
            card.windowDidMove(moved)
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
            workspace.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: workspace)
            card.windowDidMove(moved)
            await drainLayout()

            XCTAssertEqual(card.panel.frame.minX, beforeSleep.minX, accuracy: 1, "Pinned: \(pinned)")
            XCTAssertEqual(card.panel.frame.maxY, beforeSleep.maxY, accuracy: 1, "Pinned: \(pinned)")
            XCTAssertEqual(card.panel.isMovable, !pinned)

            if !pinned {
                let newOrigin = CGPoint(x: dragged.x + 24, y: dragged.y)
                card.panel.setFrameOrigin(newOrigin)
                card.windowDidMove(moved)
                let savedX = try XCTUnwrap(defaults.dictionary(forKey: "CardPlacement")?["x"] as? Double)
                XCTAssertEqual(savedX, newOrigin.x, accuracy: 1)
            }
        }
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "local.codex-tps.layout-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor
    private func makeMenu(_ state: AppState) -> MenuWindow {
        MenuWindow(state: state, retry: { _ in }, prepareDesktop: {}, toggleDesktopPause: {})
    }

    @MainActor
    private func publishSpeeds(to state: AppState) async {
        for tick in 0..<24 {
            state.rows = liveRows(rate: 40 + Double(tick))
            await drainLayout()
        }
    }

    private func liveRows(rate: Double, count: Int = 5) -> [ConversationRow] {
        (0..<count).map { index in
            ConversationRow(id: "chat-\(index)", title: "Concurrent conversation \(index + 1)",
                            client: index.isMultiple(of: 2) ? .desktop : .cli, phase: .generating, active: true,
                            orderDate: Date(timeIntervalSinceReferenceDate: Double(index)),
                            readout: .live(rate + Double(index)), average: 40, cacheHit: 0.98,
                            context: .init(used: 29_000, capacity: 128_000))
        }
    }

    @MainActor
    private func drainLayout() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, in panel: NSPanel, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: panel.windowNumber, context: nil,
                                         eventNumber: 1, clickCount: 1, pressure: 1))
    }

    @MainActor
    private func assertEventually(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                                  _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }
}
