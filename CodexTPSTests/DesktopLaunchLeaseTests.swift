import Foundation
import XCTest
@testable import CodexTPS

final class DesktopLaunchLeaseTests: XCTestCase {
    func testPrivateLauncherPathRoundTripsToTheSameEndpoint() throws {
        let endpoint = DesktopReceiver.endpointPrefix + UUID().uuidString
        let launch = try XCTUnwrap(DesktopLaunchPath(endpoint: endpoint))
        XCTAssertEqual(DesktopLaunchPath(launcher: launch.launcher.path), launch)
        XCTAssertEqual(launch.endpoint, endpoint)
        XCTAssertNil(DesktopLaunchPath(launcher: launch.directory.appendingPathComponent("other").path))
        XCTAssertNil(DesktopLaunchPath(launcher: "/tmp/\(launch.directory.lastPathComponent)/codex"))
        XCTAssertNil(DesktopLaunchPath(endpoint: "a different service"))
    }

    func testTemporaryLauncherRunsAfterItsOriginalHasBeenRemoved() throws {
        let launch = try XCTUnwrap(DesktopLaunchPath(endpoint: DesktopReceiver.endpointPrefix + UUID().uuidString))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        defer { try? launch.remove() }
        let original = folder.appendingPathComponent("runtime")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: original)
        try launch.install(executable: original)
        try FileManager.default.removeItem(at: original)
        let process = Process()
        process.executableURL = launch.launcher
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testCleanupLeavesAReplacementRuntimeSettingAlone() throws {
        let launch = try XCTUnwrap(DesktopLaunchPath(endpoint: DesktopReceiver.endpointPrefix + UUID().uuidString))
        var writes: [[String]] = []
        let other = "/another/runtime"
        try launch.clearSetting { arguments in
            if arguments.first == "getenv" { return other }
            writes.append(arguments)
            return ""
        }
        XCTAssertTrue(writes.isEmpty)
    }

    func testCleanupConfirmsTheOwnedRuntimeWasRemoved() throws {
        let launch = try XCTUnwrap(DesktopLaunchPath(endpoint: DesktopReceiver.endpointPrefix + UUID().uuidString))
        var current = launch.launcher.path
        try launch.clearSetting { arguments in
            if arguments.first == "getenv" { return current }
            XCTAssertEqual(arguments, ["unsetenv", DesktopLaunchLease.runtimeKey])
            current = ""
            return ""
        }
        XCTAssertTrue(current.isEmpty)

        let unchanged = launch.launcher.path
        XCTAssertThrowsError(try launch.clearSetting { _ in unchanged })
    }
}
