import AppKit
import Observation
import SwiftUI

final class DesktopPanel: NSPanel {
    static let restingLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CardHostingView: NSHostingView<DesktopCard> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum CardPlacement {
    static let standardWidth: CGFloat = 360
    static let scaleRange: ClosedRange<CGFloat> = 0.9...1.5

    static func scale(_ requested: CGFloat) -> CGFloat {
        guard requested.isFinite, requested > 0 else { return 1 }
        return min(scaleRange.upperBound, max(scaleRange.lowerBound, requested))
    }

    static func clamped(_ origin: CGPoint, size: CGSize, within visible: CGRect) -> CGPoint {
        CGPoint(x: max(visible.minX, min(origin.x, visible.maxX - size.width)),
                y: max(visible.minY, min(origin.y, visible.maxY - size.height)))
    }

    static func pinnedArea(for frame: CGRect, within visible: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
        let origin = clamped(CGPoint(x: frame.minX, y: frame.maxY - size.height), size: size, within: visible)
        return CGRect(x: origin.x, y: visible.minY,
                      width: visible.maxX - origin.x, height: origin.y + size.height - visible.minY)
    }

    static func id(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

@MainActor
final class CardWindow: NSObject, NSWindowDelegate {
    let panel: DesktopPanel
    #if DEBUG
    private(set) var sizeMeasurements = 0
    #endif
    private let host: CardHostingView
    private let state: AppState
    private let defaults: UserDefaults?
    private var lastPlacement: (screenID: UInt32?, topLeft: CGPoint)?
    private var layoutFrame: CGRect?
    private var updatingFrame = false
    private var isSleeping = false
    private var needsPlacementRestore = true
    private var preferredScale: CGFloat
    private var effectiveScale: CGFloat = 1
    private var width = CardPlacement.standardWidth
    private var unpinnedHeightLimit: CGFloat?
    private var resizeStart: (pointerX: CGFloat, scale: CGFloat, width: CGFloat, screen: NSScreen)?

    init(state: AppState, defaults: UserDefaults? = nil) {
        self.state = state
        self.defaults = defaults
        if let saved = defaults?.dictionary(forKey: "CardPlacement"),
           let x = saved["x"] as? Double, let top = saved["top"] as? Double,
           x.isFinite, top.isFinite {
            lastPlacement = (saved["screen"] as? UInt32, CGPoint(x: x, y: top))
        }
        preferredScale = CardPlacement.scale(CGFloat(defaults?.double(forKey: "CardScale") ?? 0))
        panel = DesktopPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 130),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                             defer: false)
        host = CardHostingView(rootView: DesktopCard(state: state, width: 360))
        super.init()
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        panel.title = "Codex Card"
        panel.level = DesktopPanel.restingLevel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.stationary, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.isMovable = true
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        configureContent()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(prepareForSleep),
                              name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(restoreAfterWake),
                              name: NSWorkspace.didWakeNotification, object: nil)
        refresh()
        observeLayoutState()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func observeLayoutState() {
        withObservationTracking {
            _ = state.isPinned
            guard state.isCardVisible else { return }
            _ = state.isExpanded
            _ = state.rows
            _ = state.connections
            _ = state.historyUnavailable
            _ = state.enabledMetrics
            _ = state.cardTheme
        } onChange: { [weak self] in
            // Observation fires once before the write. Measure after the batch of writes.
            DispatchQueue.main.async {
                guard let self else { return }
                self.refresh()
                self.observeLayoutState()
            }
        }
    }

    func refresh() {
        guard !isSleeping else { return }
        if !state.isPinned && !panel.isMovable {
            preferredScale = effectiveScale
            unpinnedHeightLimit = state.maximumCardHeight
        }
        if state.isPinned { unpinnedHeightLimit = nil }
        panel.isMovable = !state.isPinned
        let level = state.isPinned ? NSWindow.Level.floating : DesktopPanel.restingLevel
        if panel.level != level { panel.level = level }
        guard state.isCardVisible else {
            resizeStart = nil
            if panel.isVisible { panel.orderOut(nil) }
            state.isCardOnScreen = false
            return
        }

        if needsPlacementRestore {
            restorePlacement()
        } else if let screen = resizeStart?.screen ?? panel.screen ?? NSScreen.screens.first {
            resize(on: screen)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
            updateCardOnScreen()
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateCardOnScreen()
    }

    private func updateCardOnScreen() {
        state.isCardOnScreen = panel.isVisible && panel.occlusionState.contains(.visible)
    }

    private func fittingScale(in area: CGSize) -> CGFloat {
        let fitting = min(area.width / CardPlacement.standardWidth, area.height / DesktopCard.minimumFittingHeight)
        return min(preferredScale, max(CardPlacement.scaleRange.lowerBound, fitting))
    }

    private func resize(on screen: NSScreen, restoring topLeft: CGPoint? = nil) {
        let visible = screen.visibleFrame
        let frame = panel.frame
        let fixed = state.isPinned && topLeft == nil
        let keepTop = fixed || (state.isExpanded && topLeft == nil)
        let area = keepTop ? CardPlacement.pinnedArea(for: frame, within: visible) : visible
        let heightLimit = min(area.height, unpinnedHeightLimit ?? area.height)
        let availableWidth = fixed ? area.width : visible.width
        let scale = fittingScale(in: CGSize(width: availableWidth, height: heightLimit))
        let width = min(CardPlacement.standardWidth * scale, availableWidth)
        if width != self.width || scale != effectiveScale {
            self.width = width
            effectiveScale = scale
            configureContent()
        }
        if state.maximumCardHeight != heightLimit { state.maximumCardHeight = heightLimit }
        #if DEBUG
        sizeMeasurements += 1
        #endif
        host.layoutSubtreeIfNeeded()
        let size = CGSize(width: width, height: min(heightLimit, max(80 * scale, ceil(host.fittingSize.height))))
        let corner = topLeft ?? CGPoint(x: frame.minX, y: frame.maxY)
        let origin = fixed
            ? CGPoint(x: area.minX, y: area.maxY - size.height)
            : CardPlacement.clamped(CGPoint(x: corner.x, y: corner.y - size.height), size: size, within: visible)
        let nextFrame = CGRect(origin: origin, size: size)
        if frame != nextFrame { setFrame(nextFrame) }
    }

    private func configureContent() {
        host.rootView = DesktopCard(state: state, width: width, scale: effectiveScale,
                                    resize: { [weak self] event in self?.resizeCard(event) })
    }

    private func resizeCard(_ event: NSEvent) {
        let pointerX = panel.convertPoint(toScreen: event.locationInWindow).x
        switch event.type {
        case .leftMouseDown:
            guard let screen = panel.screen ?? NSScreen.screens.first else { return }
            resizeStart = (pointerX, effectiveScale, width / effectiveScale, screen)
        case .leftMouseDragged, .leftMouseUp:
            guard let start = resizeStart else { return }
            if event.type == .leftMouseDragged { unpinnedHeightLimit = nil }
            preferredScale = CardPlacement.scale(start.scale + (pointerX - start.pointerX) / start.width)
            resize(on: start.screen)
            if event.type == .leftMouseUp {
                resizeStart = nil
                if state.isPinned { preferredScale = effectiveScale }
                defaults?.set(Double(preferredScale), forKey: "CardScale")
                savePlacement()
            }
        default:
            break
        }
    }

    private func restorePlacement() {
        let screens = NSScreen.screens
        let savedID = lastPlacement?.screenID
        let topLeft = lastPlacement?.topLeft
        let savedScreen = savedID.flatMap { id in screens.first { CardPlacement.id(for: $0) == id } }
        let screenAtCorner = topLeft.flatMap { corner in
            let insideCard = CGPoint(x: corner.x, y: corner.y - 1)
            return screens.first { $0.frame.contains(insideCard) }
        }
        guard let target = savedScreen ?? screenAtCorner ?? screens.first else { return }
        let visible = target.visibleFrame
        guard !visible.isEmpty else { return }
        defer {
            layoutFrame = panel.frame
            needsPlacementRestore = false
        }
        guard let topLeft else {
            resize(on: target, restoring: CGPoint(x: visible.minX + 24, y: visible.maxY - 24))
            return
        }
        let scale = fittingScale(in: visible.size)
        let size = CGSize(width: min(visible.width, CardPlacement.standardWidth * scale),
                          height: min(visible.height, DesktopCard.minimumFittingHeight * scale))
        let minimumFrame = CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        let area = CardPlacement.pinnedArea(for: minimumFrame, within: visible)
        unpinnedHeightLimit = area.height
        resize(on: target, restoring: CGPoint(x: area.minX, y: area.maxY))
    }

    private func setFrame(_ frame: CGRect) {
        updatingFrame = true
        panel.setFrame(frame, display: true)
        layoutFrame = panel.frame
        updatingFrame = false
    }

    func windowDidMove(_ notification: Notification) {
        guard state.isCardVisible, !isSleeping, !needsPlacementRestore, !updatingFrame,
              resizeStart == nil, panel.frame != layoutFrame else { return }
        layoutFrame = nil
        savePlacement()
        if unpinnedHeightLimit != nil || state.isExpanded {
            unpinnedHeightLimit = nil
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
    }

    private func savePlacement() {
        guard let screen = panel.screen, let id = CardPlacement.id(for: screen) else { return }
        let topLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        lastPlacement = (id, topLeft)
        defaults?.set(["screen": id, "x": Double(topLeft.x), "top": Double(topLeft.y)], forKey: "CardPlacement")
    }

    @objc private func prepareForSleep() {
        if lastPlacement == nil && panel.isVisible { savePlacement() }
        isSleeping = true
        resizeStart = nil
    }

    @objc private func restoreAfterWake() {
        isSleeping = false
        screensChanged()
    }

    @objc private func screensChanged() {
        resizeStart = nil
        unpinnedHeightLimit = nil
        needsPlacementRestore = true
        // Let AppKit finish moving windows for this display configuration before restoring the card.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.needsPlacementRestore else { return }
            self.refresh()
        }
    }
}

@MainActor
final class MenuWindow: NSObject, NSPopoverDelegate {
    #if DEBUG
    private(set) var sizeMeasurements = 0
    var contentSize: CGSize { popover.contentSize }
    #endif
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let host: NSHostingController<MenuPopover>
    private let state: AppState

    init(state: AppState, retry: @escaping (CodexClient) -> Void,
         prepareDesktop: @escaping () -> Void, toggleDesktopPause: @escaping () -> Void) {
        self.state = state
        host = NSHostingController(rootView: MenuPopover(
            state: state, retry: retry, prepareDesktop: prepareDesktop, toggleDesktopPause: toggleDesktopPause
        ))
        super.init()
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.behavior = .transient
        popover.delegate = self
        if let button = item.button {
            let icon = NSImage(named: "ConversationGauge")
            icon?.size = NSSize(width: 24, height: 24)
            icon?.isTemplate = true
            button.image = icon
            button.toolTip = "Codex TPS"
            button.setAccessibilityLabel("Codex TPS menu")
            button.target = self
            button.action = #selector(togglePopover)
        }
    }

    deinit { NSStatusBar.system.removeStatusItem(item) }

    var isShown: Bool { popover.isShown }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            showPopover(relativeTo: button)
        }
    }

    func showPopover(relativeTo anchor: NSView) {
        state.preparePopover()
        resizePopover()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        item.button?.highlight(true)
    }

    func popoverDidClose(_ notification: Notification) {
        item.button?.highlight(false)
    }

    private func resizePopover() {
        #if DEBUG
        sizeMeasurements += 1
        #endif
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        if size.width > 0, size.height > 0, size != popover.contentSize { popover.contentSize = size }
    }
}
