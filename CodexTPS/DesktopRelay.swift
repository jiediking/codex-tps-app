import AppKit
import CoreFoundation
import CryptoKit
import Darwin
import Foundation

enum RelayError: LocalizedError {
    case socket, receiverInUse, engine, conflictingSetup, launchSetting, restore, unsafeDesktopPath
    var errorDescription: String? {
        switch self {
        case .socket: "The local Desktop connection is unavailable."
        case .receiverInUse: "Another Codex TPS instance is handling the Desktop connection."
        case .engine: "The bundled Codex Desktop runtime was not found."
        case .conflictingSetup: "A different Desktop runtime is already configured."
        case .launchSetting: "The Desktop launch setting could not be updated."
        case .restore: "The temporary Desktop connection could not be cleaned up."
        case .unsafeDesktopPath: "The Desktop support path must be private and controlled by your account."
        }
    }
}

struct RelayLoss: Codable, Equatable {
    enum Reason: String, Codable {
        case listenerUnavailable, oversizedFrame, malformedFrame, malformedText, encodingFailed, sendFailed
    }

    struct Impact: OptionSet, Codable {
        let rawValue: UInt8
        static let activity = Self(rawValue: 1)
        static let output = Self(rawValue: 2)
        static let unknown: Self = [.activity, .output]
    }

    let reason: Reason
    let impact: Impact
    var event: String? = nil
    var thread: String? = nil
    var errorCode: Int32? = nil

