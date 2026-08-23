import XCTest
@testable import Powerflow

final class SMCReaderFanCacheTests: XCTestCase {
    func testSummaryFanReadingsAreCachedBetweenSamples() throws {
        let connection = FanKeyRecorder(keys: [
            "FNum": .count(2),
            "F0Ac": .rpm(1_800),
            "F0Mx": .rpm(4_000),
            "F1Ac": .rpm(2_000),
            "F1Mx": .rpm(5_000),
        ])
        let reader = SMCReader()

        let first = try XCTUnwrap(reader.readFanReadings(connection, includeDetails: false))
        XCTAssertEqual(first.count, 2)

        connection.readCount = 0
        _ = reader.readFanReadings(connection, includeDetails: false)

        XCTAssertGreaterThanOrEqual(connection.readCount, 1)
    }

    private final class FanKeyRecorder: FanKeyReading {
        enum Value {
            case count(Int)
            case rpm(Double)
        }

        private let values: [String: Value]
        var readCount = 0

        init(keys: [String: Value]) {
            values = keys
        }

        func readKey(_ key: String) -> SMCValue? {
            readCount += 1
            guard let value = values[key] else { return nil }
            switch value {
            case .count(let count):
                return Self.value(key: key, double: Double(count))
            case .rpm(let rpm):
                return Self.value(key: key, double: rpm)
            }
        }

        private static func value(key: String, double: Double) -> SMCValue {
            var raw = Float(double)
            let bits = withUnsafeBytes(of: &raw) { Array($0).reversed() }
            return SMCValue(
                key: key,
                dataSize: 4,
                dataType: "flt",
                bytes: Array(bits)
            )
        }
    }
}
