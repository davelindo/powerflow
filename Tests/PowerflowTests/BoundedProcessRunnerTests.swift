import Foundation
import XCTest
@testable import Powerflow

final class BoundedProcessRunnerTests: XCTestCase {
    func testDeadlineIncludesOutputHeldOpenByDescendant() {
        let start = ProcessInfo.processInfo.systemUptime
        let data = BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 2 & printf done"],
            timeout: 0.1
        )
        XCTAssertNil(data)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func testDrainsLargeOutputWithoutTruncation() {
        let data = BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/head"),
            arguments: ["-c", "131072", "/dev/zero"]
        )
        XCTAssertEqual(data?.count, 131_072)
    }

    func testReturnsBoundedSuccessfulOutput() {
        let data = BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf powerflow"]
        )
        XCTAssertEqual(data.flatMap { String(data: $0, encoding: .utf8) }, "powerflow")
    }

    func testRejectsOversizedOutput() {
        let data = BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes x | head -c 4096"],
            maximumOutputBytes: 128
        )
        XCTAssertNil(data)
    }

    func testTimeoutReturnsPromptly() {
        let start = Date()
        let data = BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 2"],
            timeout: 0.05,
            terminationGrace: 0.05
        )
        XCTAssertNil(data)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }
}
