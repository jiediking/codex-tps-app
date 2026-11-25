import AppKit
import OSLog
import Foundation

struct LiveTurn {
    private struct Sample {
        let at: Date
        let characters: Int
        let itemStartedAt: Date?
    }

    var id: String?
    var began: Date
    var observedSince: Date
    var confirmed = true
    private(set) var statusObservedAt: Date?
    fileprivate var lastNormalPhase: TurnPhase = .preparing
    private var phaseStartedAt: Date
    private var lostPrefix = false
    private var needsOutputBaseline = false
    private var flags: TurnPhase?
    private var tools: [String: TurnPhase] = [:]
    private var reasoning = Set<String>()
    private var visibleOutputAt: Date?
    private var messageStarts: [String: Date] = [:]
    private var samples: [Sample] = []
    private var resumedWorkAt: Date?

    init(id: String?, began: Date, observedSince: Date) {
        self.id = id
        self.began = began
        self.observedSince = observedSince
        phaseStartedAt = observedSince
    }

    var phase: TurnPhase {
        if let flags { return flags }
        if !tools.isEmpty { return tools.values.allSatisfy { $0 == .reading } ? .reading : .runningTool }
        if !reasoning.isEmpty { return .thinking }
        return visibleOutputAt == nil ? .preparing : .generating
    }

    mutating func interruptCoverage(at now: Date, preservingOutput: Bool = false) {
        interruptCoverage(at: now, impact: preservingOutput ? .activity : .unknown)
    }

    mutating func interruptCoverage(at now: Date, impact: RelayLoss.Impact) {
        if impact.contains(.output), !needsOutputBaseline {
            needsOutputBaseline = true
            lostPrefix = true
            samples.removeAll(keepingCapacity: true)
            messageStarts.removeAll()
        }
        guard impact.contains(.activity), confirmed else { return }
        confirmed = false
        phaseStartedAt = now
        flags = nil
        tools.removeAll()
        reasoning.removeAll()
        visibleOutputAt = nil
    }

    mutating func apply(_ signal: CodexSignal, now: Date, trackStatusIdentity: Bool = true) {
        let previousPhase = confirmed ? phase : .unconfirmed
        if trackStatusIdentity, signal.kind == .active, signal.turn == nil,
           !confirmed || id == nil || statusObservedAt != nil {
            statusObservedAt = now
        }
        if signal.fromThreadRead == true, !confirmed {
            flags = signal.phase
            return
        }
        if !confirmed { confirmed = true }
        if needsOutputBaseline {
            observedSince = now
            needsOutputBaseline = false
        }
        if let turn = signal.turn {
            id = turn
            statusObservedAt = nil
        }
        switch signal.kind {
        case .turnStarted:
            began = signal.at
        case .active:
            if flags == .awaitingInput && signal.phase == nil {
                resumedWorkAt = now
                visibleOutputAt = nil
                reasoning.removeAll()
            }
            flags = signal.phase
        case .itemStarted:
            if let item = signal.item { messageStarts[item] = signal.at }
            resumedWorkAt = signal.at
        case .text:
            if let characters = signal.characters, characters > 0 {
                visibleOutputAt = signal.at
                reasoning.removeAll()
                samples.append(Sample(at: signal.at, characters: characters,
                                      itemStartedAt: signal.item.flatMap { messageStarts[$0] }))
                if samples.count > 60_000 {
                    samples.removeFirst(20_000)
                    lostPrefix = true
                    observedSince = samples[0].at
                }
            }
        case .reasoning:
            if let item = signal.item {
                reasoning.insert(item)
                visibleOutputAt = nil
            }
        case .reasoningEnded:
            if let item = signal.item { reasoning.remove(item) }
        case .toolStarted:
            if let item = signal.item {
                tools[item] = signal.phase ?? .runningTool
                reasoning.removeAll()
                visibleOutputAt = nil
            }
        case .toolEnded:
            if let item = signal.item { tools[item] = nil }
            resumedWorkAt = signal.at
        default: break
        }
        if phase != previousPhase { phaseStartedAt = now }
    }

