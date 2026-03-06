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
    }
}
