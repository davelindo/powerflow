import Foundation
import XCTest
@testable import Powerflow

final class BoundedProcessRunnerTests: XCTestCase {
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
