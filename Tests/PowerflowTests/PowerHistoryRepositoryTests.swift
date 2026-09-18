import Foundation
import SQLite3
import XCTest
@testable import Powerflow

final class PowerHistoryRepositoryTests: XCTestCase {
    @MainActor
    func testChangingRangePreservesRepositoryInitializationFailure() async {
        let report = PowerReportState(
            range: .day, points: [], summary: .empty, isLoading: false,
            errorMessage: "History database is unavailable"
        )
        let state = AppState.snapshotTesting(settings: .default, snapshot: .empty, history: [], report: report)
        state.isPopoverVisible = true
        state.selectReportRange(.week)

        XCTAssertEqual(state.popoverStore.state.report.range, .week)
        XCTAssertEqual(state.popoverStore.state.report.errorMessage, report.errorMessage)
        XCTAssertFalse(state.popoverStore.state.report.isLoading)
        await state.shutdown()
    }

    func testPartialTelemetryRecordsAvailableLoadInsteadOfZero() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let resolved = MacPowerDataProvider.resolvedSystemPower(
            smc: .empty, telemetrySystemIn: nil, telemetrySystemLoad: 36, adapterInputPower: nil
        )
        var sample = PowerSnapshot.empty
        sample.systemLoad = resolved.load ?? 0
        sample.systemLoadAvailable = resolved.load != nil
        for index in 0...1 {
            sample.timestamp = base.addingTimeInterval(Double(index * 10))
            sample.monotonicUptime = Double(100 + index * 10)
            try await fixture.repository.record(observation: PowerHistoryObservation(snapshot: sample))
        }
        let report = try await fixture.repository.report(range: .hour, endingAt: sample.timestamp)
        XCTAssertEqual(report.summary.observedEnergyWh, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(report.summary.averageSystemLoad, 36, accuracy: 0.001)
        XCTAssertEqual(report.summary.coverageFraction, 10.0 / 3_600, accuracy: 0.000_001)
        try await fixture.repository.close()
    }

    func testRawSensorPresenceDoesNotValidateAnUnavailableResolvedLoad() {
        var sample = PowerSnapshot.empty
        sample.diagnostics.smc.hasSystemTotal = true
        XCTAssertFalse(PowerHistoryObservation(snapshot: sample).hasValidSystemPower)
        sample.systemLoadAvailable = true
        XCTAssertTrue(PowerHistoryObservation(snapshot: sample).hasValidSystemPower)
    }

    func testReportPrunesExpiredRowsWithoutFreshTelemetry() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try await fixture.repository.record(observation: observation(at: base, uptime: 100, systemLoad: 36))
        try await fixture.repository.record(observation: observation(at: base.addingTimeInterval(10), uptime: 110, systemLoad: 36))
        try await fixture.repository.close()

