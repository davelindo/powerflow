import XCTest
@testable import Powerflow

final class SMCReaderFanCacheTests: XCTestCase {
    func testFanPercentageDoesNotChangeWithDetailLevel() throws {
        let connection = FanKeyRecorder(keys: [
            "FNum": .count(1),
            "F0Ac": .rpm(1_800),
            "F0Mn": .rpm(1_200),
            "F0Mx": .rpm(4_000),
        ])
        let reader = SMCReader(cachedCpuTempKeys: [], keyReader: connection)
        let summary = try XCTUnwrap(reader.readFanReadings(connection, includeDetails: false).first?.percentMax)
        let full = try XCTUnwrap(reader.readFanReadings(connection, includeDetails: true).first?.percentMax)
        XCTAssertEqual(summary, 45, accuracy: 0.001)
        XCTAssertEqual(full, summary, accuracy: 0.001)
    }

    func testSummaryFanReadingsKeepLiveRPMWhileCachingStableMetadata() {
        let connection = FanKeyRecorder(keys: [
            "FNum": .count(2),
            "F0Ac": .rpm(1_800),
            "F0Mx": .rpm(4_000),
            "F1Ac": .rpm(2_000),
            "F1Mx": .rpm(5_000),
        ])
        let reader = SMCReader(cachedCpuTempKeys: ["Tp09"], keyReader: connection)

        let first = reader.readFanReadings(connection, includeDetails: false)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[0].rpm, 1_800, accuracy: 0.001)
        XCTAssertEqual(first[1].rpm, 2_000, accuracy: 0.001)

        connection.set(.rpm(2_100), for: "F0Ac")
        connection.set(.rpm(2_300), for: "F1Ac")
        connection.resetReadCounts()
        let second = reader.readFanReadings(connection, includeDetails: false)

        XCTAssertEqual(second[0].rpm, 2_100, accuracy: 0.001)
        XCTAssertEqual(second[1].rpm, 2_300, accuracy: 0.001)
        XCTAssertEqual(connection.readCount(for: "FNum"), 0)
        XCTAssertEqual(connection.readCount(for: "F0Mx"), 0)
        XCTAssertEqual(connection.readCount(for: "F1Mx"), 0)
        XCTAssertEqual(connection.readCount(for: "F0Ac"), 1)
        XCTAssertEqual(connection.readCount(for: "F1Ac"), 1)
    }

    func testFullFanReadingsKeepTargetAndModeLiveWhileCachingLimits() {
        let connection = FanKeyRecorder(keys: [
            "FNum": .count(1),
            "F0Ac": .rpm(1_800),
            "F0Mx": .rpm(4_000),
            "F0Mn": .rpm(1_200),
            "F0Tg": .rpm(2_000),
            "F0Md": .count(0),
        ])
        let reader = SMCReader(cachedCpuTempKeys: ["Tp09"], keyReader: connection)

        let first = reader.readFanReadings(connection, includeDetails: true)
        XCTAssertEqual(first.first?.targetRpm, 2_000)
        XCTAssertEqual(first.first?.modeRaw, 0)

        connection.set(.rpm(2_400), for: "F0Ac")
        connection.set(.rpm(2_600), for: "F0Tg")
        connection.set(.count(1), for: "F0Md")
        connection.resetReadCounts()
        let second = reader.readFanReadings(connection, includeDetails: true)

        XCTAssertEqual(second.first?.rpm, 2_400)
        XCTAssertEqual(second.first?.targetRpm, 2_600)
        XCTAssertEqual(second.first?.modeRaw, 1)
        XCTAssertEqual(connection.readCount(for: "FNum"), 0)
        XCTAssertEqual(connection.readCount(for: "F0Mx"), 0)
        XCTAssertEqual(connection.readCount(for: "F0Mn"), 0)
        XCTAssertEqual(connection.readCount(for: "F0Tg"), 1)
        XCTAssertEqual(connection.readCount(for: "F0Md"), 1)
    }

    private final class FanKeyRecorder: FanKeyReading {
        enum Value {
            case count(Int)
            case rpm(Double)
        }

        private var values: [String: Value]
        private var readCounts: [String: Int] = [:]

        init(keys: [String: Value]) {
            values = keys
        }

        func readKey(_ key: String) -> SMCValue? {
            readCounts[key, default: 0] += 1
            guard let value = values[key] else { return nil }
            switch value {
            case .count(let count):
                return Self.value(key: key, double: Double(count))
            case .rpm(let rpm):
                return Self.value(key: key, double: rpm)
            }
        }

        func set(_ value: Value, for key: String) {
            values[key] = value
        }

        func resetReadCounts() {
            readCounts = [:]
        }

        func readCount(for key: String) -> Int {
            readCounts[key, default: 0]
        }

        static func value(key: String, double: Double) -> SMCValue {
            var raw = Float(double)
            let bits = withUnsafeBytes(of: &raw) { Array($0) }
            return SMCValue(
                key: key,
                dataSize: 4,
                dataType: "flt",
                bytes: bits
            )
        }
    }

    func testCPUTemperatureResultIsCachedForFiveSecondsWithoutSuppressingBatteryTemperature() {
        let connection = TemperatureKeyRecorder(temperatures: ["TB0T": 32, "Tp09": 50])
        let reader = SMCReader(cachedCpuTempKeys: ["Tp09"], keyReader: connection)
        let hints = SMCReadHints(
            needsScreenPower: false,
            needsHeatpipePower: false,
            needsTemperature: true
        )

        let first = reader.readPowerData(detailLevel: .summary, hints: hints)
        XCTAssertTrue(first.hasTemperature)
        XCTAssertEqual(first.temperature, 32, accuracy: 0.001)
        XCTAssertTrue(first.hasCpuTemperature)
        XCTAssertEqual(connection.readCountByPrefix["T"], 2)
        XCTAssertEqual(first.cpuTemperature, 50, accuracy: 0.001)

        connection.readCountByPrefix["T"] = 0
        let cached = reader.readPowerData(detailLevel: .summary, hints: hints)
        XCTAssertTrue(cached.hasTemperature)
        XCTAssertEqual(cached.temperature, 32, accuracy: 0.001)
        XCTAssertTrue(cached.hasCpuTemperature)
        XCTAssertEqual(cached.cpuTemperature, 50, accuracy: 0.001)
        XCTAssertEqual(connection.readCountByPrefix["T"], 1)
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
            guard let value = temperatures[key], value > 0, value < 150 else {
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
