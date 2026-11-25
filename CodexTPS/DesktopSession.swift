import AppKit

struct DesktopTarget {
    static let bundleID = "com.openai.codex"

    static var runningApplications: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
    }

    let engine: URL

    init(application: URL) throws {
        let resources = application.appendingPathComponent("Contents/Resources")
        let runtimes = [
            "codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "codex-cli/bin/codex"
        ].map { resources.appendingPathComponent($0) }
        guard let engine = runtimes.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else { throw RelayError.engine }
        self.engine = engine
    }
}

@MainActor
final class DesktopSession {
    private let monitor: CodexMonitor
    private let executable: URL
    private var lease: DesktopLaunchLease?

    private(set) var paused = false
    var hasSession: Bool { lease != nil }

    init(monitor: CodexMonitor, executable: URL) {
        self.monitor = monitor
        self.executable = executable
    }

    func prepare() async throws {
        guard lease == nil else { return }
        let endpoint = try monitor.beginDesktopSession()
        do {
            lease = try await DesktopLaunchLease.start(endpoint: endpoint, executable: executable)
        } catch {
            monitor.endDesktopSession()
            throw error
        }
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        monitor.pauseDesktop(paused)
    }

    func prepareToQuit() async throws {
        monitor.endDesktopSession()
        if let lease {
            try await lease.stop()
            self.lease = nil
        }
    }
}