    var summary: String {
        let scope = if impact.isEmpty {
            "none"
        } else if let thread {
            "thread/" + SHA256.hash(data: Data(thread.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        } else {
            "all"
        }
        let impactLabel = switch impact {
        case .activity: "activity"
        case .output: "output"
        case .unknown: "unknown"
        default: "none"
        }
        let error = errorCode.map { " code=\($0)" } ?? ""
        return "\(reason.rawValue) event=\(event ?? "unknown") impact=\(impactLabel) scope=\(scope)\(error)"
    }
}

struct RelayLossReport: Codable {
    private(set) var count: UInt64 = 0
    private(set) var losses: [RelayLoss] = []
    private(set) var overflowed = false

    mutating func record(_ loss: RelayLoss) {
        count += 1
        var loss = loss
        if let thread = loss.thread,
           thread.isEmpty || thread.utf8.count > 64 || !thread.utf8.allSatisfy({ (32...126).contains($0) }) {
            loss.thread = nil
        }
        guard !losses.contains(loss) else { return }
        // Keep the report small enough for a local message even after a long outage.
        guard losses.count < 4 else {
            overflowed = true
            return
        }
        losses.append(loss)
    }
}

struct RelayGap {
    let missing: UInt64
    let report: RelayLossReport?
    let continuousOutput: Bool

    var fullyReported: Bool {
        guard let report, report.count == missing, !report.overflowed, !report.losses.isEmpty else { return false }
        return continuousOutput == !report.losses.contains { $0.impact.contains(.output) }
    }

    func impact(on thread: String) -> RelayLoss.Impact {
        guard let report, fullyReported else { return continuousOutput ? .activity : .unknown }
        return report.losses.reduce(into: []) { impact, loss in
            if loss.thread == nil || loss.thread == thread { impact.formUnion(loss.impact) }
        }
    }
}

struct RelayPacket: Codable {
    let session: UUID
    let sequence: UInt64
    let outputSequence: UInt64
    let signal: CodexSignal
    var lossReport: RelayLossReport? = nil

    func hasContinuousOutput(after previous: Self) -> Bool {
        guard session == previous.session, outputSequence >= previous.outputSequence else {
            return false
        }
        return outputSequence - previous.outputSequence == (signal.kind == .text ? 1 : 0)
    }

    func gap(after previous: Self) -> RelayGap? {
        guard session == previous.session, sequence > previous.sequence,
              sequence - previous.sequence > 1 else { return nil }
        return RelayGap(missing: sequence - previous.sequence - 1, report: lossReport,
                        continuousOutput: hasContinuousOutput(after: previous))
    }
}

struct RelayProcess: Hashable {
    let pid: pid_t
    private let startedSeconds: UInt64
    private let startedMicroseconds: UInt64

    init?(_ pid: pid_t) {
        guard let info = Self.info(about: pid) else { return nil }
        self.pid = pid
        startedSeconds = info.pbi_start_tvsec
        startedMicroseconds = info.pbi_start_tvusec
    }

    var isRunning: Bool { RelayProcess(pid) == self }

    static func desktopAncestor(of pid: pid_t) -> NSRunningApplication? {
        var child = pid
        var visited = Set<pid_t>()
        while visited.insert(child).inserted, let info = self.info(about: child) {
            let parent = pid_t(info.pbi_ppid)
            if let app = NSRunningApplication(processIdentifier: parent),
               app.bundleIdentifier == DesktopTarget.bundleID, !app.isTerminated {
                return app
            }
            child = parent
        }
        return nil
    }

    private static func info(about pid: pid_t) -> proc_bsdinfo? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid()
        else { return nil }
        return info
    }

    static func descendants(of application: pid_t, running executable: URL) -> Set<RelayProcess> {
        let expected = executable.resolvingSymlinksInPath()
        let bundleID = bundleIdentifier(for: expected)
        var parents = [application]
        var visited = Set<pid_t>()
        var matches = Set<RelayProcess>()
        while let parent = parents.popLast() {
            guard visited.insert(parent).inserted else { continue }
            for pid in childIDs(of: parent) {
                guard let process = RelayProcess(pid) else { continue }
                parents.append(pid)
                guard let path = executablePath(of: pid) else { continue }
                let url = URL(fileURLWithPath: path)
                if url == expected || (url.lastPathComponent == expected.lastPathComponent
                    && bundleID != nil && bundleIdentifier(for: url) == bundleID) {
                    matches.insert(process)
                }
            }
        }
        return matches
    }

    private static func childIDs(of parent: pid_t) -> [pid_t] {
        let estimate = proc_listchildpids(parent, nil, 0)
        var children = [pid_t](repeating: 0, count: max(32, Int(estimate) + 16))
        let count = children.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
        return Array(children.prefix(max(0, Int(count))).filter { $0 > 1 })
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return String(decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func bundleIdentifier(for executable: URL) -> String? {
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }

}

private enum RelayMessage: Int32 {
    case register = 1, observation, event
}

private struct RelayRegistration: Codable {
    let pid: pid_t
    let session: UUID
}

final class DesktopReceiver {
    static let endpointPrefix = "local.codex-tps.desktop."

    private final class Callback {
        weak var receiver: DesktopReceiver?
        init(receiver: DesktopReceiver) { self.receiver = receiver }
    }

    private var port: CFMessagePort?
    private var registrations: [UUID: RelayProcess] = [:]
    private(set) var observing = false
    private var accepting = false
    var onRegistration: ((RelayProcess, UUID) -> Bool)?
    var onPacket: ((RelayPacket) -> Void)?

    var processes: Set<RelayProcess> { Set(registrations.values) }
    var isListening: Bool { port.map(CFMessagePortIsValid) == true }

    func start(on queue: DispatchQueue) throws -> String {
        stop()
        let name = Self.endpointPrefix + UUID().uuidString
        let callback = Callback(receiver: self)
        var context = CFMessagePortContext(
            version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                pointer.map { UnsafeRawPointer(Unmanaged<Callback>.fromOpaque($0).retain().toOpaque()) }
            },
            release: { pointer in
                if let pointer { Unmanaged<Callback>.fromOpaque(pointer).release() }
            },
            copyDescription: nil
        )
        var unusedContext = DarwinBoolean(false)
        guard let port = CFMessagePortCreateLocal(nil, name as CFString, { _, message, data, pointer in
            guard let pointer, let message = RelayMessage(rawValue: message),
                  let receiver = Unmanaged<Callback>.fromOpaque(pointer).takeUnretainedValue().receiver
            else { return nil }
            return receiver.receive(message, data: data as Data?)
        }, &context, &unusedContext), !unusedContext.boolValue else { throw RelayError.socket }
        self.port = port
        accepting = true
        observing = true
        CFMessagePortSetDispatchQueue(port, queue)
        return name
    }

    func setObservation(_ enabled: Bool) {
        accepting = true
        observing = enabled
    }

    func finishObservation() -> Set<RelayProcess> {
        observing = false
        accepting = false
        return processes
    }

    func stop() {
        if let port { CFMessagePortInvalidate(port) }
        port = nil
        registrations.removeAll()
        accepting = false
        observing = false
    }

    deinit { stop() }

    private func receive(_ message: RelayMessage, data: Data?) -> Unmanaged<CFData>? {
        switch message {
        case .register:
            guard accepting, let data, data.count <= 256,
                  let registration = try? JSONDecoder().decode(RelayRegistration.self, from: data),
                  let process = RelayProcess(registration.pid),
                  onRegistration?(process, registration.session) != false
            else { return nil }
            registrations = registrations.filter { $0.value.isRunning }
            registrations[registration.session] = process
        case .observation:
            break
        case .event:
            if observing, let data, data.count <= 16_384,
               let packet = try? JSONDecoder().decode(RelayPacket.self, from: data),
               registrations[packet.session] != nil {
                onPacket?(packet)
            }
            return nil
        }
        return .passRetained(Data([observing ? 1 : 0]) as CFData)
    }
}

final class RelaySender {
    private let port: CFMessagePort
    private let id = UUID()
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private var observing = false
    private var number: UInt64 = 0
    private var outputNumber: UInt64 = 0
    private var pendingLosses = RelayLossReport()

    init?(endpoint: String) {
        guard let port = CFMessagePortCreateRemote(nil, endpoint as CFString) else { return nil }
        self.port = port
    }

    func register() -> Bool {
        guard let data = try? encoder.encode(RelayRegistration(pid: getpid(), session: id)) else { return false }
        let response = request(.register, data: data)
        lock.withLock { observing = response == true }
        return response != nil
    }

    func refreshObservation() {
        let response = request(.observation)
        lock.withLock { observing = response == true }
    }

    var hasListener: Bool { lock.withLock { observing && CFMessagePortIsValid(port) } }

    private func request(_ message: RelayMessage, data: Data? = nil) -> Bool? {
        var response: Unmanaged<CFData>?
        let result = CFMessagePortSendRequest(port, message.rawValue, data as CFData?, 0.05, 0.5,
                                              CFRunLoopMode.defaultMode.rawValue, &response)
        guard result == kCFMessagePortSuccess, let response,
              let byte = (response.takeRetainedValue() as Data).first else { return nil }
        return byte == 1
    }

    func skip(_ loss: RelayLoss) {
        lock.withLock {
            number += 1
            if loss.impact.contains(.output) { outputNumber += 1 }
            pendingLosses.record(loss)
        }
    }

    func emit(_ event: CodexSignal) {
        lock.lock()
        defer { lock.unlock() }
        number += 1
        if event.kind == .text { outputNumber += 1 }
        func record(_ reason: RelayLoss.Reason, errorCode: Int32? = nil) {
            let impact: RelayLoss.Impact = switch event.kind {
            case .heartbeat: []
            case .text: .output
            default: .activity
            }
            pendingLosses.record(RelayLoss(reason: reason, impact: impact, event: event.kind.rawValue,
                                           thread: event.thread, errorCode: errorCode))
        }
        guard observing else { return record(.listenerUnavailable) }
        let packet = RelayPacket(session: id, sequence: number, outputSequence: outputNumber, signal: event,
                                 lossReport: pendingLosses.count > 0 ? pendingLosses : nil)
        guard let bytes = try? encoder.encode(packet), bytes.count <= 16_384
        else { return record(.encodingFailed) }
        // Give the local event queue a short chance to drain during a burst.
        let result = CFMessagePortSendRequest(port, RelayMessage.event.rawValue, bytes as CFData, 0.005, 0, nil, nil)
        guard result == kCFMessagePortSuccess else { return record(.sendFailed, errorCode: result) }
        pendingLosses = RelayLossReport()
    }
}

struct DesktopRuntime {
    let engine: String
    let launcher: String
    let endpoint: String

    func runtimeEnvironment(_ environment: [String: String]) -> [String: String] {
        var result = environment
        for key in ["CODEX_CLI_PATH", "CODEX_APP_RUNTIME_CLI_PATH"] where result[key] == launcher {
            result[key] = engine
        }
        return result
    }
}

enum DesktopRelay {
    static func runLeased(_ arguments: [String], path: DesktopLaunchPath,
                          environment: [String: String]) -> Int32 {
        let desktop = RelayProcess.desktopAncestor(of: getpid())
        let bundled = desktop?.bundleURL.flatMap { try? DesktopTarget(application: $0).engine }
        if let bundled {
            let runtime = DesktopRuntime(engine: bundled.path, launcher: path.launcher.path, endpoint: path.endpoint)
            return run(arguments, runtime: runtime, environment: environment)
        }

        // Other GUI processes can inherit the path. Forward their commands without observing them.
        let original = path.launcher.resolvingSymlinksInPath()
        let searchPath = (environment["PATH"] ?? "").split(separator: ":")
        let searched = searchPath.lazy.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("codex")
        }.first {
            $0.resolvingSymlinksInPath() != original && FileManager.default.isExecutableFile(atPath: $0.path)
        }
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: DesktopTarget.bundleID)
            .flatMap { try? DesktopTarget(application: $0).engine }
        guard let engine = searched ?? installed else { return 127 }
        var child = environment
        for key in ["CODEX_CLI_PATH", "CODEX_APP_RUNTIME_CLI_PATH"] where child[key] == path.launcher.path {
            child.removeValue(forKey: key)
        }
        return execRuntime(engine.path, arguments: arguments, environment: child)
    }

