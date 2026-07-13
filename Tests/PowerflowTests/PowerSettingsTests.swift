import XCTest
@testable import Powerflow

final class PowerSettingsTests: XCTestCase {
    func testBackgroundApplicationEnergyUsesDedicatedFiveSecondCadence() {
        var settings = PowerSettings.default

        XCTAssertEqual(
            PowerMonitor.resolvedInterval(settings, isPopoverVisible: false, isWarmup: false),
            5
        )
        XCTAssertEqual(
            PowerMonitor.resolvedInterval(settings, isPopoverVisible: true, isWarmup: false),
            settings.updateIntervalSeconds
        )

        settings.showAppEnergyOffenders = false
        XCTAssertEqual(
            PowerMonitor.resolvedInterval(settings, isPopoverVisible: false, isWarmup: false),
            10
        )
    }

    @MainActor
    func testTenMinuteAppImpactIntegratesEnergyAndKeepsUnallocatedRemainder() throws {
        let now = Date()
        let editor = AppEnergyOffender(
            groupID: "com.example.editor",
            primaryPID: 101,
            name: "Editor",
            iconPath: nil,
            processCount: 1,
            impactScore: 10,
            cpuPercent: 8,
            memoryBytes: 256_000_000,
            pageinsPerSecond: 0.1,
            activityShare: 0.4,
            estimatedPowerWatts: 1.44,
            estimatedEnergyWh: 0.004,
            sampleDurationSeconds: 10
        )
        let browser = AppEnergyOffender(
            groupID: "com.example.browser",
            primaryPID: 102,
            name: "Browser",
            iconPath: nil,
            processCount: 1,
            impactScore: 10,
            cpuPercent: 12,
            memoryBytes: 512_000_000,
            pageinsPerSecond: 0.2,
            activityShare: 0.3,
            estimatedPowerWatts: 1.08,
            estimatedEnergyWh: 0.003,
            sampleDurationSeconds: 10
        )
        let cachedEditor = AppEnergyOffender(
            groupID: editor.groupID,
            primaryPID: editor.primaryPID,
            name: editor.name,
            iconPath: editor.iconPath,
            processCount: editor.processCount,
            impactScore: editor.impactScore,
            cpuPercent: editor.cpuPercent,
            memoryBytes: editor.memoryBytes,
            pageinsPerSecond: editor.pageinsPerSecond,
            activityShare: editor.activityShare,
            estimatedPowerWatts: editor.estimatedPowerWatts
        )

        let rows = AppState.makeAppImpactRows(
            from: [
                AppImpactSample(timestamp: now.addingTimeInterval(-10), offenders: [editor, browser]),
                AppImpactSample(timestamp: now.addingTimeInterval(-5), offenders: [cachedEditor]),
                AppImpactSample(timestamp: now, offenders: [editor]),
            ]
        )

        XCTAssertEqual(rows.map(\.name), ["Editor", "Browser"])
        XCTAssertEqual(try XCTUnwrap(rows.first?.sharePercent), 40, accuracy: 0.01)
        XCTAssertEqual(rows.first?.shareText, "40%")
        XCTAssertEqual(try XCTUnwrap(rows.first?.energyWattHours), 0.008, accuracy: 0.000_001)
        XCTAssertEqual(rows.first?.energyText, "8.0mWh")
        XCTAssertEqual(try XCTUnwrap(rows[1].energyWattHours), 0.003, accuracy: 0.000_001)
        XCTAssertEqual(rows[1].shareText, "15%")
        XCTAssertTrue(rows[1].detailText.contains("Active 33%"))
    }

    func testProcessCPUTimeConvertsMachTicksToPercent() throws {
        let nanosecondsPerTick = 125.0 / 3.0
        let ticksForTwoCPUSeconds = UInt64(2_000_000_000 / nanosecondsPerTick)

        let percent = try XCTUnwrap(
            AppEnergyMonitor.cpuPercent(
                currentTicks: ticksForTwoCPUSeconds,
                previousTicks: 0,
                elapsed: 2,
                nanosecondsPerTick: nanosecondsPerTick
            )
        )

        XCTAssertEqual(percent, 100, accuracy: 0.001)
    }

