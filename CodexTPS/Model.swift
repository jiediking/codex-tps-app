import Dispatch
import Foundation
import Observation

enum CodexClient: String, CaseIterable, Identifiable, Codable {
    case desktop = "Desktop"
    case cli = "CLI"

    var id: Self { self }
    var label: String { "Codex \(rawValue)" }

    init?(originator: String) {
        switch originator {
        case "Codex Desktop": self = .desktop
        case "codex-tui": self = .cli
        default: return nil
        }
    }
}

enum Metric: String, CaseIterable, Identifiable {
    case average = "Average Speed"
    case cache = "Cache Hit Rate"
    case context = "Context Window"

    var id: Self { self }
}

enum ConnectionStatus: Equatable {
    case checking, connected, notRunning, setup, pending, restartRequired, paused, unavailable, unconfirmed

    var isWarning: Bool { self == .unavailable || self == .unconfirmed }

    var title: String {
        switch self {
        case .checking: "Connecting…"
        case .connected: "Connected"
        case .notRunning: "Not running"
        case .setup: "Live Off"
        case .pending: "Waiting for Codex"
        case .restartRequired: "Restart Codex"
        case .paused: "Paused"
        case .unavailable: "Source unavailable"
        case .unconfirmed: "Activity unconfirmed"
        }
    }
}

struct ConnectionRunState {
    private(set) var connectedDuringRun = false

    mutating func status(running: Bool?, available: Bool, unconfirmed: Bool) -> ConnectionStatus {
        if running == false {
            connectedDuringRun = false
            return .notRunning
        }
        if available {
            connectedDuringRun = true
            return unconfirmed ? .unconfirmed : .connected
        }
        return running == true && connectedDuringRun ? .unavailable : .checking
    }
}

struct DesktopConnectionState {
    enum Launch: Equatable {
        case setup, pending, restartRequired, paused, running(Date)
    }

    private var launch: Launch = .setup
    private var connection = ConnectionRunState()
    private var loss: (detectedAt: Date, confirmAfter: DispatchTime)?

    var launchedAt: Date? {
        guard case .running(let date) = launch else { return nil }
        return date
    }

    var connectedDuringRun: Bool { connection.connectedDuringRun }
    var lossDetectedAt: Date? { loss?.detectedAt }

    @discardableResult
    mutating func observe(_ next: Launch) -> Bool {
        guard next != launch else { return false }
        launch = next
        connection = ConnectionRunState()
        loss = nil
        return true
    }

    mutating func status(available: Bool, now: Date, uptime: DispatchTime) -> ConnectionStatus {
        switch launch {
        case .setup: return .setup
        case .pending: return .pending
        case .restartRequired: return .restartRequired
        case .paused: return .paused
        case .running:
            let status = connection.status(running: true, available: available, unconfirmed: false)
            guard status == .unavailable else {
                loss = nil
                return status
            }
            // The relay may stop before macOS observes the Desktop process exit.
            let pending = loss ?? (detectedAt: now, confirmAfter: uptime + .seconds(2))
            loss = pending
            return uptime < pending.confirmAfter ? .connected : .unavailable
        }
    }
}

struct ConnectionInfo: Equatable {
    private(set) var status: ConnectionStatus
    private(set) var lastUpdate: Date? = nil
    private(set) var warningSince: Date? = nil

    mutating func update(_ status: ConnectionStatus, lastUpdate: Date?, now: Date, warningStartedAt: Date? = nil) {
        if self.status != status { warningSince = status.isWarning ? (warningStartedAt ?? now) : nil }
        self.status = status
        self.lastUpdate = lastUpdate
    }
}

enum TurnPhase: String, Codable {
    case preparing = "Preparing"
    case reading = "Reading"
    case thinking = "Thinking"
    case generating = "Generating"
    case runningTool = "Running tool"
    case awaitingApproval = "Awaiting approval"
    case awaitingInput = "Awaiting input"
    case unavailable = "Source unavailable"
    case unconfirmed = "Activity unconfirmed"
    case completed = "Completed"
    case interrupted = "Interrupted"
    case failed = "Failed"

    var title: String { self == .preparing ? "Working" : rawValue }
    var isConnectionWarning: Bool { self == .unavailable || self == .unconfirmed }
}

struct ContextUsage: Equatable {
    let used: Int?
    let capacity: Int?
}

struct ConversationRow: Identifiable, Equatable {
    enum Readout: Equatable {
        case elapsed(Int), waiting, hidden, live(Double), settled(Double?)

        var text: String? {
            switch self {
            case .elapsed(let seconds): DisplayFormat.elapsed(seconds)
            case .waiting: "Waiting for speed"
            case .hidden: nil
            case .live(let value): "≈ \(DisplayFormat.number(value)) tok/s"
            case .settled(let value): value.map { "\(DisplayFormat.number($0)) tok/s" } ?? "— tok/s"
            }
        }
    }

    let id: String
    let title: String
    let client: CodexClient
    let phase: TurnPhase
    let active: Bool
    let orderDate: Date
    let readout: Readout
    var average: Double? = nil
    var cacheHit: Double? = nil
    var context: ContextUsage? = nil

    var statusText: String {
        let base = "\(phase.title) · \(client.rawValue)"
        return active ? base : "\(base) · \(DisplayFormat.relative(orderDate))"
    }

