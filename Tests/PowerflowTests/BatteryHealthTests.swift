import XCTest
@testable import Powerflow

final class BatteryHealthTests: XCTestCase {
    func testResolvedBatteryHealthPrefersAppleSmartBatteryNominalCapacity() throws {
        var smc = SMCPowerData.empty
        smc.hasFullChargeCapacity = true
        smc.hasDesignCapacity = true
        smc.fullChargeCapacity = 5_393
        smc.designCapacity = 6_249

        var batteryInfo = BatteryInfo.empty
        batteryInfo.nominalChargeCapacity = 5_545
        batteryInfo.designCapacity = 6_249

        let health = try XCTUnwrap(
            MacPowerDataProvider.resolvedBatteryHealthPercent(
                smc: smc,
                batteryInfo: batteryInfo
            )
        )
        let nominalChargeCapacity = try XCTUnwrap(batteryInfo.nominalChargeCapacity)
        let designCapacity = try XCTUnwrap(batteryInfo.designCapacity)
        let expectedHealth = (Double(nominalChargeCapacity) / Double(designCapacity)) * 100.0

        XCTAssertEqual(health, expectedHealth, accuracy: 0.0001)
    }

    func testResolvedBatteryHealthFallsBackToSmcWhenBatteryServiceValueIsUnavailable() throws {
        var smc = SMCPowerData.empty
        smc.hasFullChargeCapacity = true
        smc.hasDesignCapacity = true
        smc.fullChargeCapacity = 5_393
        smc.designCapacity = 6_249

        let health = try XCTUnwrap(
            MacPowerDataProvider.resolvedBatteryHealthPercent(
                smc: smc,
                batteryInfo: .empty
            )
        )
        let expectedHealth = (smc.fullChargeCapacity / smc.designCapacity) * 100.0

        XCTAssertEqual(health, expectedHealth, accuracy: 0.0001)
    }
}
