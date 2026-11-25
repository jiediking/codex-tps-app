import AppKit
import SwiftUI

private let whiteText = Color(red: 0.94, green: 0.97, blue: 0.99)
private let warningText = Color(red: 1.0, green: 0.62, blue: 0.51)
private let turquoise = Color(red: 0.42, green: 0.79, blue: 0.88)
private let ruleColor = Color(red: 0.60, green: 0.83, blue: 0.89).opacity(0.27)

private struct HorizontalRule: View {
    var scale: CGFloat = 1
    var color = ruleColor

    var body: some View {
        Rectangle().fill(color).frame(height: scale)
            .accessibilityHidden(true)
    }
}

private struct WarningLabel: View {
    let title: String
    var since: Date? = nil
    var wraps = false
    var scale: CGFloat = 1
    var color = warningText

    var body: some View {
        HStack(spacing: 5 * scale) {
            Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
            if let since {
                TimelineView(.periodic(from: since, by: 1)) { tick in
                    let seconds = DisplayFormat.seconds(since: since, now: tick.date)
                    Text("\(title) · \(DisplayFormat.elapsed(seconds))").monospacedDigit()
                }
            } else {
                Text(title)
            }
        }
        .lineLimit(wraps ? nil : 1)
        .foregroundStyle(color)
    }
}

private struct CardMouseArea: NSViewRepresentable {
    var resize: ((NSEvent) -> Void)? = nil

    func makeNSView(context: Context) -> MouseView { MouseView() }

    func updateNSView(_ view: MouseView, context: Context) { view.resize = resize }

    final class MouseView: NSView {
        var resize: ((NSEvent) -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if let resize {
                resize(event)
            } else if let window, window.isMovable {
                window.performDrag(with: event)
            }
        }

        override func mouseDragged(with event: NSEvent) { resize?(event) }
        override func mouseUp(with event: NSEvent) { resize?(event) }
    }
}

struct DesktopCard: View {
    private static let headerHeight: CGFloat = 28
    private static let spacing: CGFloat = 12
    private static let topPadding: CGFloat = 17
    private static let minimumBottomPadding: CGFloat = 24
    private static let headerAndSpacing = headerHeight + 2 * spacing + 1 + topPadding
    private static let minimumContentHeight: CGFloat = 22
    static let minimumFittingHeight = headerAndSpacing + minimumBottomPadding + minimumContentHeight

    let state: AppState
    let width: CGFloat
    var scale: CGFloat = 1
    var resize: ((NSEvent) -> Void)? = nil

    private var palette: CardPalette { state.cardTheme.palette }