    mutating func discardSettledSamples(before end: Date) {
        if let first = samples.first, first.at <= end { samples.removeAll { $0.at <= end } }
        messageStarts = messageStarts.filter { $0.value > end }
    }

    func display(turn: String?, sends: [SendMarker]?, metrics: ReplyMetrics,
                 savedAssistantAt: Date?, now: Date) -> (phase: TurnPhase, readout: ConversationRow.Readout) {
        guard confirmed else { return (.unconfirmed, elapsed(since: phaseStartedAt, now: now)) }
        let phase = self.phase

        switch phase {
        case .preparing, .reading, .thinking,
             .runningTool, .awaitingApproval, .awaitingInput:
            return (phase, elapsed(since: phaseStartedAt, now: now))
        default:
            break
        }

        guard phase == .generating, let visibleOutputAt else { return (phase, .hidden) }
        guard let turn, let sends else { return (.generating, .waiting) }
        let reply = metrics.replies.last { $0.usage.turn == turn }
        let replyEnd = reply?.usage.at ?? .distantPast
        let starts = sends.filter { $0.turn == turn && $0.at > replyEnd }
        if let next = starts.first(where: { $0.at > visibleOutputAt }) {
            return (.preparing, elapsed(since: next.at, now: now))
        }
        if starts.isEmpty, let reply {
            if (resumedWorkAt ?? .distantPast) > replyEnd || visibleOutputAt > replyEnd {
                return (.generating, .waiting)
            }
            return (.preparing, .settled(reply.speed))
        }
        guard starts.count == 1 else { return (.generating, .waiting) }
        let start = starts[0].at
        let matching = samples.filter { $0.at >= start }
        guard let first = matching.first, let last = matching.last,
              now.timeIntervalSince(last.at) < 5, last.at > start else { return (.generating, .waiting) }

        // In a newly discovered chat the observer can arrive during model
        // preparation. A complete first visible item still gives a usable count.
        if observedSince > start {
            guard !lostPrefix, let itemStart = first.itemStartedAt,
                  itemStart >= observedSince.addingTimeInterval(-0.15), itemStart >= start,
                  matching.allSatisfy({ $0.itemStartedAt != nil }) else { return (.generating, .waiting) }
            if let savedAssistantAt, savedAssistantAt >= start, savedAssistantAt < itemStart {
                return (.generating, .waiting)
            }
        }
        let elapsed = last.at.timeIntervalSince(start)
        let characters = matching.reduce(0.0) { $0 + Double($1.characters) }
        return (.generating, .live(characters / 4 / elapsed))
    }

    private func elapsed(since start: Date, now: Date) -> ConversationRow.Readout {
        .elapsed(DisplayFormat.seconds(since: start, now: now))
    }
}