        let reopened = try PowerHistoryRepository(databaseURL: fixture.directory.appendingPathComponent("history.sqlite3"))
        _ = try await reopened.report(range: .quarter, endingAt: base.addingTimeInterval(100 * 86_400))
        let count = try await reopened.storedMinuteCount()
        XCTAssertEqual(count, 0)
        try await reopened.close()
    }

    func testFailedRetentionDeleteCanRetryInTheSameMinute() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try await fixture.repository.record(observation: observation(at: base, uptime: 100, systemLoad: 36))
        try await fixture.repository.record(observation: observation(at: base.addingTimeInterval(10), uptime: 110, systemLoad: 36))
        try await fixture.repository.flush()

        var database: OpaquePointer?
        let databaseURL = fixture.directory.appendingPathComponent("history.sqlite3")
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, """
            CREATE TRIGGER fail_retention BEFORE DELETE ON minute_history
            BEGIN SELECT RAISE(ABORT, 'injected retention failure'); END;
            """, nil, nil, nil), SQLITE_OK)
        let end = base.addingTimeInterval(100 * 86_400)
        do {
            _ = try await fixture.repository.report(range: .quarter, endingAt: end)
            XCTFail("The injected delete failure should be reported")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("injected retention failure"))
        }
        XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER fail_retention", nil, nil, nil), SQLITE_OK)
        _ = try await fixture.repository.report(range: .quarter, endingAt: end)
        let count = try await fixture.repository.storedMinuteCount()
        XCTAssertEqual(count, 0)
        try await fixture.repository.close()
    }

    func testCounterCatchUpDoesNotCountFallbackEnergyTwice() async throws {
        for stalledIntervals in [1, 2] {
            let fixture = try makeRepository()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            var calibrator = SystemEnergyCounterCalibrator()
            for index in 0...12 {
                _ = calibrator.energyDeltaWh(
                    rawCounter: UInt64(index * 100), systemLoadWatts: 36, uptime: Double(index * 10)
                )
            }
            XCTAssertTrue(calibrator.isValidated)
            for index in 0...(stalledIntervals + 1) {
                let uptime = Double(120 + index * 10)
                let raw = UInt64(index <= stalledIntervals ? 1_200 : (12 + index) * 100)
                let energy = index == 0 ? nil : calibrator.energyDeltaWh(
                    rawCounter: raw, systemLoadWatts: 36, uptime: uptime
                )
                try await fixture.repository.record(observation: observation(
                    at: base.addingTimeInterval(Double(index * 10)), uptime: uptime,
                    systemLoad: 36, systemEnergyDeltaWh: energy
                ))
            }
            let report = try await fixture.repository.report(
                range: .hour, endingAt: base.addingTimeInterval(40)
            )
            XCTAssertEqual(report.summary.observedEnergyWh, Double(stalledIntervals + 1) * 0.1, accuracy: 0.000_001)
            XCTAssertEqual(report.summary.averageSystemLoad, 36, accuracy: 0.001)
            try await fixture.repository.close()
        }
    }

    @MainActor
    func testDisplayRejectionDoesNotDiscardCounterEnergy() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let state = AppState.snapshotTesting(settings: .default, snapshot: .empty, history: [], repository: fixture.repository)
        var sample = PowerSnapshot.empty
        sample.timestamp = base
        sample.monotonicUptime = 100
        sample.systemLoad = 20
        sample.systemLoadAvailable = true
        sample.systemIn = 20
        sample.diagnostics.smc.hasSystemTotal = true
        state.apply(sample)
        sample.timestamp = base.addingTimeInterval(5)
        sample.monotonicUptime = 105
        sample.systemEnergyDeltaWh = 0.1
        sample.batteryPower = 50 // deliberately rejected by display smoothing
        state.apply(sample)
        XCTAssertEqual(state.snapshot.timestamp, base)
        sample.timestamp = base.addingTimeInterval(10)
        sample.monotonicUptime = 110
        sample.batteryPower = 0
        state.apply(sample)
        await state.shutdown()
        let reopened = try PowerHistoryRepository(databaseURL: fixture.directory.appendingPathComponent("history.sqlite3"))
        let report = try await reopened.report(range: .hour, endingAt: base.addingTimeInterval(15))
        XCTAssertEqual(report.summary.observedEnergyWh, 0.2, accuracy: 0.000001)
        XCTAssertEqual(report.summary.coverageFraction, 10.0 / 3600, accuracy: 0.000001)
        try await reopened.close()
    }

    func testUnavailablePowerBreaksCoverageButMeasuredZeroIsValid() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<5 {
            var sample = PowerSnapshot.empty
            sample.timestamp = base.addingTimeInterval(Double(index * 5))
            sample.monotonicUptime = 100 + Double(index * 5)
            sample.diagnostics.smc.hasSystemTotal = index != 2
            sample.systemLoadAvailable = index != 2
            try await fixture.repository.record(observation: PowerHistoryObservation(snapshot: sample))
        }
        let report = try await fixture.repository.report(range: .hour, endingAt: base.addingTimeInterval(25))
        XCTAssertEqual(report.summary.coverageFraction, 10.0 / 3600, accuracy: 0.000001)
        XCTAssertEqual(report.summary.observedEnergyWh, 0)
        XCTAssertNil(report.summary.averageTemperatureC)
        try await fixture.repository.close()
    }

    func testIntegratesElapsedTimeAcrossMinuteBoundaries() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        try await fixture.repository.record(
            observation: observation(at: base, uptime: 1_000, systemLoad: 20, adapterInput: 30, health: 90, cycles: 120)
        )
        try await fixture.repository.record(
            observation: observation(at: base.addingTimeInterval(20), uptime: 1_020, systemLoad: 40, adapterInput: 50, health: 88, cycles: 120)
        )
        try await fixture.repository.record(
            observation: observation(at: base.addingTimeInterval(70), uptime: 1_070, systemLoad: 10, adapterInput: 0, health: 88, cycles: 121)
        )

        let report = try await fixture.repository.report(range: .hour, endingAt: base.addingTimeInterval(90))

        XCTAssertEqual(report.points.count, 2)
        XCTAssertEqual(report.points[0].systemLoad, 1_720.0 / 60.0, accuracy: 0.001)
        XCTAssertEqual(report.points[1].systemLoad, 13, accuracy: 0.001)
        XCTAssertEqual(report.summary.averageSystemLoad, 1_850.0 / 70.0, accuracy: 0.001)
        XCTAssertEqual(report.summary.peakSystemLoad, 40, accuracy: 0.001)
        XCTAssertEqual(report.summary.observedEnergyWh, 1_850.0 / 3_600.0, accuracy: 0.000_001)
        XCTAssertEqual(report.summary.coverageFraction, 70.0 / 3_600.0, accuracy: 0.000_001)
        XCTAssertEqual(report.summary.latestCycleCount, 121)
        XCTAssertEqual(report.summary.cycleCountChange, 1)
        XCTAssertFalse(report.summary.cycleCountResetDetected)
        try await fixture.repository.close()
    }

    func testValidatedEnergyDeltaOverridesTrapezoidEstimate() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        try await fixture.repository.record(
            observation: observation(at: base, uptime: 100, systemLoad: 10)
        )
        try await fixture.repository.record(
            observation: observation(
                at: base.addingTimeInterval(10),
                uptime: 110,
                systemLoad: 10,
                systemEnergyDeltaWh: 0.2
            )
        )

        let report = try await fixture.repository.report(range: .hour, endingAt: base.addingTimeInterval(15))
        XCTAssertEqual(report.summary.observedEnergyWh, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(report.summary.averageSystemLoad, 72, accuracy: 0.001)
        try await fixture.repository.close()
    }

    func testRejectsSleepAndClockJumpIntervals() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        try await fixture.repository.record(
            observation: observation(at: base, uptime: 100, systemLoad: 10)
        )
        try await fixture.repository.record(
            observation: observation(at: base.addingTimeInterval(300), uptime: 105, systemLoad: 500)
        )
        try await fixture.repository.record(
            observation: observation(at: base.addingTimeInterval(305), uptime: 110, systemLoad: 20)
        )

        let report = try await fixture.repository.report(range: .hour, endingAt: base.addingTimeInterval(310))
        XCTAssertEqual(report.summary.coverageFraction, 5.0 / 3_600.0, accuracy: 0.000_001)
        XCTAssertEqual(report.summary.observedEnergyWh, 1_300.0 / 3_600.0, accuracy: 0.000_001)
        try await fixture.repository.close()
    }

    func testDetectsCycleCounterResetChronologically() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let cycles = [304, 305, 2, 3]

        for index in cycles.indices {
            try await fixture.repository.record(
                observation: observation(
                    at: base.addingTimeInterval(Double(index * 10)),
                    uptime: 1_000 + Double(index * 10),
                    systemLoad: 10,
                    cycles: cycles[index]
                )
            )
        }

        let report = try await fixture.repository.report(range: .hour, endingAt: base.addingTimeInterval(45))
        XCTAssertEqual(report.summary.latestCycleCount, 3)
        XCTAssertNil(report.summary.cycleCountChange)
        XCTAssertTrue(report.summary.cycleCountResetDetected)
        try await fixture.repository.close()
    }

    func testPrunesTelemetryOlderThanNinetyDays() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-91 * 24 * 60 * 60)

        try await fixture.repository.record(observation: observation(at: old, uptime: 100, systemLoad: 12))
        try await fixture.repository.record(
            observation: observation(at: old.addingTimeInterval(5), uptime: 105, systemLoad: 12)
        )
        try await fixture.repository.record(observation: observation(at: now, uptime: 1_000, systemLoad: 18))
        try await fixture.repository.record(
            observation: observation(at: now.addingTimeInterval(5), uptime: 1_005, systemLoad: 18)
        )

        let storedMinuteCount = try await fixture.repository.storedMinuteCount()
        XCTAssertEqual(storedMinuteCount, 1)
        try await fixture.repository.close()
    }

    func testRecoversOnlyFromCorruptDatabaseFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite3")
        try Data("not a database".utf8).write(to: databaseURL)

        let repository = try PowerHistoryRepository(databaseURL: databaseURL)
        let firstObservationAt = Self.minuteAligned(Date())
        try await repository.record(
            observation: observation(at: firstObservationAt, uptime: 100, systemLoad: 22)
        )
        try await repository.record(
            observation: observation(
                at: firstObservationAt.addingTimeInterval(5),
                uptime: 105,
                systemLoad: 22
            )
        )

        let storedMinuteCount = try await repository.storedMinuteCount()
        XCTAssertEqual(storedMinuteCount, 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains("history.sqlite3"))
        let quarantine = try XCTUnwrap(files.first { $0.hasPrefix("corrupt-") })
        let preserved = directory.appendingPathComponent(quarantine).appendingPathComponent("history.sqlite3")
        XCTAssertEqual(try Data(contentsOf: preserved), Data("not a database".utf8))
        try await repository.close()
    }

    func testResetsInaccurateVersionOneDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite3")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "CREATE TABLE minute_history (minute INTEGER PRIMARY KEY); PRAGMA user_version=1;",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(database)

        let repository = try PowerHistoryRepository(databaseURL: databaseURL)
        let firstObservationAt = Self.minuteAligned(Date())
        try await repository.record(
            observation: observation(at: firstObservationAt, uptime: 100, systemLoad: 12)
        )
        try await repository.record(
            observation: observation(
                at: firstObservationAt.addingTimeInterval(5),
                uptime: 105,
                systemLoad: 12
            )
        )
        let count = try await repository.storedMinuteCount()
        XCTAssertEqual(count, 1)
        try await repository.close()
    }

    func testDoesNotDeletePathForNonCorruptionOpenFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try PowerHistoryRepository(databaseURL: directory))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    private func makeRepository() throws -> (repository: PowerHistoryRepository, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = directory.appendingPathComponent("history.sqlite3")
        return (try PowerHistoryRepository(databaseURL: databaseURL), directory)
    }

    private static func minuteAligned(_ date: Date) -> Date {
        let epoch = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (epoch / 60).rounded(.down) * 60 + 1)
    }

    private func observation(
        at date: Date,
        uptime: TimeInterval,
        systemLoad: Double,
        adapterInput: Double = 25,
        health: Double = 89,
        cycles: Int = 120,
        systemEnergyDeltaWh: Double? = nil
    ) -> PowerHistoryObservation {
        var snapshot = PowerSnapshot.empty
        snapshot.timestamp = date
        snapshot.monotonicUptime = uptime
        snapshot.systemEnergyDeltaWh = systemEnergyDeltaWh
        snapshot.systemLoad = systemLoad
        snapshot.systemLoadAvailable = true
        snapshot.diagnostics.smc.hasSystemTotal = true
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
}