    func testIdleThreadCountDoesNotCreatePhantomImpact() {
        XCTAssertEqual(
            AppEnergyMonitor.impactScore(cpuPercent: 0, pageinsPerSecond: 0),
            0
        )
    }

    func testLegacyStoredOffenderDecodesWithoutPowerEstimate() throws {
        let payload = """
        {
          "groupID": "com.example.legacy",
          "primaryPID": 42,
          "name": "Legacy",
          "iconPath": null,
          "processCount": 1,
          "impactScore": 2.5,
          "cpuPercent": 2.5,
          "memoryBytes": 1024,
          "pageinsPerSecond": 0
        }
        """

        let offender = try JSONDecoder().decode(AppEnergyOffender.self, from: Data(payload.utf8))

        XCTAssertNil(offender.activityShare)
        XCTAssertNil(offender.estimatedPowerWatts)
        XCTAssertNil(offender.estimatedEnergyWh)
        XCTAssertNil(offender.sampleDurationSeconds)
    }

    func testPowerIntegrationUsesElapsedTimeAndBothEndpoints() throws {
        let energy = try XCTUnwrap(
            MacPowerDataProvider.integratedEnergyWh(
                previousWatts: 4,
                currentWatts: 12,
                duration: 10
            )
        )

        XCTAssertEqual(energy, 8 * 10 / 3_600, accuracy: 0.000_000_1)
        XCTAssertNil(
            MacPowerDataProvider.integratedEnergyWh(
                previousWatts: 4,
                currentWatts: 12,
                duration: PowerflowConstants.maxAppEnergyIntegrationInterval + 1
            )
        )
    }

    func testEstimatedEnergyUsesIntervalBudgetAndKeepsUnlistedRemainder() throws {
        let foreground = AppEnergyOffender(
            groupID: "foreground",
            primaryPID: 10,
            name: "Foreground",
            iconPath: nil,
            processCount: 1,
            impactScore: 60,
            cpuPercent: 60,
            memoryBytes: 1,
            pageinsPerSecond: 0,
            activityShare: 0.6
        )
        let background = AppEnergyOffender(
            groupID: "background",
            primaryPID: 11,
            name: "Background",
            iconPath: nil,
            processCount: 1,
            impactScore: 25,
            cpuPercent: 25,
            memoryBytes: 1,
            pageinsPerSecond: 0,
            activityShare: 0.25
        )

        let attributed = MacPowerDataProvider.attributingEstimatedEnergy(
            to: [foreground, background],
            energyBudgetWh: 0.02,
            duration: 10
        )

        XCTAssertEqual(try XCTUnwrap(attributed[0].estimatedEnergyWh), 0.012, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(attributed[1].estimatedEnergyWh), 0.005, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(attributed[0].estimatedPowerWatts), 4.32, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(attributed[0].sampleDurationSeconds), 10, accuracy: 0.001)
        XCTAssertLessThan(
            attributed.compactMap(\.estimatedEnergyWh).reduce(0, +),
            0.02
        )
    }

    func testEstimatedPowerUsesMeasuredBudgetAndKeepsUnlistedRemainder() throws {
        let foreground = AppEnergyOffender(
            groupID: "foreground",
            primaryPID: 10,
            name: "Foreground",
            iconPath: nil,
            processCount: 1,
            impactScore: 60,
            cpuPercent: 60,
            memoryBytes: 1,
            pageinsPerSecond: 0,
            activityShare: 0.6
        )
        let background = AppEnergyOffender(
            groupID: "background",
            primaryPID: 11,
            name: "Background",
            iconPath: nil,
            processCount: 1,
            impactScore: 25,
            cpuPercent: 25,
            memoryBytes: 1,
            pageinsPerSecond: 0,
            activityShare: 0.25
        )

        let attributed = MacPowerDataProvider.attributingEstimatedPower(
            to: [foreground, background],
            systemLoad: 20,
            screenPower: 4,
            packagePower: nil
        )

        XCTAssertEqual(try XCTUnwrap(attributed[0].estimatedPowerWatts), 9.6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(attributed[1].estimatedPowerWatts), 4, accuracy: 0.001)
        XCTAssertLessThan(
            attributed.compactMap(\.estimatedPowerWatts).reduce(0, +),
            16
        )
    }

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
