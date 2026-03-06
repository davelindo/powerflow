import XCTest
@testable import Powerflow

final class PowerFormatterTests: XCTestCase {
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
        snapshot.batteryLevel = batteryLevel
        snapshot.batteryLevelPrecise = Double(batteryLevel)
        snapshot.temperatureC = temperatureC
        return snapshot
    }
}