func projectConversation(_ chat: ChatMetadata, history: History, sends: [SendMarker]?, live: LiveTurn?,
                         terminalEvent: TurnEnd?, canShowLive: Bool, connected: Bool,
                         confirmingDisconnect: Bool = false, now: Date) -> (row: ConversationRow?, live: LiveTurn?) {
    let end = [history.lastEnd, terminalEvent].compactMap { $0 }.max { $0.at < $1.at }
    var live = live
    if let at = live?.statusObservedAt {
        // A status can arrive before the rollout reaches the turn it describes.
        if let start = history.lastStart, start.at <= at,
           history.end(of: start.id).map({ $0.at >= at }) ?? true,
           live?.id == nil || live?.id == start.id
            || live?.id.flatMap({ history.end(of: $0)?.at }).map({ $0 < at }) == true {
            live?.id = start.id
        }
    } else if let observed = live, observed.id == nil, let open = history.openTurn,
       open.at <= observed.began, end?.id != open.id {
        live?.id = open.id
    }
    let ended = live?.id.map { id in
        if let at = live?.statusObservedAt {
            return history.end(of: id).map { $0.at >= at } ?? false
        }
        return history.end(of: id) != nil || terminalEvent?.id == id
    } ?? false
    let turnID = live?.statusObservedAt == nil ? live?.id : nil
    let metrics = ReplyMetrics(usage: Array(history.usage.values), sends: sends ?? [])
    func makeRow(phase: TurnPhase, active: Bool, at date: Date,
                 readout: ConversationRow.Readout) -> ConversationRow {
        ConversationRow(id: chat.id, title: chat.title, client: chat.client, phase: phase,
                        active: active, orderDate: date, readout: readout,
                        average: metrics.average, cacheHit: metrics.cacheHit, context: history.context)
    }

    if var live, canShowLive, !ended {
        if let last = metrics.replies.last(where: { $0.usage.turn == turnID })?.usage.at,
           now.timeIntervalSince(last) > 0.1 {
            live.discardSettledSamples(before: last)
        }
        let display: (phase: TurnPhase, readout: ConversationRow.Readout) = if confirmingDisconnect {
            (live.lastNormalPhase, .hidden)
        } else if connected {
            live.display(turn: turnID, sends: sends, metrics: metrics, savedAssistantAt: history.savedAssistantAt, now: now)
        } else {
            (.unavailable, .hidden)
        }
        if !display.phase.isConnectionWarning { live.lastNormalPhase = display.phase }
        let start = history.openTurn.flatMap { $0.id == live.id ? $0.at : nil }
            ?? live.statusObservedAt ?? live.began
        return (makeRow(phase: display.phase, active: true, at: start,
                        readout: display.readout), live)
    }

    let recent = end.map { makeRow(phase: $0.phase, active: false, at: $0.at, readout: .settled(metrics.lastRate)) }
    return (recent, nil)
}

struct MonitorSnapshot {
    let rows: [ConversationRow]
    let connections: [CodexClient: ConnectionInfo]
    let historyUnavailable: Bool
}

final class CodexMonitor {
    private static let desktopLog = Logger(subsystem: "local.codex-tps.app", category: "desktop-connection")
    private let queue = DispatchQueue(label: "local.codex-tps.monitor", qos: .utility)
    private let records: CodexRecords
    private let cli: CLIStream
    private let desktop = DesktopReceiver()
    private var desktopApplication: NSRunningApplication?
    private var desktopsBeforeLease = Set<RelayProcess>()
    private var desktopRelaySessions = Set<UUID>()
    private var timer: DispatchSourceTimer?
    private var lastRelayPacket: RelayPacket?
    private var seen: [CodexClient: Date] = [:]
    private var connections: [CodexClient: ConnectionInfo] = [:]
    private var desktopConnection = DesktopConnectionState()
    private var cliConnection = ConnectionRunState()
    private var turns: [CodexClient: [String: LiveTurn]] = [:]
    private var terminalEvents: [String: TurnEnd] = [:]

    var onSnapshot: ((MonitorSnapshot) -> Void)?

