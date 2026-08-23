import XCTest
@testable import Powerflow

final class SystemEnergyCounterCalibratorTests: XCTestCase {
    func testValidatesStableCounterScaleBeforeReturningEnergy() throws {
        var calibrator = SystemEnergyCounterCalibrator()
        var lastEnergy: Double?

        for index in 0...12 {
            lastEnergy = calibrator.energyDeltaWh(
                rawCounter: UInt64(index * 100),
                systemLoadWatts: 36,
                uptime: Double(index * 10)
            )
            if index < 12 {
                XCTAssertNil(lastEnergy)
            }
        }

        XCTAssertTrue(calibrator.isValidated)
        XCTAssertEqual(try XCTUnwrap(lastEnergy), 0.1, accuracy: 0.000_001)
    }

    func testRejectsUnstableCounterScale() {
        var calibrator = SystemEnergyCounterCalibrator()
        var raw: UInt64 = 0
        let deltas: [UInt64] = [10, 1_000, 20, 900, 30, 800, 40, 700, 50, 600, 60, 500, 70]

        _ = calibrator.energyDeltaWh(rawCounter: raw, systemLoadWatts: 36, uptime: 0)
        for (index, delta) in deltas.enumerated() {
            raw += delta
            XCTAssertNil(
                calibrator.energyDeltaWh(
                    rawCounter: raw,
                    systemLoadWatts: 36,
                    uptime: Double((index + 1) * 10)
                )
            )
        }

        XCTAssertFalse(calibrator.isValidated)
    }

    func testRegressionInvalidatesValidatedCounter() {
        var calibrator = SystemEnergyCounterCalibrator()
        for index in 0...12 {
            _ = calibrator.energyDeltaWh(
                rawCounter: UInt64(index * 100),
                systemLoadWatts: 36,
                uptime: Double(index * 10)
            )
        }
        XCTAssertTrue(calibrator.isValidated)

        XCTAssertNil(calibrator.energyDeltaWh(rawCounter: 5, systemLoadWatts: 36, uptime: 130))
        XCTAssertFalse(calibrator.isValidated)
    }
}
