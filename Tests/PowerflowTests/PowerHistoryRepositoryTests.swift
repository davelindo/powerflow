import Foundation
import XCTest
@testable import Powerflow

final class PowerHistoryRepositoryTests: XCTestCase {
    func testAggregatesMinuteBucketsAndBuildsReportSummary() async throws {
        let fixture = try makeRepository()
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        try await fixture.repository.record(
            observation: observation(at: base, systemLoad: 20, adapterInput: 30, health: 90, cycles: 120),
            appImpact: nil
        )
        try await fixture.repository.record(
            observation: observation(at: base.addingTimeInterval(20), systemLoad: 40, adapterInput: 50, health: 88, cycles: 120),
            appImpact: nil
        )
        try await fixture.repository.record(
            observation: observation(at: base.addingTimeInterval(70), systemLoad: 10, adapterInput: 0, health: 88, cycles: 121),
            appImpact: nil
        )

        let report = try await fixture.repository.report(range: .hour, endingAt: base.addingTimeInterval(90))

        XCTAssertEqual(report.points.count, 2)
        XCTAssertEqual(report.points[0].systemLoad, 30, accuracy: 0.001)
        XCTAssertEqual(report.summary.averageSystemLoad, 70.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(report.summary.peakSystemLoad, 40, accuracy: 0.001)
        XCTAssertEqual(report.summary.observedEnergyWh, 40.0 / 60.0, accuracy: 0.001)
        XCTAssertEqual(report.summary.latestCycleCount, 121)
        XCTAssertEqual(report.summary.cycleCountChange, 1)
    }

    func testPrunesTelemetryOlderThanNinetyDays() async throws {
        let fixture = try makeRepository()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try await fixture.repository.record(
            observation: observation(at: now.addingTimeInterval(-91 * 24 * 60 * 60), systemLoad: 12),
            appImpact: nil
        )
        try await fixture.repository.record(
            observation: observation(at: now, systemLoad: 18),
            appImpact: nil
        )

        let storedMinuteCount = try await fixture.repository.storedMinuteCount()
        XCTAssertEqual(storedMinuteCount, 1)
    }

    func testRestoresOnlyRecentApplicationImpactSamples() async throws {
        let fixture = try makeRepository()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldSample = AppImpactSample(timestamp: now.addingTimeInterval(-700), offenders: [offender(name: "Old")])
        let recentSample = AppImpactSample(timestamp: now.addingTimeInterval(-60), offenders: [offender(name: "Recent")])

        try await fixture.repository.record(
            observation: observation(at: oldSample.timestamp, systemLoad: 8),
            appImpact: oldSample
        )
        try await fixture.repository.record(
            observation: observation(at: recentSample.timestamp, systemLoad: 9),
            appImpact: recentSample
        )

        let samples = try await fixture.repository.recentAppImpactSamples(endingAt: now)
        XCTAssertEqual(samples.flatMap(\.offenders).map(\.name), ["Recent"])
    }

    func testPersistsFreshApplicationEnergyWithoutTelemetryObservation() async throws {
        let fixture = try makeRepository()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let sample = AppImpactSample(
            timestamp: timestamp,
            offenders: [offender(name: "Background", energyWh: 0.004)]
        )

        try await fixture.repository.record(appImpact: sample)

        let restored = try await fixture.repository.recentAppImpactSamples(
            endingAt: timestamp.addingTimeInterval(1)
        )
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].offenders[0].estimatedEnergyWh, 0.004)
        let storedMinuteCount = try await fixture.repository.storedMinuteCount()
        XCTAssertEqual(storedMinuteCount, 0)
    }

    func testRecoversFromCorruptDatabaseFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("history.sqlite3")
        try Data("not a database".utf8).write(to: databaseURL)

        var repository: PowerHistoryRepository? = try PowerHistoryRepository(databaseURL: databaseURL)
        try await repository?.record(
            observation: observation(at: Date(), systemLoad: 22),
            appImpact: nil
        )

        let storedMinuteCount = try await repository?.storedMinuteCount()
        XCTAssertEqual(storedMinuteCount, 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.contains("corrupt-") })
        repository = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeRepository() throws -> (repository: PowerHistoryRepository, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = directory.appendingPathComponent("history.sqlite3")
        return (try PowerHistoryRepository(databaseURL: databaseURL), directory)
    }

    private func observation(
        at date: Date,
        systemLoad: Double,
        adapterInput: Double = 25,
        health: Double = 89,
        cycles: Int = 120
    ) -> PowerHistoryObservation {
        var snapshot = PowerSnapshot.empty
        snapshot.timestamp = date
        snapshot.systemLoad = systemLoad
        snapshot.systemIn = adapterInput
        snapshot.batteryPower = adapterInput - systemLoad
        snapshot.screenPower = 4
        snapshot.screenPowerAvailable = true
        snapshot.heatpipePower = systemLoad * 0.45
        snapshot.heatpipeKey = "PHPC"
        snapshot.temperatureC = 38
        snapshot.batteryHealthPercent = health
        snapshot.batteryCapacityDetails = BatteryCapacityDetails(
            remainingMAh: 4_200,
            fullChargeMAh: 5_500,
            designMAh: 6_200
        )
        snapshot.batteryCycleCountSMC = cycles
        snapshot.isExternalPowerConnected = adapterInput > 0
        return PowerHistoryObservation(snapshot: snapshot)
    }

    private func offender(name: String, energyWh: Double? = nil) -> AppEnergyOffender {
        AppEnergyOffender(
            groupID: name.lowercased(),
            primaryPID: 42,
            name: name,
            iconPath: nil,
            processCount: 1,
            impactScore: 12,
            cpuPercent: 10,
            memoryBytes: 100_000_000,
            pageinsPerSecond: 0,
            activityShare: 0.5,
            estimatedPowerWatts: energyWh.map { $0 * 3_600 / 5 },
            estimatedEnergyWh: energyWh,
            sampleDurationSeconds: energyWh == nil ? nil : 5
        )
    }
}