    init(paths: CodexPaths = .local) {
        records = CodexRecords(paths: paths)
        cli = CLIStream(location: paths.sharedSocket, queue: queue)
        cli.onEvent = { [weak self] event in self?.ingest(event, from: .cli) }
        desktop.onRegistration = { [weak self] process, session in
            self?.adoptDesktop(process, session: session) == true
        }
        desktop.onPacket = { [weak self] packet in self?.ingestDesktop(packet) }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, timer == nil else { return }
            let clock = DispatchSource.makeTimerSource(queue: queue)
            clock.schedule(deadline: .now(), repeating: .milliseconds(450), leeway: .milliseconds(50))
            clock.setEventHandler { [weak self] in self?.refresh() }
            timer = clock
            clock.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            cli.retry()
            closeDesktopEndpoint()
        }
    }

    func beginDesktopSession() throws -> String {
        try queue.sync {
            closeDesktopEndpoint()
            let endpoint = try desktop.start(on: queue)
            desktopsBeforeLease = Set(DesktopTarget.runningApplications.compactMap {
                RelayProcess($0.processIdentifier)
            })
            return endpoint
        }
    }

    func pauseDesktop(_ paused: Bool) {
        queue.sync {
            desktop.setObservation(!paused)
            resetDesktopProgress()
        }
    }

    func endDesktopSession() {
        queue.sync { closeDesktopEndpoint() }
    }

    func retry(_ client: CodexClient) {
        queue.async { [weak self] in
            guard let self, timer != nil else { return }
            if client == .cli { cli.retry() }
            refresh()
        }
    }

    private func resetDesktopProgress() {
        seen[.desktop] = nil
        turns[.desktop] = nil
        lastRelayPacket = nil
    }

    private func closeDesktopEndpoint() {
        desktop.stop()
        desktopsBeforeLease.removeAll()
        desktopApplication = nil
        desktopRelaySessions.removeAll()
        resetDesktopProgress()
    }

    private func observeDesktopLaunch() {
        if desktopApplication?.isTerminated == true {
            desktopApplication = nil
            desktopRelaySessions.removeAll()
            resetDesktopProgress()
        }
        let state: DesktopConnectionState.Launch
        if !desktop.isListening {
            state = .setup
        } else if !desktop.observing {
            state = .paused
        } else if let desktopApplication {
            state = .running(desktopApplication.launchDate ?? .distantPast)
        } else if desktopsBeforeLease.contains(where: \.isRunning) {
            state = .restartRequired
        } else {
            state = .pending
        }
        desktopConnection.observe(state)
    }

    private func adoptDesktop(_ process: RelayProcess, session: UUID) -> Bool {
        guard let app = RelayProcess.desktopAncestor(of: process.pid) else { return false }
        if desktopApplication?.processIdentifier != app.processIdentifier || desktopApplication?.isTerminated == true {
            if let current = desktopApplication, !current.isTerminated,
               let candidateLaunch = app.launchDate, let currentLaunch = current.launchDate,
               candidateLaunch < currentLaunch { return false }
            desktopApplication = app
            desktopRelaySessions.removeAll()
            resetDesktopProgress()
        }
        desktopRelaySessions.insert(session)
        return true
    }

    private func ingestDesktop(_ packet: RelayPacket) {
        guard desktop.observing, desktopRelaySessions.contains(packet.session) else { return }
        if let previous = lastRelayPacket, previous.session != packet.session {
            loseDesktopCoverage()
        }
        if let previous = lastRelayPacket, previous.session == packet.session {
            guard packet.sequence > previous.sequence else { return }
            if let gap = packet.gap(after: previous) {
                let causes = gap.report?.losses.map(\.summary).joined(separator: ", ") ?? "unreported"
                Self.desktopLog.info("Desktop relay notification gap. Missing: \(gap.missing, privacy: .public). Visible output continuous: \(gap.continuousOutput, privacy: .public). Causes complete: \(gap.fullyReported, privacy: .public). Causes: \(causes, privacy: .public)")
                loseDesktopCoverage(gap: gap)
            }
        }
        lastRelayPacket = packet
        seen[.desktop] = Date()
        if packet.signal.kind != .heartbeat { ingest(packet.signal, from: .desktop) }
    }

    private func loseDesktopCoverage(preservingOutput: Bool = false, gap: RelayGap? = nil) {
        guard var items = turns[.desktop] else { return }
        let now = Date()
        for id in items.keys {
            let impact = gap?.impact(on: id) ?? (preservingOutput ? .activity : .unknown)
            items[id]?.interruptCoverage(at: now, impact: impact)
        }
        turns[.desktop] = items
    }

    private func ingest(_ signal: CodexSignal, from client: CodexClient) {
        guard !signal.thread.isEmpty else { return }
        let now = Date()
        if client == .cli, signal.kind != .lost { seen[.cli] = now }
        let thread = signal.thread
        var items = turns[client, default: [:]]
        if signal.fromThreadRead == true, items[thread]?.confirmed == true { return }
        switch signal.kind {
        case .heartbeat:
            return
        case .idle:
            items[thread] = nil
        case .lost:
            items[thread]?.interruptCoverage(at: now)
        case .turnEnded:
            if let id = signal.turn ?? items[thread]?.id {
                terminalEvents[thread] = TurnEnd(id: id, at: signal.at, phase: signal.phase ?? .completed)
                if items[thread]?.statusObservedAt == nil,
                   items[thread]?.id == id || items[thread]?.id == nil { items[thread] = nil }
            }
        default:
            if let ended = terminalEvents[thread], let id = signal.turn, id == ended.id { return }
            var turn = items[thread] ?? LiveTurn(id: signal.turn, began: signal.at, observedSince: now)
            if let id = signal.turn, let recorded = turn.id, id != recorded {
                turn = LiveTurn(id: id, began: signal.at, observedSince: now)
            }
            turn.apply(signal, now: now, trackStatusIdentity: client == .cli)
            items[thread] = turn
        }
        turns[client] = items
    }

    private func refresh() {
        observeDesktopLaunch()
        let now = Date()
        let uptime = DispatchTime.now()
        let desktopConnected = desktopConnection.launchedAt != nil && desktop.observing
            && seen[.desktop].map { now.timeIntervalSince($0) < 5 } == true
        let known = Set(turns.values.flatMap { $0.keys }).union(cli.loadedThreads)
        records.update(prioritize: known)
        let desktopAvailable = desktopConnected && records.indexAvailable
        let desktopLink = desktopConnection.status(available: desktopAvailable, now: now, uptime: uptime)
        let confirmingDesktopDisconnect = !desktopAvailable && desktopLink == .connected
        if !desktopConnected, !confirmingDesktopDisconnect {
            loseDesktopCoverage(preservingOutput: lastRelayPacket != nil)
        }
        cli.poll(known: Set(records.chats.values.filter { $0.client == .cli }.map(\.id)))
        if cli.connected { seen[.cli] = now }
        let cliRunning = CLIProcess.isRunning()

        var unconfirmed = Set<CodexClient>()
        var rows: [ConversationRow] = []
        for chat in records.chats.values {
            let history = records.history(for: chat.id)
            let sends = records.sends(for: chat.id)
            let live = turns[chat.client]?[chat.id]
            let isDesktop = chat.client == .desktop
            let connected = isDesktop ? desktopConnected && desktopLink != .unavailable : cli.connected
            let canShowLive = isDesktop ? desktopConnected || desktopConnection.connectedDuringRun
                : cliRunning != false || (connected && live?.confirmed == true)
            let presentation = projectConversation(chat, history: history, sends: sends, live: live,
                                                   terminalEvent: terminalEvents[chat.id], canShowLive: canShowLive,
                                                   connected: connected,
                                                   confirmingDisconnect: isDesktop && confirmingDesktopDisconnect, now: now)
            if live != nil { turns[chat.client]?[chat.id] = presentation.live }
            records.watchTurn(presentation.live?.id, in: chat.id)
            if presentation.live?.confirmed == false { unconfirmed.insert(chat.client) }
            if let row = presentation.row { rows.append(row) }
        }
        rows.sort { $0.id < $1.id }
        let desktopStatus: ConnectionStatus = if desktopAvailable, unconfirmed.contains(.desktop) {
            .unconfirmed
        } else {
            desktopLink
        }
        if connections[.desktop]?.status != desktopStatus {
            Self.desktopLog.notice("Codex Desktop: \(desktopStatus.title, privacy: .public)")
        }
        let cliStatus = cliConnection.status(running: cliRunning, available: cli.connected && records.indexAvailable,
                                             unconfirmed: unconfirmed.contains(.cli))
        let statuses: [CodexClient: ConnectionStatus] = [.desktop: desktopStatus, .cli: cliStatus]
        for (client, status) in statuses {
            let warningStartedAt = client == .desktop && status == .unavailable ? desktopConnection.lossDetectedAt : nil
            connections[client, default: .init(status: .checking)]
                .update(status, lastUpdate: status == .unavailable ? seen[client] : nil,
                        now: now, warningStartedAt: warningStartedAt)
        }
        onSnapshot?(MonitorSnapshot(rows: rows, connections: connections, historyUnavailable: records.indexReadFailed))
    }
}