    var body: some View {
        let selection = CardSelection(state.rows)
        let expanded = state.isExpanded && selection.firstHiddenActive != nil
        let extraHeight = max(0, state.maximumCardHeight / scale - Self.minimumFittingHeight)
        let bottomPadding = min(state.cardTheme.bottomPadding, Self.minimumBottomPadding + extraHeight)
        VStack(alignment: .leading, spacing: Self.spacing * scale) {
            HStack(spacing: 8 * scale) {
                HStack {
                    Text("Codex")
                        .font(.system(size: 23 * scale, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                }
                .overlay {
                    if !state.isPinned { CardMouseArea().accessibilityHidden(true) }
                }
                activeCount(selection, expanded: expanded)
                Button {
                    state.isPinned.toggle()
                } label: {
                    Image(systemName: state.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 15 * scale, weight: .medium))
                        .foregroundStyle(state.isPinned ? palette.pin : palette.ink)
                        .frame(width: Self.headerHeight * scale, height: Self.headerHeight * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(state.isPinned ? "Unpin Card" : "Keep on top and lock position")
                .accessibilityLabel(state.isPinned ? "Unpin Card" : "Pin Card")
                .accessibilityValue(state.isPinned ? "On" : "Off")
            }
            .frame(height: Self.headerHeight * scale)
            HorizontalRule(scale: scale, color: palette.divider)
            cardContent(selection, expanded: expanded, bottomPadding: bottomPadding)
        }
        .foregroundStyle(palette.ink)
        .padding(.horizontal, 22 * scale)
        .padding(.top, Self.topPadding * scale)
        .padding(.bottom, bottomPadding * scale)
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(CardSurface(theme: state.cardTheme, scale: scale, bottomPadding: bottomPadding,
                              animate: state.shouldAnimateCard))
        .overlay(alignment: .bottomTrailing) {
            if let resize {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11 * scale, weight: .medium))
                    .foregroundStyle(palette.detail)
                    .frame(width: 24 * scale, height: 24 * scale)
                    .overlay { CardMouseArea(resize: resize) }
                    .help("Resize Card")
                    .accessibilityLabel("Resize Card")
                    .padding(4 * scale)
            }
        }
    }

    @ViewBuilder
    private func activeCount(_ selection: CardSelection, expanded: Bool) -> some View {
        let count = Text("\(selection.active.count) active")
            .font(.system(size: 12.5 * scale, weight: .medium))
            .monospacedDigit()
            .fixedSize()
        if selection.firstHiddenActive != nil {
            Button {
                state.isExpanded.toggle()
            } label: {
                HStack(spacing: 5 * scale) {
                    count
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9 * scale, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .frame(height: Self.headerHeight * scale)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Show first three conversations" : "Show all active conversations")
            .accessibilityLabel("\(selection.active.count) active conversations")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        } else {
            count.foregroundStyle(palette.detail)
        }
    }

    @ViewBuilder
    private func cardContent(_ selection: CardSelection, expanded: Bool, bottomPadding: CGFloat) -> some View {
        let limit = max(0, state.maximumCardHeight - (Self.headerAndSpacing + bottomPadding) * scale)
        if selection.collapsed.isEmpty {
            fittedContent(height: limit) {
                Group {
                    if let warning = emptyWarning {
                        WarningLabel(title: warning.status.title, since: warning.warningSince,
                                     scale: scale, color: palette.warning)
                    } else {
                        Text(emptyText).foregroundStyle(palette.detail)
                    }
                }
                .font(.system(size: 13 * scale))
                .padding(.vertical, 6 * scale)
            }
        } else {
            let visible = expanded ? selection.active : selection.collapsed
            let target = expanded ? selection.firstHiddenActive?.id : visible.first?.id
            fittedContent(height: limit, target: target, expanded: expanded) {
                rows(visible)
            }
        }
    }

    private func fittedContent<Content: View>(height: CGFloat, target: String? = nil, expanded: Bool = false,
                                              @ViewBuilder content: () -> Content) -> some View {
        let content = content()
        return ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
            ScrollViewReader { scroll in
                ScrollView {
                    content
                }
                .task(id: expanded) {
                    guard let target else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scroll.scrollTo(target, anchor: .top)
                }
            }
            .frame(height: height)
        }
        .frame(maxHeight: height)
    }

    private var emptyText: String {
        if state.historyUnavailable { return "History unavailable" }
        if state.connections.values.allSatisfy({ $0.status == .checking }) { return "Connecting…" }
        return "No conversations yet"
    }

    private var emptyWarning: ConnectionInfo? {
        let connections = CodexClient.allCases.compactMap { state.connections[$0] }
        guard !connections.contains(where: { $0.status == .connected }) else { return nil }
        return connections.first { $0.status == .unconfirmed } ?? connections.first { $0.status == .unavailable }
    }

    private func rows(_ items: [ConversationRow]) -> some View {
        VStack(spacing: 11 * scale) {
            ForEach(items) { item in
                if item.id != items.first?.id { HorizontalRule(scale: scale, color: palette.divider) }
                CardConversation(row: item, metrics: Metric.allCases.filter(state.enabledMetrics.contains),
                                 connection: state.connections[item.client], palette: palette, scale: scale)
                    .id(item.id)
            }
        }
    }
}

private struct CardConversation: View {
    let row: ConversationRow
    let metrics: [Metric]
    let connection: ConnectionInfo?
    let palette: CardPalette
    let scale: CGFloat

    var body: some View {
        let ink = row.active ? palette.activeInk : palette.recentInk
        let detail = row.active ? palette.activeDetail : palette.recentDetail
        VStack(alignment: .leading, spacing: 6 * scale) {
            HStack(alignment: .top, spacing: 11 * scale) {
                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text(row.title)
                        .font(.system(size: 16 * scale, weight: .semibold))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(row.title)
                        .accessibilityLabel(row.title)
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Group {
                            if row.phase.isConnectionWarning {
                                WarningLabel(title: row.statusText, wraps: true, scale: scale, color: palette.warning)
                            } else {
                                HStack(spacing: 6 * scale) {
                                    if row.active {
                                        Circle().fill(palette.activeDot).frame(width: 6 * scale, height: 6 * scale)
                                            .accessibilityHidden(true)
                                    }
                                    Text(row.statusText)
                                }
                                .foregroundStyle(detail)
                            }
                        }
                        .font(.system(size: 11.5 * scale, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2 * scale) {
                    if row.phase == .unavailable, connection?.status == .unavailable,
                       let since = connection?.warningSince {
                        TimelineView(.periodic(from: since, by: 1)) { tick in
                            let seconds = DisplayFormat.seconds(since: since, now: tick.date)
                            readoutText(DisplayFormat.elapsed(seconds))
                        }
                    } else if let text = row.readout.text {
                        readoutText(text)
                    }
                    if case .settled = row.readout {
                        Text("Last reply").font(.system(size: 11.5 * scale))
                            .foregroundStyle(detail)
                    }
                }
                .foregroundStyle(row.phase.isConnectionWarning ? palette.warning : ink)
            }
            if !metrics.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8 * scale) {
                        ForEach(metrics) { metric in
                            if metric != metrics.first { Spacer(minLength: 0) }
                            Text(row.value(for: metric)).fixedSize()
                        }
                        if metrics.count == 1 { Spacer(minLength: 0) }
                    }
                    VStack(alignment: .leading, spacing: 3 * scale) {
                        ForEach(metrics) { metric in Text(row.value(for: metric)) }
                    }
                }
                .font(.system(size: 11.5 * scale))
                .monospacedDigit()
                .foregroundStyle(detail)
            }
        }
        .background {
            if row.active, let wash = palette.activeWash {
                RoundedRectangle(cornerRadius: 11 * scale)
                    .fill(wash)
                    .padding(.horizontal, -9 * scale)
                    .padding(.vertical, -7 * scale)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func readoutText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: (row.readout == .waiting ? 11.5 : 16) * scale, weight: .semibold))
            .monospacedDigit()
            .fixedSize()
    }
}

