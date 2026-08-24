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
        let reader = SMCReader(cachedCpuTempKeys: ["Tp09"], keyReader: connection)

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

        static func value(key: String, double: Double) -> SMCValue {
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

    func testCPUTemperatureResultIsCachedForFiveSeconds() throws {
        let connection = TemperatureKeyRecorder(temperatures: ["Tp09": 50])
        let reader = SMCReader(cachedCpuTempKeys: ["Tp09"], keyReader: connection)
        let hints = SMCReadHints(
            needsScreenPower: false,
            needsHeatpipePower: false,
            needsTemperature: true
        )

        let first = try XCTUnwrap(reader.readPowerData(detailLevel: .summary, hints: hints))
        XCTAssertTrue(first.hasCpuTemperature)
        XCTAssertEqual(connection.readCountByPrefix["T"], 2)
        XCTAssertEqual(first.cpuTemperature, 50, accuracy: 0.001)

        connection.readCountByPrefix["T"] = 0
        let cached = reader.readPowerData(detailLevel: .summary, hints: hints)
        XCTAssertTrue(cached.hasCpuTemperature)
        XCTAssertEqual(cached.cpuTemperature, 50, accuracy: 0.001)
        XCTAssertEqual(connection.readCountByPrefix["T"], 0)
    }

    private final class TemperatureKeyRecorder: FanKeyReading {
        private let temperatures: [String: Double]
        var readCountByPrefix: [String: Int] = [:]

        init(temperatures: [String: Double]) {
            self.temperatures = temperatures
        }

        func readKey(_ key: String) -> SMCValue? {
            let prefix = String(key.prefix(1))
            readCountByPrefix[prefix, default: 0] += 1
            guard let value = temperatures[key], value > 0, value < 150, key == "Tp09" else {
                return nil
            }
            var raw = Float(value)
            let bits = withUnsafeBytes(of: &raw) { Array($0) }
            return SMCValue(
                key: key,
                dataSize: 4,
                dataType: "flt",
                bytes: Array(bits)
            )
        }
    }
}
