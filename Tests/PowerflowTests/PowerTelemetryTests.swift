import XCTest
@testable import Powerflow

final class PowerTelemetryTests: XCTestCase {
    func testEmptyTelemetryCarriesNoSystemPowerData() {
        XCTAssertFalse(PowerTelemetry.empty.hasSystemPowerData)
        XCTAssertNil(PowerTelemetry.empty.systemPowerInWatts)
        XCTAssertNil(PowerTelemetry.empty.systemLoadWatts)
    }

    func testTelemetryKeepsFieldPresenceSeparateFromZeroValues() throws {
        let telemetry = PowerTelemetry(
            adapterEfficiencyLoss: nil,
            batteryPower: 0,
            systemCurrentIn: nil,
            systemEnergyConsumed: nil,
            systemLoad: 0,
            systemPowerIn: 61_800,
            systemVoltageIn: nil
        )

        XCTAssertTrue(telemetry.hasSystemPowerData)
        XCTAssertEqual(try XCTUnwrap(telemetry.batteryPowerWatts), 0)
        XCTAssertEqual(try XCTUnwrap(telemetry.systemLoadWatts), 0)
        XCTAssertEqual(try XCTUnwrap(telemetry.systemPowerInWatts), 61.8, accuracy: 0.001)
    }

    func testPartialTelemetryWithSystemPowerInputIsSystemPowerData() {
        let telemetry = PowerTelemetry(
            adapterEfficiencyLoss: nil,
            batteryPower: nil,
            systemCurrentIn: 3_200,
            systemEnergyConsumed: nil,
            systemLoad: nil,
            systemPowerIn: 61_800,
            systemVoltageIn: 20_000
        )

        XCTAssertTrue(telemetry.hasAnyTelemetryData)
        XCTAssertTrue(telemetry.hasSystemPowerData)
    }

    func testCurrentVoltageOnlyTelemetryIsNotSystemPowerData() {
        let telemetry = PowerTelemetry(
            adapterEfficiencyLoss: nil,
            batteryPower: nil,
            systemCurrentIn: 3_200,
            systemEnergyConsumed: nil,
            systemLoad: nil,
            systemPowerIn: nil,
            systemVoltageIn: 20_000
        )

        XCTAssertTrue(telemetry.hasAnyTelemetryData)
        XCTAssertFalse(telemetry.hasSystemPowerData)
    }

    func testSnapshotRequiresUsableSystemPowerPairForBalanceChecks() {
        var snapshot = PowerSnapshot.empty
        snapshot.systemIn = 60
        snapshot.systemLoad = 0
        snapshot.batteryPower = 60
        snapshot.diagnostics = PowerDiagnostics(
            smc: .empty,
            telemetry: PowerTelemetry(
                adapterEfficiencyLoss: nil,
                batteryPower: nil,
                systemCurrentIn: 3_000,
                systemEnergyConsumed: nil,
                systemLoad: nil,
                systemPowerIn: nil,
                systemVoltageIn: 20_000
            )
        )

        XCTAssertFalse(snapshot.hasSystemPowerData)
        XCTAssertTrue(snapshot.isPowerBalanceConsistent)
    }

    func testSystemPowerResolutionKeepsTelemetryPairsTogether() {
        var smc = SMCPowerData.empty
        smc.deliveryRate = 65
        smc.hasDeliveryRate = true

        let resolved = MacPowerDataProvider.resolvedSystemPower(
            smc: smc,
            telemetrySystemIn: 61.8,
            telemetrySystemLoad: 34.6,
            adapterInputPower: nil
        )

        XCTAssertEqual(resolved.input, 61.8, accuracy: 0.001)
        XCTAssertEqual(resolved.load, 34.6, accuracy: 0.001)
    }

    func testSystemPowerResolutionUsesDeliveryRateWithoutSystemTotal() {
        var smc = SMCPowerData.empty
        smc.deliveryRate = 65
        smc.hasDeliveryRate = true

        let resolved = MacPowerDataProvider.resolvedSystemPower(
            smc: smc,
            telemetrySystemIn: nil,
            telemetrySystemLoad: nil,
            adapterInputPower: 96
        )

        XCTAssertEqual(resolved.input, 65, accuracy: 0.001)
        XCTAssertEqual(resolved.load, 0, accuracy: 0.001)
    }
}