    static func isStdioLaunch(_ arguments: [String]) -> Bool {
        let configuration: Set<String> = ["-c", "--config", "--enable", "--disable"]
        var remaining = arguments[...]
        while let argument = remaining.first {
            let option = splitOption(argument)
            guard configuration.contains(option.name) else { break }
            remaining.removeFirst()
            if option.value == nil && remaining.popFirst() == nil { return false }
        }
        guard remaining.popFirst() == "app-server" else { return false }

        let valued = configuration.union(["--listen", "--startup-client-info",
                                          "--cloud-skills-snapshot", "--code-mode-host"])
        let flags: Set<String> = ["--stdio", "--strict-config", "--startup-sign-out",
                                  "--analytics-default-enabled"]
        while let argument = remaining.popFirst() {
            let option = splitOption(argument)
            if flags.contains(option.name), option.value == nil { continue }
            guard valued.contains(option.name),
                  let value = option.value ?? remaining.popFirst() else { return false }
            if option.name == "--listen", value != "stdio://" { return false }
        }
        return true
    }

    private static func splitOption(_ argument: String) -> (name: String, value: String?) {
        if argument.hasPrefix("-c"), argument.count > 2 {
            return ("-c", String(argument.dropFirst(2)))
        }
        guard let separator = argument.firstIndex(of: "=") else { return (argument, nil) }
        return (String(argument[..<separator]), String(argument[argument.index(after: separator)...]))
    }

