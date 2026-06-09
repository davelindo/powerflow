import XCTest
@testable import Powerflow

final class PowerSettingsTests: XCTestCase {
    func testDecodingLegacyBatteryControlKeysPreservesSupportedSettings() throws {
        let payload = """
        {
          "updateIntervalSeconds": 2.5,
          "statusBarItem": "heatpipe",
          "showChargingPower": false,
          "launchAtLogin": true,
          "statusBarFormat": "{power} / {battery}",
          "statusBarIcon": "waveform",
          "chargingMode": "limit",
          "chargeLimitPercent": 80,
          "heatProtectionEnabled": true
        }
        """

        let settings = try JSONDecoder().decode(PowerSettings.self, from: Data(payload.utf8))

        XCTAssertEqual(settings.updateIntervalSeconds, 2.5)
        XCTAssertEqual(settings.statusBarItem, .heatpipe)
        XCTAssertFalse(settings.showChargingPower)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(settings.statusBarFormat, "{power} / {battery}")
        XCTAssertEqual(settings.statusBarIcon, .waveform)
        XCTAssertTrue(settings.showAppEnergyOffenders)
    }

    func testProcessActivitySettingPreservesExplicitFalse() throws {
        var settings = PowerSettings.default
        settings.showAppEnergyOffenders = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PowerSettings.self, from: data)

        XCTAssertFalse(decoded.showAppEnergyOffenders)
    }

    @MainActor
    func testDisablingProcessActivityClearsDisplayedOffenders() {
        var settings = PowerSettings.default
        settings.showAppEnergyOffenders = true

        var snapshot = PowerSnapshot.empty
        snapshot.appEnergyOffenders = [
            AppEnergyOffender(
                groupID: "com.example.editor",
                primaryPID: 101,
                name: "Editor",
                iconPath: nil,
                processCount: 1,
                impactScore: 12.4,
                cpuPercent: 8.0,
                memoryBytes: 256_000_000,
                pageinsPerSecond: 0.1
            )
        ]

        let appState = AppState.snapshotTesting(
            settings: settings,
            snapshot: snapshot,
            history: []
        )
        XCTAssertFalse(appState.popoverStore.state.history.offenders.isEmpty)

        appState.settings.showAppEnergyOffenders = false

        XCTAssertTrue(appState.snapshot.appEnergyOffenders.isEmpty)
        XCTAssertTrue(appState.popoverStore.state.history.offenders.isEmpty)
    }
}
