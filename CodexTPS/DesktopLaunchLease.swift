import AppKit
import CoreFoundation
import Darwin
import Foundation

struct DesktopLaunchPath: Equatable {
    private static let prefix = "codex-tps-live-"
    let directory: URL
    let id: UUID

    var launcher: URL { directory.appendingPathComponent("codex") }
    var endpoint: String { DesktopReceiver.endpointPrefix + id.uuidString }

    init?(endpoint: String) {
        guard endpoint.hasPrefix(DesktopReceiver.endpointPrefix),
              let id = UUID(uuidString: String(endpoint.dropFirst(DesktopReceiver.endpointPrefix.count))),
              let root = Self.temporaryRoot() else { return nil }
        self.id = id
        directory = root.appendingPathComponent(Self.prefix + id.uuidString, isDirectory: true)
    }

    init?(launcher: String) {
        guard launcher.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: launcher)
        let folder = url.deletingLastPathComponent().lastPathComponent
        guard folder.hasPrefix(Self.prefix),
              let parsed = Self(endpoint: DesktopReceiver.endpointPrefix + folder.dropFirst(Self.prefix.count)),
              launcher == parsed.launcher.path else { return nil }
        self = parsed
    }

    private static func temporaryRoot() -> URL? {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) == size else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true).resolvingSymlinksInPath()
    }

    func install(executable: URL) throws {
        guard mkdir(directory.path, 0o700) == 0 else { throw RelayError.launchSetting }
        do {
            let fd = try DesktopPathSecurity.directory(directory, privateToUser: true)
            defer { Darwin.close(fd) }
            // A Desktop process can reuse this path after the TPS app has been replaced.
            try FileManager.default.copyItem(at: executable, to: launcher)
            guard FileManager.default.isExecutableFile(atPath: launcher.path) else { throw RelayError.launchSetting }
        } catch {
            try? remove()
            throw error
        }
    }

    func remove() throws {
        let fd: Int32
        do { fd = try DesktopPathSecurity.directory(directory, privateToUser: true) }
        catch let error as POSIXError where error.code == .ENOENT { return }
        defer { Darwin.close(fd) }
        var item = stat()
        let name = launcher.lastPathComponent
        if fstatat(fd, name, &item, AT_SYMLINK_NOFOLLOW) == 0 {
            guard item.st_uid == getuid(), [S_IFLNK, S_IFREG].contains(item.st_mode & S_IFMT),
                  unlinkat(fd, name, 0) == 0 else { throw RelayError.unsafeDesktopPath }
        } else if errno != ENOENT {
            throw RelayError.restore
        }
        if rmdir(directory.path) != 0, errno != ENOENT { throw RelayError.restore }
    }

    func possibleHolders(excluding existing: Set<RelayProcess> = []) -> Set<RelayProcess> {
        let created = (try? directory.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        return Set(DesktopTarget.runningApplications.compactMap { app in
            guard let process = RelayProcess(app.processIdentifier), !existing.contains(process) else { return nil }
            if let created, let launched = app.launchDate, launched < created { return nil }
            return process
        })
    }

    func removeWhenUnused(by holders: Set<RelayProcess>) throws {
        while holders.contains(where: \.isRunning) { Thread.sleep(forTimeInterval: 0.5) }
        try remove()
    }

    func clearSetting(using command: ([String]) throws -> String = DesktopLaunchLease.runLaunchctl) throws {
        let key = DesktopLaunchLease.runtimeKey
        guard try command(["getenv", key]) == launcher.path else { return }
        _ = try command(["unsetenv", key])
        guard try command(["getenv", key]) != launcher.path else { throw RelayError.restore }
    }
}

/// The helper owns the setting. Its input pipe belongs to TPS and closes even if TPS is killed.
final class DesktopLaunchLease {
    static let runtimeKey = "CODEX_CLI_PATH"