    static func execRuntime(_ engine: String, arguments: [String], environment: [String: String]) -> Int32 {
        var argv = ([engine] + arguments).map { strdup($0) }
        var envp = environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { return 127 }
        argv.append(nil)
        envp.append(nil)
        _ = execve(engine, &argv, &envp)
        return 127
    }

    static func run(_ arguments: [String], runtime: DesktopRuntime, environment: [String: String]) -> Int32 {
        let childEnvironment = runtime.runtimeEnvironment(environment)
        let parent = getppid()
        guard parent > 1 else { return 0 }
        guard environment["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] == "Codex Desktop", isStdioLaunch(arguments),
              let sender = RelaySender(endpoint: runtime.endpoint), sender.register()
        else { return execRuntime(runtime.engine, arguments: arguments, environment: childEnvironment) }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: runtime.engine)
        child.arguments = arguments
        child.environment = childEnvironment
        child.standardError = FileHandle.standardError

        let input = Pipe()
        let output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        do { try child.run() } catch { return 127 }
        DispatchQueue.global(qos: .userInitiated).async {
            let wire = input.fileHandleForWriting
            defer { try? wire.close() }
            try? forward(FileHandle.standardInput, to: wire)
        }
        signal(SIGTERM, SIG_IGN)
        let shutdown = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
        let terminateChild: @Sendable () -> Void = { if child.isRunning { child.terminate() } }
        shutdown.setEventHandler(handler: terminateChild)
        shutdown.resume()
        let parentExit = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit,
                                                           queue: .global(qos: .utility))
        parentExit.setEventHandler(handler: terminateChild)
        parentExit.resume()
        if getppid() != parent { terminateChild() }
        defer {
            shutdown.cancel()
            parentExit.cancel()
        }

