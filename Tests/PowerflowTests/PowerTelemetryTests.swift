import XCTest
@testable import Powerflow

final class PowerTelemetryTests: XCTestCase {
    func testPartialSystemTelemetryPreservesAvailableLoad() {
        let resolved = MacPowerDataProvider.resolvedSystemPower(
            smc: .empty, telemetrySystemIn: nil, telemetrySystemLoad: 36, adapterInputPower: nil
        )
        XCTAssertEqual(resolved.load, 36)
    }

    func testComputeBudgetDistinguishesMissingPowerFromMeasuredZero() {
        XCTAssertNil(MacPowerDataProvider.computePowerBudget(systemLoad: nil, screenPower: nil, packagePower: nil))
        XCTAssertNil(MacPowerDataProvider.computePowerBudget(systemLoad: .infinity, screenPower: 4, packagePower: nil))
        XCTAssertEqual(MacPowerDataProvider.computePowerBudget(systemLoad: 0, screenPower: nil, packagePower: nil), 0)
        XCTAssertEqual(MacPowerDataProvider.computePowerBudget(systemLoad: nil, screenPower: nil, packagePower: 8), 8)
    }

    func testPowerValidationRejectsNonFiniteNegativeAndImplausibleValues() {
        XCTAssertNil(MacPowerDataProvider.validatedPower(.infinity))
        XCTAssertNil(MacPowerDataProvider.validatedPower(-1))
        XCTAssertNil(MacPowerDataProvider.validatedPower(501))
        XCTAssertEqual(MacPowerDataProvider.validatedPower(-12, allowsNegative: true), -12)
    }

    func testSMCSanitizationDropsImplausiblePowerAndFanReadings() {
        var smc = SMCPowerData.empty
        smc.systemTotal = 4.25e14
        smc.hasSystemTotal = true
        smc.batteryRate = 242_253
        smc.hasBatteryRate = true
        smc.fanReadings = [
            SMCFanReading(
                index: 0,
                rpm: 1e12,
                maxRpm: 1,
                minRpm: nil,
                targetRpm: nil,
                modeRaw: nil,
                percentMax: 100
            ),
        ]

        let sanitized = MacPowerDataProvider.sanitizedSMC(smc)

        XCTAssertFalse(sanitized.hasSystemTotal)
        XCTAssertFalse(sanitized.hasBatteryRate)
        XCTAssertTrue(sanitized.fanReadings.isEmpty)
    }

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

    func testSystemPowerResolutionKeepsTelemetryPairsTogether() throws {
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
        XCTAssertEqual(try XCTUnwrap(resolved.load), 34.6, accuracy: 0.001)
    }

    func testInputOnlySnapshotDoesNotRetryBalanceAgainstMissingLoad() {
        var snapshot = PowerSnapshot.empty
        snapshot.systemIn = 60
        snapshot.systemLoad = 0
        snapshot.batteryPower = 0
        snapshot.diagnostics.smc.deliveryRate = 60
        snapshot.diagnostics.smc.hasDeliveryRate = true

        XCTAssertTrue(snapshot.hasSystemPowerData)
        XCTAssertTrue(snapshot.isPowerBalanceConsistent)

        snapshot.systemLoadAvailable = true
        XCTAssertFalse(snapshot.isPowerBalanceConsistent)
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
        XCTAssertNil(resolved.load)
    }
}