    static func runLaunchctl(_ arguments: [String]) throws -> String {
        let p = Process()
        let output = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = arguments
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw RelayError.launchSetting }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .replacingOccurrences(of: "\n$", with: "", options: .regularExpression)
    }

    private enum Reply: UInt8 { case ready = 82, released = 68, busy = 66, conflict = 67, failed = 69 }

    let path: DesktopLaunchPath
    private let process = Process()
    private var writer: FileHandle?
    private var reader: FileHandle?

    private init(path: DesktopLaunchPath) { self.path = path }

    static func start(endpoint: String, executable: URL) async throws -> DesktopLaunchLease {
        guard let path = DesktopLaunchPath(endpoint: endpoint) else { throw RelayError.launchSetting }
        let lease = DesktopLaunchLease(path: path)
        let input = Pipe()
        let output = Pipe()
        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        guard fcntl(writer.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(reader.fileDescriptor, F_SETFL, O_NONBLOCK) == 0 else { throw RelayError.launchSetting }
        lease.process.executableURL = executable
        lease.process.arguments = ["--desktop-launch-lease", endpoint]
        lease.process.standardInput = input
        lease.process.standardOutput = output
        lease.process.standardError = FileHandle.nullDevice
        try lease.process.run()
        lease.writer = writer
        lease.reader = reader

        do {
            for _ in 0..<100 {
                var byte: UInt8 = 0
                let count = read(reader.fileDescriptor, &byte, 1)
                if count == 1 {
                    switch Reply(rawValue: byte) {
                    case .ready: return lease
                    case .busy: throw RelayError.receiverInUse
                    case .conflict: throw RelayError.conflictingSetup
                    default: throw RelayError.launchSetting
                    }
                }
                if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw RelayError.launchSetting
        } catch {
            try? await lease.stop()
            throw error
        }
    }

    func stop() async throws {
        if let writer {
            self.writer = nil
            try writer.close()
        }
        for _ in 0..<100 {
            if let reader {
                var byte: UInt8 = 0
                if read(reader.fileDescriptor, &byte, 1) == 1 {
                    guard byte == Reply.released.rawValue else { throw RelayError.restore }
                    try reader.close()
                    self.reader = nil
                    return
                }
            }
            if !process.isRunning {
                // The helper may have failed before activation. A live Desktop can still need its launcher.
                try Self.withOwner {
                    try path.clearSetting()
                    if path.possibleHolders().isEmpty { try path.remove() }
                }
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw RelayError.restore
    }

    deinit {
        try? writer?.close()
        try? reader?.close()
    }

    private static func withOwner<T>(_ operation: () throws -> T) throws -> T {
        let name = "local.codex-tps.launch-owner.\(getuid())"
        var ignored = DarwinBoolean(false)
        guard let owner = CFMessagePortCreateLocal(nil, name as CFString, { _, _, _, _ in nil }, nil, &ignored),
              !ignored.boolValue else { throw RelayError.receiverInUse }
        defer { CFMessagePortInvalidate(owner) }
        return try operation()
    }

    static func maintain(endpoint: String, executable: URL) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        do {
            guard let path = DesktopLaunchPath(endpoint: endpoint),
                  let receiver = CFMessagePortCreateRemote(nil, endpoint as CFString),
                  CFMessagePortIsValid(receiver) else { throw RelayError.launchSetting }
            var retired: (DesktopLaunchPath, Set<RelayProcess>)?
            let holders = try withOwner {
                let key = DesktopLaunchLease.runtimeKey
                let previous = try DesktopLaunchLease.runLaunchctl(["getenv", key])
                if !previous.isEmpty {
                    guard let stale = DesktopLaunchPath(launcher: previous) else { throw RelayError.conflictingSetup }
                    try stale.clearSetting()
                    let holders = stale.possibleHolders()
                    if holders.isEmpty {
                        try stale.remove()
                    } else {
                        retired = (stale, holders)
                        DispatchQueue.global(qos: .utility).async {
                            try? stale.removeWhenUnused(by: holders)
                        }
                    }
                }
                try path.install(executable: executable)
                let alreadyRunning = Set(DesktopTarget.runningApplications.compactMap {
                    RelayProcess($0.processIdentifier)
                })
                do {
                    guard try DesktopLaunchLease.runLaunchctl(["getenv", key]).isEmpty else {
                        throw RelayError.conflictingSetup
                    }
                    _ = try DesktopLaunchLease.runLaunchctl(["setenv", key, path.launcher.path])
                    guard try DesktopLaunchLease.runLaunchctl(["getenv", key]) == path.launcher.path else {
                        throw RelayError.launchSetting
                    }
                    // The owner can disappear before reading readiness. EOF still releases the setting.
                    try? reply(.ready)
                    _ = try FileHandle.standardInput.readToEnd()
                } catch {
                    try? path.clearSetting()
                    if path.possibleHolders(excluding: alreadyRunning).isEmpty { try? path.remove() }
                    throw error
                }
                try path.clearSetting()
                return path.possibleHolders(excluding: alreadyRunning)
            }
            if holders.isEmpty { try path.remove() }
            try? reply(.released)
            if !holders.isEmpty { try path.removeWhenUnused(by: holders) }
            if let (stale, users) = retired { try stale.removeWhenUnused(by: users) }
            return 0
        } catch {
            let reply: Reply = switch error as? RelayError {
            case .receiverInUse: .busy
            case .conflictingSetup: .conflict
            default: .failed
            }
            try? Self.reply(reply)
            return 1
        }
    }

    private static func reply(_ reply: Reply) throws {
        try FileHandle.standardOutput.write(contentsOf: Data([reply.rawValue]))
    }
}