        let beat = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        beat.schedule(deadline: .now(), repeating: 1.5)
        beat.setEventHandler {
            sender.refreshObservation()
            sender.emit(.init(kind: .heartbeat))
        }
        beat.resume()
        do {
            try forwardObserved(output.fileHandleForReading, to: FileHandle.standardOutput,
                                listening: { sender.hasListener }, emit: sender.emit, skip: sender.skip)
        } catch {
            if child.isRunning { child.terminate() }
        }
        beat.cancel()
        child.waitUntilExit()
        return child.terminationStatus
    }

    private static let rpcHeader = #/
        [ \t\r]* \{ [ \t\r]*
        (?:
            (?: "jsonrpc" [ \t\r]* : [ \t\r]* "2\.0"
              | "id" [ \t\r]* : [ \t\r]* (?: -?[0-9]+ | "[^"\\]{0,128}" | null ) )
            [ \t\r]* , [ \t\r]*
        )*
        (?: "method" [ \t\r]* : [ \t\r]* "([A-Za-z0-9/_]+)" [ \t\r]* (?=[,}])
          | "(result|error)" [ \t\r]* : )
        /#

    private static func oversizedFrame(_ line: Data) -> RelayLoss {
        // Inspect only recognized top-level headers from the App Server's NDJSON.
        // An unrecognized header cannot prove whether a visible delta was skipped.
        let prefix = String(decoding: line.prefix(4096), as: UTF8.self)
        if let header = prefix.prefixMatch(of: rpcHeader) {
            if header.2 != nil { return RelayLoss(reason: .oversizedFrame, impact: [], event: "response") }
            switch header.1 {
            case "item/started", "item/completed", "thread/status/changed", "turn/started", "turn/completed",
                 "thread/closed", "item/reasoning/summaryPartAdded", "item/reasoning/summaryTextDelta",
                 "item/reasoning/textDelta":
                return RelayLoss(reason: .oversizedFrame, impact: .activity, event: header.1.map { String($0) })
            case "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
                return RelayLoss(reason: .oversizedFrame, impact: [], event: header.1.map { String($0) })
            case "item/agentMessage/delta":
                return RelayLoss(reason: .oversizedFrame, impact: .output, event: "item/agentMessage/delta")
            default:
                break
            }
        }
        return RelayLoss(reason: .oversizedFrame, impact: .unknown)
    }

    static func forwardObserved(_ input: FileHandle, to output: FileHandle, listening: () -> Bool,
                                emit: (CodexSignal) -> Void, skip: (RelayLoss) -> Void) throws {
        let limit = 2_097_152
        var line = Data()
        var skipping = false
        try forward(input, to: output) { bytes in
            if !listening() {
                line.removeAll(keepingCapacity: true)
                skipping = bytes.last != 10
                skip(RelayLoss(reason: .listenerUnavailable, impact: .unknown))
                return
            }
            var start = bytes.startIndex
            while start < bytes.endIndex {
                let newline = bytes[start...].firstIndex(of: 10)
                let end = newline ?? bytes.endIndex
                if !skipping {
                    if line.count + end - start <= limit {
                        line.append(contentsOf: bytes[start..<end])
                    } else {
                        skip(oversizedFrame(line))
                        skipping = true
                        line.removeAll(keepingCapacity: true)
                    }
                }
                guard let newline else { break }
                if !skipping, !line.isEmpty {
                    if let packet = JSON.object(line) {
                        if let event = CodexSignal.from(packet) {
                            emit(event)
                        } else if packet["method"] as? String == "item/agentMessage/delta" {
                            let params = packet["params"] as? [String: Any]
                            if params?["delta"] as? String != "" {
                                skip(RelayLoss(reason: .malformedText, impact: .output, event: "item/agentMessage/delta",
                                               thread: params?["threadId"] as? String))
                            }
                        }
                    } else if line.contains(where: { $0 != 9 && $0 != 13 && $0 != 32 }) {
                        skip(RelayLoss(reason: .malformedFrame, impact: .unknown))
                    }
                }
                skipping = false
                line.removeAll(keepingCapacity: true)
                start = newline + 1
            }
        }
    }

    static func forward(_ input: FileHandle, to output: FileHandle,
                        observe: (Data) -> Void = { _ in }) throws {
        // Forward the bytes already available on each pipe. A model request
        // can be waiting on a complete JSON line much smaller than the buffer.
        var scratch = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = scratch.withUnsafeMutableBytes { read(input.fileDescriptor, $0.baseAddress, $0.count) }
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let bytes = Data(scratch.prefix(count))
            try output.write(contentsOf: bytes)
            observe(bytes)
        }
    }
}
