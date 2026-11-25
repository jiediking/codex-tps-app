import AppKit
import Darwin

@MainActor
final class CodexTPSApp: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var card: CardWindow?
    private var menu: MenuWindow?
    private var monitor: CodexMonitor?
    private var desktop: DesktopSession?
    private var wakeObserver: NSObjectProtocol?
    private var quitQueued = false
    private var quitApproved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let state = AppState()
        self.state = state
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let useFixture = args.contains("--demo")
        if useFixture { state.showFixture() }
        #else
        let useFixture = false
        #endif
        if !useFixture {
            let paths = CodexPaths.local
            let monitor = CodexMonitor(paths: paths)
            self.monitor = monitor
            if let executable = Bundle.main.executableURL {
                desktop = DesktopSession(monitor: monitor, executable: executable)
            }
            monitor.onSnapshot = { [weak state] snapshot in
                DispatchQueue.main.async {
                    guard let state else { return }
                    if state.rows != snapshot.rows { state.rows = snapshot.rows }
                    if state.connections != snapshot.connections { state.connections = snapshot.connections }
                    if state.historyUnavailable != snapshot.historyUnavailable {
                        state.historyUnavailable = snapshot.historyUnavailable
                    }
                }
            }
            monitor.start()
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.monitor?.retry(.cli)
                    self?.monitor?.retry(.desktop)
                }
            }
        }
        card = CardWindow(state: state)
        menu = MenuWindow(state: state, retry: { [weak monitor] source in monitor?.retry(source) },
                          prepareDesktop: { [weak self] in self?.prepareDesktop() },
                          toggleDesktopPause: { [weak self] in self?.toggleDesktopPause() })
        prepareDesktop()
        #if DEBUG
        if args.contains("--demo-menu") {
            DispatchQueue.main.async { [weak self] in
                self?.menu?.togglePopover()
                if args.contains("--demo-styles") { self?.state?.cardStylesOpen = true }
                if args.contains("--demo-connections") { self?.state?.connectionsOpen = true }
            }
        }
        #endif
    }

    private func prepareDesktop() {
        guard let desktop else { return }
        performDesktopAction { try await desktop.prepare() }
    }

    private func toggleDesktopPause() {
        guard let desktop, desktop.hasSession, state?.desktopBusy == false else { return }
        desktop.setPaused(!desktop.paused)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard state != nil, !quitApproved else { return .terminateNow }
        DispatchQueue.main.async { [weak self] in self?.requestQuit() }
        return .terminateCancel
    }

    private func requestQuit() {
        guard let state, !state.isQuitting else { return }
        if state.desktopBusy {
            quitQueued = true
            return
        }
        state.isQuitting = true
        performDesktopAction {
            defer { state.isQuitting = false }
            if let desktop = self.desktop {
                try await desktop.prepareToQuit()
                self.clearSavedPreferences()
            }
            self.quitApproved = true
            NSApplication.shared.terminate(nil)
        }
    }

    private func performDesktopAction(_ action: @escaping @MainActor () async throws -> Void) {
        guard let state, !state.desktopBusy else { return }
        state.desktopBusy = true
        state.connectionMessage = nil
        Task { @MainActor [self] in
            do { try await action() }
            catch {
                if let menu, !menu.isShown { menu.togglePopover() }
                state.connectionsOpen = true
                state.connectionMessage = error.localizedDescription
            }
            state.desktopBusy = false
            if quitQueued {
                quitQueued = false
                requestQuit()
            }
        }
    }

    private func clearSavedPreferences() {
        let defaults = UserDefaults.standard
        guard let domain = Bundle.main.bundleIdentifier,
              defaults.persistentDomain(forName: domain) != nil else { return }
        defaults.removePersistentDomain(forName: domain)
        _ = defaults.synchronize()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        monitor?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment
if arguments.first == "--desktop-launch-lease", arguments.count == 2,
   let executable = Bundle.main.executableURL {
    exit(DesktopLaunchLease.maintain(endpoint: arguments[1], executable: executable))
}
if let path = DesktopLaunchPath(launcher: CommandLine.arguments[0]) {
    exit(DesktopRelay.runLeased(arguments, path: path, environment: environment))
}
if !arguments.isEmpty, environment["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] == "Codex Desktop",
   let launcher = environment["CODEX_APP_RUNTIME_CLI_PATH"], let path = DesktopLaunchPath(launcher: launcher),
   RelayProcess.desktopAncestor(of: getpid()) != nil {
    exit(DesktopRelay.runLeased(arguments, path: path, environment: environment))
}
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = CodexTPSApp()
    application.setActivationPolicy(.accessory)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
