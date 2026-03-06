import Foundation
import XCTest
@testable import Powerflow

final class PowerSettingsStoreTests: XCTestCase {
    private let suiteName = "PowerflowTests.PowerSettingsStoreTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testLoadClampsPersistedValuesAndWritesBackNormalizedSettings() throws {
        defaults.set(try legacySettingsData(updateIntervalSeconds: 0.25), forKey: "powerflow.settings")

        let store = PowerSettingsStore(defaults: defaults)
        let loaded = store.load()

        XCTAssertEqual(loaded.updateIntervalSeconds, PowerSettings.minimumUpdateInterval)
        XCTAssertEqual(loaded.statusBarFormat, "{power}")

        let persistedData = try XCTUnwrap(defaults.data(forKey: "powerflow.settings"))
        let persisted = try JSONDecoder().decode(PowerSettings.self, from: persistedData)
        XCTAssertEqual(persisted, loaded)
    }

    private func legacySettingsData(updateIntervalSeconds: Double) throws -> Data {
        let payload = """
        {
          "updateIntervalSeconds": \(updateIntervalSeconds),
          "statusBarItem": "system",
          "showChargingPower": true,
          "launchAtLogin": false,
          "statusBarFormat": "{power}",
          "statusBarIcon": "bolt",
          "chargingMode": "sail",
          "chargeLimitPercent": 90,
          "sailingLowerPercent": 70,
          "sailingUpperPercent": 80,
          "heatProtectionEnabled": true,
          "heatProtectionMaxTempC": 45,
          "forceDischargeFirst": true
        }
        """
        return Data(payload.utf8)
    }
}
