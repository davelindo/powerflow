import XCTest
@testable import Powerflow

final class PowerFormatterTests: XCTestCase {
    func testUnavailableSystemLoadIsNotDisplayedAsMeasuredZero() {
        var settings = PowerSettings.default
        settings.statusBarItem = .system
        settings.showChargingPower = false
        var snapshot = PowerSnapshot.empty
        XCTAssertEqual(PowerFormatter.displayPowerString(snapshot: snapshot, settings: settings), "--")
        snapshot.systemLoadAvailable = true
        XCTAssertEqual(PowerFormatter.displayPowerString(snapshot: snapshot, settings: settings), "0W")
    }

    func testWattsStringNormalizesNegativeZeroAndRejectsNonFiniteValues() {
        XCTAssertEqual(PowerFormatter.wattsString(-0.001), "0W")
        XCTAssertEqual(PowerFormatter.wattsString(.infinity), "--")
    }

    func testEnergyStringKeepsSmallTenMinuteTotalsReadable() {
        XCTAssertEqual(PowerFormatter.energyString(0), "0mWh")
        XCTAssertEqual(PowerFormatter.energyString(0.0004), "<1mWh")
        XCTAssertEqual(PowerFormatter.energyString(0.008), "8.0mWh")
        XCTAssertEqual(PowerFormatter.energyString(0.125), "125mWh")
        XCTAssertEqual(PowerFormatter.energyString(1.25), "1.25Wh")
        XCTAssertEqual(PowerFormatter.energyString(.infinity), "--")
    }

    func testStatusTitleFallsBackToDefaultFormatWhenSettingsFormatIsBlank() {
        var settings = PowerSettings.default
        settings.statusBarFormat = "   "

        let snapshot = makeSnapshot(systemIn: 62, batteryLevel: 84)

        XCTAssertEqual(
            PowerFormatter.statusTitle(snapshot: snapshot, settings: settings),
            "48W | 84%"
        )
    }

    func testStatusTitleCollapsesDoubleSpacesAfterTokenReplacement() {
        var settings = PowerSettings.default
        settings.statusBarFormat = "{power}  {temp}"

        let snapshot = makeSnapshot(systemLoad: 42, batteryLevel: 55, temperatureC: 36.5)

        XCTAssertEqual(
            PowerFormatter.statusTitle(snapshot: snapshot, settings: settings),
            "42W 36.5 C"
        )
    }

    private func makeSnapshot(
        systemIn: Double = 48,
        systemLoad: Double = 48,
        batteryLevel: Int = 80,
        temperatureC: Double = 0
    ) -> PowerSnapshot {
        var snapshot = PowerSnapshot.empty
        snapshot.systemIn = systemIn
        snapshot.systemLoad = systemLoad
        snapshot.systemLoadAvailable = true
        snapshot.batteryLevel = batteryLevel
        snapshot.batteryLevelPrecise = Double(batteryLevel)
        snapshot.temperatureC = temperatureC
        return snapshot
    }
}
