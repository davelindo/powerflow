import XCTest
@testable import Powerflow

final class BatteryHealthTests: XCTestCase {
    func testResolvedBatteryHealthPrefersAppleSmartBatteryPercent() throws {
        var smc = SMCPowerData.empty
        smc.hasFullChargeCapacity = true
        smc.hasDesignCapacity = true
        smc.fullChargeCapacity = 5_393
        smc.designCapacity = 6_249

        var batteryInfo = BatteryInfo.empty
        batteryInfo.maximumCapacityPercent = 84
        batteryInfo.nominalChargeCapacity = 5_162
        batteryInfo.designCapacity = 6_249

        let health = try XCTUnwrap(
            MacPowerDataProvider.resolvedBatteryHealthPercent(
                smc: smc,
                batteryInfo: batteryInfo,
                profilerMaximumCapacityPercent: 83
            )
        )

        XCTAssertEqual(health, 84, accuracy: 0.0001)
    }

    func testResolvedBatteryHealthPrefersSystemProfilerCapacityWhenBatteryPercentIsUnavailable() throws {
        var smc = SMCPowerData.empty
        smc.hasFullChargeCapacity = true
        smc.hasDesignCapacity = true
        smc.fullChargeCapacity = 5_393
        smc.designCapacity = 6_249

        var batteryInfo = BatteryInfo.empty
        batteryInfo.nominalChargeCapacity = 5_162
        batteryInfo.designCapacity = 6_249

        let health = try XCTUnwrap(
            MacPowerDataProvider.resolvedBatteryHealthPercent(
                smc: smc,
                batteryInfo: batteryInfo,
                profilerMaximumCapacityPercent: 84
            )
        )

        XCTAssertEqual(health, 84, accuracy: 0.0001)
    }

    func testResolvedBatteryHealthFallsBackToAppleSmartBatteryNominalCapacity() throws {
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
                batteryInfo: batteryInfo,
                profilerMaximumCapacityPercent: nil
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

    func testBatteryHealthProfilerParsesSystemInformationMaximumCapacity() throws {
        let json = """
        {
          "SPPowerDataType": [
            {
              "_name": "spbattery_information",
              "sppower_battery_health_info": {
                "sppower_battery_cycle_count": 269,
                "sppower_battery_health": "Good",
                "sppower_battery_health_maximum_capacity": "84%"
              }
            }
          ]
        }
        """

        let health = try XCTUnwrap(
            BatteryHealthProfilerReader.maximumCapacityPercent(
                from: Data(json.utf8)
            )
        )

        XCTAssertEqual(health, 84, accuracy: 0.0001)
    }

    func testBatteryHealthProfilerParsesNumericMaximumCapacity() throws {
        let json = """
        {
          "SPPowerDataType": [
            {
              "sppower_battery_health_maximum_capacity": 83
            }
          ]
        }
        """

        let health = try XCTUnwrap(
            BatteryHealthProfilerReader.maximumCapacityPercent(
                from: Data(json.utf8)
            )
        )

        XCTAssertEqual(health, 83, accuracy: 0.0001)
    }

    func testBatteryHealthProfilerRejectsMalformedJSON() {
        let health = BatteryHealthProfilerReader.maximumCapacityPercent(
            from: Data("{".utf8)
        )

        XCTAssertNil(health)
    }

    func testBatteryHealthProfilerReturnsNilForNonZeroExit() {
        let reader = BatteryHealthProfilerReader(profilerPath: "/usr/bin/false", timeout: 1)

        XCTAssertNil(reader.readMaximumCapacityPercent())
    }
}
