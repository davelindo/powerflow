import XCTest
@testable import Powerflow

final class DetailedFlowStateTests: XCTestCase {
    func testChargingFlowConservesAdapterInput() {
        var snapshot = PowerSnapshot.empty
        snapshot.systemIn = 29
        snapshot.systemLoad = 20.5

        let flow = DetailedFlowState(snapshot: snapshot)

        XCTAssertEqual(flow.adapterToSystem, 20.5, accuracy: 0.001)
        XCTAssertEqual(flow.adapterToBattery, 8.5, accuracy: 0.001)
        XCTAssertEqual(flow.batteryToSystem, 0, accuracy: 0.001)
        XCTAssertEqual(flow.adapterSourceTotal, 29, accuracy: 0.001)
    }

    func testBatteryOnlyFlowSuppliesEntireSystemLoad() {
        var snapshot = PowerSnapshot.empty
        snapshot.systemIn = 0
        snapshot.systemLoad = 18

        let flow = DetailedFlowState(snapshot: snapshot)

        XCTAssertEqual(flow.adapterSourceTotal, 0, accuracy: 0.001)
        XCTAssertEqual(flow.batteryToSystem, 18, accuracy: 0.001)
        XCTAssertTrue(flow.hasBatterySource)
    }

    func testUnderpoweredAdapterShowsDualSources() {
        var snapshot = PowerSnapshot.empty
        snapshot.systemIn = 12
        snapshot.systemLoad = 20

        let flow = DetailedFlowState(snapshot: snapshot)

        XCTAssertEqual(flow.adapterToSystem, 12, accuracy: 0.001)
        XCTAssertEqual(flow.batteryToSystem, 8, accuracy: 0.001)
        XCTAssertTrue(flow.hasBatterySource)
    }

    func testMeasuredChannelsProduceClampedOtherRemainder() {
        var snapshot = PowerSnapshot.empty
        snapshot.systemLoad = 20.5
        snapshot.heatpipePower = 11.5
        snapshot.heatpipeKey = "PHPC"
        snapshot.screenPower = 4
        snapshot.screenPowerAvailable = true

        let flow = DetailedFlowState(snapshot: snapshot)

        XCTAssertEqual(flow.packagePower, 11.5)
        XCTAssertEqual(flow.displayPower, 4)
        XCTAssertEqual(flow.otherPower, 5, accuracy: 0.001)
    }

    func testContradictoryMeasuredChannelsCollapseIntoOther() {
        var snapshot = PowerSnapshot.empty
        snapshot.systemLoad = 20
        snapshot.heatpipePower = 18
        snapshot.heatpipeKey = "PHPC"
        snapshot.screenPower = 8
        snapshot.screenPowerAvailable = true

        let flow = DetailedFlowState(snapshot: snapshot)

        XCTAssertNil(flow.packagePower)
        XCTAssertNil(flow.displayPower)
        XCTAssertEqual(flow.otherPower, 20, accuracy: 0.001)
    }
}