    func value(for metric: Metric) -> String {
        switch metric {
        case .average:
            return "Avg " + (average.map { "\(DisplayFormat.number($0)) tok/s" } ?? "—")
        case .cache:
            return "Cache " + (cacheHit.map { "\(DisplayFormat.number($0 * 100, decimals: 0))%" } ?? "—")
        case .context:
            if let context, context.used != nil || context.capacity != nil {
                return "Context \(DisplayFormat.tokenCount(context.used)) / \(DisplayFormat.tokenCount(context.capacity))"
            }
            return "Context —"
        }
    }
}

enum DisplayFormat {
    static func number(_ value: Double, decimals: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(0...decimals)).grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX")))
    }

    static func tokenCount(_ value: Int?) -> String {
        guard let value else { return "—" }
        if value >= 1_000_000 { return "\(number(Double(value) / 1_000_000))m" }
        if value >= 1_000 { return "\(number(Double(value) / 1_000))k" }
        return String(value)
    }

    static func elapsed(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes == 0 { return "\(seconds)s" }
        let remainder = seconds % 60
        if minutes < 60 { return "\(minutes)m \(remainder)s" }
        return "\(minutes / 60)h \(minutes % 60)m \(remainder)s"
    }

    static func seconds(since start: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(start)))
    }

    static func relative(_ date: Date) -> String {
        let elapsed = seconds(since: date, now: .now)
        if elapsed < 60 { return "Just now" }
        if elapsed < 3_600 { return "\(elapsed / 60) min ago" }
        if elapsed < 86_400 { return "\(elapsed / 3_600) hr ago" }
        let days = elapsed / 86_400
        return "\(days) \(days == 1 ? "day" : "days") ago"
    }
}

struct CardSelection {
    static let collapsedLimit = 3

    let active: [ConversationRow]
    let recent: [ConversationRow]

    init(_ rows: [ConversationRow]) {
        func newest(_ a: ConversationRow, _ b: ConversationRow) -> Bool {
            a.orderDate == b.orderDate ? a.id < b.id : a.orderDate > b.orderDate
        }
        active = rows.filter(\.active).sorted(by: newest)
        recent = rows.filter { !$0.active }.sorted(by: newest)
    }

    var collapsed: [ConversationRow] {
        Array(active.prefix(Self.collapsedLimit))
            + Array(recent.prefix(max(0, min(2, Self.collapsedLimit - active.count))))
    }

    var firstHiddenActive: ConversationRow? { active.dropFirst(Self.collapsedLimit).first }
}

@MainActor
@Observable
final class AppState {
    var isCardVisible = true
    var isCardOnScreen = false
    var isPinned = false
    var isExpanded = false
    var cardStylesOpen = false
    var connectionsOpen = false
    var desktopDetailsOpen = false
    var connectionMessage: String?
    var desktopBusy = false
    var isQuitting = false
    var historyUnavailable = false
    var connections: [CodexClient: ConnectionInfo] = [
        .desktop: ConnectionInfo(status: .checking), .cli: ConnectionInfo(status: .checking)
    ]
    var rows: [ConversationRow] = [] {
        didSet {
            if isExpanded && CardSelection(rows).firstHiddenActive == nil { isExpanded = false }
        }
    }
    var maximumCardHeight: CGFloat = 500
    private(set) var enabledMetrics: Set<Metric>
    private(set) var cardTheme: CardTheme

    private let defaults: UserDefaults?

    var shouldAnimateCard: Bool { isCardVisible && isCardOnScreen }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        let hidden = Set(defaults?.stringArray(forKey: "HiddenMetrics") ?? [])
        enabledMetrics = Set(Metric.allCases.filter { !hidden.contains($0.rawValue) })
        cardTheme = CardTheme.restoring(defaults?.string(forKey: "CardTheme"))
    }

    func setMetric(_ metric: Metric, enabled: Bool) {
        if enabled { enabledMetrics.insert(metric) } else { enabledMetrics.remove(metric) }
        defaults?.set(Metric.allCases.filter { !enabledMetrics.contains($0) }.map(\.rawValue),
                     forKey: "HiddenMetrics")
    }

    func setCardTheme(_ theme: CardTheme) {
        guard cardTheme.id != theme.id else { return }
        cardTheme = theme
        defaults?.set(theme.id, forKey: "CardTheme")
    }

    func preparePopover() {
        cardStylesOpen = false
        connectionsOpen = connections[.desktop]?.status == .restartRequired
        desktopDetailsOpen = false
    }
}

#if DEBUG
extension AppState {
    func showFixture() {
        let now = Date()
        rows = [
            ConversationRow(id: "fixture-1", title: "Refactor auth flow", client: .desktop,
                            phase: .generating, active: true, orderDate: now, readout: .live(62),
                            average: 53.3, cacheHit: 0.92, context: .init(used: 42_000, capacity: 128_000)),
            ConversationRow(id: "fixture-2", title: "Add integration tests", client: .cli,
                            phase: .completed, active: false, orderDate: now.addingTimeInterval(-186),
                            readout: .settled(40), average: 46, cacheHit: 0.85,
                            context: .init(used: 27_000, capacity: 128_000)),
            ConversationRow(id: "fixture-3", title: "Fix export timeout", client: .desktop,
                            phase: .completed, active: false, orderDate: now.addingTimeInterval(-1_086),
                            readout: .settled(58), average: 50, cacheHit: 0.88,
                            context: .init(used: 24_000, capacity: 128_000))
        ]
        connections = [.desktop: .init(status: .connected), .cli: .init(status: .setup)]
    }
}
#endif