private struct MenuActionStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        configuration.label
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(selected ? turquoise.opacity(0.24) : .white.opacity(configuration.isPressed ? 0.19 : 0.085),
                        in: shape)
            .overlay { shape.strokeBorder(ruleColor.opacity(0.65)).allowsHitTesting(false) }
    }
}

struct MenuPopover: View {
    let state: AppState
    let retry: (CodexClient) -> Void
    let prepareDesktop: () -> Void
    let toggleDesktopPause: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Button {
                    state.isCardVisible.toggle()
                } label: {
                    Label(state.isCardVisible ? "Hide Card" : "Show Card",
                          systemImage: state.isCardVisible ? "eye.slash" : "eye")
                }
                .buttonStyle(MenuActionStyle())
                Button {
                    state.isPinned.toggle()
                } label: {
                    Label(state.isPinned ? "Unpin Card" : "Pin Card", systemImage: state.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(MenuActionStyle(selected: state.isPinned))
                .help(state.isPinned ? "Unpin Card" : "Keep on top and lock position")
                .accessibilityValue(state.isPinned ? "On" : "Off")
            }
            .font(.system(size: 12.5, weight: .medium))

            VStack(spacing: 7) {
                ForEach(Metric.allCases) { metric in
                    HStack {
                        Text(metric.rawValue)
                            .accessibilityHidden(true)
                        Spacer()
                        Toggle(metric.rawValue, isOn: Binding(
                            get: { state.enabledMetrics.contains(metric) },
                            set: { state.setMetric(metric, enabled: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .frame(minHeight: 23)
                }
            }
            .padding(.horizontal, 4)
            .tint(turquoise.opacity(0.85))

            cardStyles
            HorizontalRule()
            HStack {
                Button {
                    state.connectionsOpen.toggle()
                    if !state.connectionsOpen { state.desktopDetailsOpen = false }
                } label: {
                    HStack(spacing: 7) {
                        Text("Connections")
                        Image(systemName: state.connectionsOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .accessibilityValue(state.connectionsOpen ? "Expanded" : "Collapsed")
                Spacer()
                Button(state.isQuitting ? "Quitting…" : "Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
                    .disabled(state.isQuitting)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 4)

            if state.connectionsOpen {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(CodexClient.allCases) { client in
                        connection(client, info: state.connections[client] ?? .init(status: .checking))
                    }
                    if let message = state.connectionMessage {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(whiteText.opacity(0.73))
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(whiteText)
        .padding(13)
        .frame(width: 315)
        .fixedSize(horizontal: true, vertical: true)
        .background(Color(red: 0.04, green: 0.17, blue: 0.20).opacity(0.91))
        .preferredColorScheme(.dark)
    }

    private var cardStyles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                state.cardStylesOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("Card Style").fontWeight(.medium)
                    Spacer()
                    Text(state.cardTheme.name).foregroundStyle(whiteText.opacity(0.78))
                    Image(systemName: state.cardStylesOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Card Style")
            .accessibilityValue("\(state.cardTheme.name), \(state.cardStylesOpen ? "Expanded" : "Collapsed")")

            if state.cardStylesOpen {
                ForEach(CardTheme.builtIn) { theme in
                    let selected = theme.id == state.cardTheme.id
                    Button {
                        state.setCardTheme(theme)
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(theme.swatch)
                                .overlay { Circle().strokeBorder(whiteText.opacity(0.28), lineWidth: 0.5) }
                                .frame(width: 11, height: 11)
                                .accessibilityHidden(true)
                            Text(theme.name)
                            Spacer()
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(turquoise)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: 24)
                        .padding(.leading, 8)
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private func connection(_ client: CodexClient, info: ConnectionInfo) -> some View {
        let hasDetails = client == .desktop && (info.status == .connected || info.status == .paused || info.status == .pending
            || info.status == .restartRequired || info.status.isWarning)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(client.label)
                    .font(.system(size: 12))
                Spacer(minLength: 8)
                if client == .desktop && state.desktopBusy {
                    Text("Working…").foregroundStyle(whiteText.opacity(0.78))
                } else if client == .desktop && info.status == .setup {
                    Button("Retry Connection", action: prepareDesktop)
                        .foregroundStyle(turquoise)
                        .help("Prepare the live connection for the next Codex launch")
                } else if hasDetails {
                    Button {
                        state.desktopDetailsOpen.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            connectionStatus(info)
                            Image(systemName: state.desktopDetailsOpen ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(whiteText.opacity(0.78))
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Codex Desktop connection options")
                    .accessibilityValue(state.desktopDetailsOpen ? "Expanded" : "Collapsed")
                } else if info.status == .setup {
                    Button(info.status.title) { retry(client) }
                        .foregroundStyle(turquoise)
                        .buttonStyle(.plain)
                } else {
                    connectionStatus(info)
                }
            }
            if info.status.isWarning {
                HStack {
                    if let date = info.lastUpdate {
                        TimelineView(.periodic(from: date, by: 60)) { _ in
                            Text("Last update \(DisplayFormat.relative(date))")
                        }
                    }
                    Spacer()
                    Button("Retry") { retry(client) }
                        .foregroundStyle(turquoise)
                        .buttonStyle(.plain)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(whiteText.opacity(0.7))
            }
            if hasDetails && state.desktopDetailsOpen && !state.desktopBusy {
                VStack(alignment: .leading, spacing: 5) {
                    if info.status == .paused {
                        Text("Live updates are paused for this session.")
                        Button("Resume Live Updates", action: toggleDesktopPause)
                            .foregroundStyle(turquoise)
                    } else {
                        Button("Pause Live Updates", action: toggleDesktopPause)
                            .foregroundStyle(turquoise)
                    }
                }
                .foregroundStyle(whiteText.opacity(0.73))
                .padding(.top, 4)
            }
        }
        .font(.system(size: 11.5))
    }

    @ViewBuilder
    private func connectionStatus(_ info: ConnectionInfo) -> some View {
        if info.status.isWarning {
            WarningLabel(title: info.status.title, since: info.warningSince)
        } else {
            Text(info.status.title)
                .foregroundStyle(info.status == .setup ? turquoise : whiteText.opacity(0.78))
                .lineLimit(1)
        }
    }
}
