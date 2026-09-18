import Foundation
import SQLite3

actor PowerHistoryRepository {
    enum RepositoryError: LocalizedError {
        case applicationSupportUnavailable
        case incompatibleSchema(Int32)
        case sqlite(code: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                return "Application Support is unavailable."
            case let .incompatibleSchema(version):
                return "History database version \(version) is newer than this version of Powerflow."
            case let .sqlite(_, message):
                return "History database error: \(message)"
            }
        }

        var isCorruption: Bool {
            guard case let .sqlite(code, _) = self else { return false }
            return code == SQLITE_CORRUPT || code == SQLITE_NOTADB
        }
    }

    private final class DatabaseHandle: @unchecked Sendable {
        private(set) var pointer: OpaquePointer?

        init(_ pointer: OpaquePointer) {
            self.pointer = pointer
        }

        func close() {
            guard let pointer else { return }
            sqlite3_close(pointer)
            self.pointer = nil
        }

        deinit {
            close()
        }
    }

    private struct TimedValue {
        var value: Double?
        var timestamp: TimeInterval?

        mutating func update(_ newValue: Double?, at newTimestamp: TimeInterval) {
            guard let newValue, newValue.isFinite else { return }
            guard timestamp == nil || newTimestamp >= (timestamp ?? 0) else { return }
            value = newValue
            timestamp = newTimestamp
        }
    }

    private struct TimedInteger {
        var value: Int?
        var timestamp: TimeInterval?

        mutating func updateLatest(_ newValue: Int?, at newTimestamp: TimeInterval) {
            guard let newValue else { return }
            guard timestamp == nil || newTimestamp >= (timestamp ?? 0) else { return }
            value = newValue
            timestamp = newTimestamp
        }

        mutating func updateFirst(_ newValue: Int?, at newTimestamp: TimeInterval) {
            guard let newValue else { return }
            guard timestamp == nil || newTimestamp < (timestamp ?? .greatestFiniteMagnitude) else { return }
            value = newValue
            timestamp = newTimestamp
        }
    }

    private struct MinuteAggregate {
        var observedSeconds = 0.0
        var systemEnergyWs = 0.0
        var systemPeak = 0.0
        var adapterEnergyWs = 0.0
        var adapterPeak = 0.0
        var batteryEnergyWs = 0.0
        var screenEnergyWs = 0.0
        var screenSeconds = 0.0
        var packageEnergyWs = 0.0
        var packageSeconds = 0.0
        var temperatureValueSeconds = 0.0
        var temperatureSeconds = 0.0
        var temperaturePeak = 0.0
        var fanValueSeconds = 0.0
        var fanSeconds = 0.0
        var fanPeak = 0.0
        var externalSeconds = 0.0
        var chargingSeconds = 0.0
        var healthValueSeconds = 0.0
        var healthSeconds = 0.0
        var fullValueSeconds = 0.0
        var fullSeconds = 0.0
        var designValueSeconds = 0.0
        var designSeconds = 0.0
        var latestHealth = TimedValue()
        var latestFull = TimedValue()
        var latestDesign = TimedValue()
        var firstCycle = TimedInteger()
        var latestCycle = TimedInteger()

        mutating func add(
            previous: PowerHistoryObservation,
            current: PowerHistoryObservation,
            startFraction: Double,
            endFraction: Double,
            duration: TimeInterval,
            systemEnergyWs suppliedSystemEnergy: Double?
        ) {
            guard duration.isFinite, duration > 0 else { return }
            observedSeconds += duration

            let systemStart = Self.interpolate(previous.systemLoad, current.systemLoad, startFraction)
            let systemEnd = Self.interpolate(previous.systemLoad, current.systemLoad, endFraction)
            systemEnergyWs += suppliedSystemEnergy ?? Self.integral(systemStart, systemEnd, duration)
            systemPeak = max(systemPeak, max(systemStart, systemEnd))

            let adapterStart = Self.interpolate(previous.adapterInput, current.adapterInput, startFraction)
            let adapterEnd = Self.interpolate(previous.adapterInput, current.adapterInput, endFraction)
            adapterEnergyWs += Self.integral(adapterStart, adapterEnd, duration)
            adapterPeak = max(adapterPeak, max(adapterStart, adapterEnd))

            let batteryStart = Self.interpolate(previous.batteryPower, current.batteryPower, startFraction)
            let batteryEnd = Self.interpolate(previous.batteryPower, current.batteryPower, endFraction)
            batteryEnergyWs += Self.integral(batteryStart, batteryEnd, duration)

            Self.accumulateOptional(
                previous.screenPower,
                current.screenPower,
                startFraction: startFraction,
                endFraction: endFraction,
                duration: duration,
                valueSeconds: &screenEnergyWs,
                observedSeconds: &screenSeconds
            )
            Self.accumulateOptional(
                previous.packagePower,
                current.packagePower,
                startFraction: startFraction,
                endFraction: endFraction,
                duration: duration,
                valueSeconds: &packageEnergyWs,
                observedSeconds: &packageSeconds
            )
            Self.accumulateOptional(
                previous.temperatureC,
                current.temperatureC,
                startFraction: startFraction,
                endFraction: endFraction,
                duration: duration,
                valueSeconds: &temperatureValueSeconds,
                observedSeconds: &temperatureSeconds,
                peak: &temperaturePeak
            )
            Self.accumulateOptional(
                previous.fanPercent,
                current.fanPercent,
                startFraction: startFraction,
                endFraction: endFraction,
                duration: duration,
                valueSeconds: &fanValueSeconds,
                observedSeconds: &fanSeconds,
                peak: &fanPeak
            )
            Self.accumulateOptional(
                previous.batteryHealthPercent,
                current.batteryHealthPercent,
                startFraction: startFraction,
                endFraction: endFraction,
                duration: duration,
                valueSeconds: &healthValueSeconds,
                observedSeconds: &healthSeconds
            )
            Self.accumulateOptional(
                previous.fullChargeMAh,
                current.fullChargeMAh,
                startFraction: startFraction,
                endFraction: endFraction,
                duration: duration,
                valueSeconds: &fullValueSeconds,
                observedSeconds: &fullSeconds
            )
            Self.accumulateOptional(
                previous.designMAh,
                current.designMAh,
                startFraction: startFraction,
                endFraction: endFraction,
                duration: duration,
                valueSeconds: &designValueSeconds,
                observedSeconds: &designSeconds
            )

            let externalStart = previous.isExternalPowerConnected ? 1.0 : 0.0
            let externalEnd = current.isExternalPowerConnected ? 1.0 : 0.0
            externalSeconds += Self.integral(
                Self.interpolate(externalStart, externalEnd, startFraction),
                Self.interpolate(externalStart, externalEnd, endFraction),
                duration
            )
            let chargingStart = previous.isCharging ? 1.0 : 0.0
            let chargingEnd = current.isCharging ? 1.0 : 0.0
            chargingSeconds += Self.integral(
                Self.interpolate(chargingStart, chargingEnd, startFraction),
                Self.interpolate(chargingStart, chargingEnd, endFraction),
                duration
            )

            let previousTimestamp = previous.timestamp.timeIntervalSince1970
            let currentTimestamp = current.timestamp.timeIntervalSince1970
            let segmentStartTimestamp = previousTimestamp
                + ((currentTimestamp - previousTimestamp) * startFraction)
            let segmentEndTimestamp = previousTimestamp
                + ((currentTimestamp - previousTimestamp) * endFraction)
            let segmentReachedCurrent = endFraction >= 1 - .ulpOfOne
            latestHealth.update(
                segmentReachedCurrent ? current.batteryHealthPercent : previous.batteryHealthPercent,
                at: segmentEndTimestamp
            )
            latestFull.update(
                segmentReachedCurrent ? current.fullChargeMAh : previous.fullChargeMAh,
                at: segmentEndTimestamp
            )
            latestDesign.update(
                segmentReachedCurrent ? current.designMAh : previous.designMAh,
                at: segmentEndTimestamp
            )
            firstCycle.updateFirst(previous.cycleCount, at: segmentStartTimestamp)
            let cycleAtSegmentEnd = segmentReachedCurrent
                ? current.cycleCount
                : previous.cycleCount
            latestCycle.updateLatest(cycleAtSegmentEnd, at: segmentEndTimestamp)
        }

        private static func interpolate(_ start: Double, _ end: Double, _ fraction: Double) -> Double {
            start + ((end - start) * min(max(fraction, 0), 1))
        }

        private static func integral(_ start: Double, _ end: Double, _ duration: Double) -> Double {
            ((start + end) * 0.5) * duration
        }

        private static func accumulateOptional(
            _ previous: Double?,
            _ current: Double?,
            startFraction: Double,
            endFraction: Double,
            duration: Double,
            valueSeconds: inout Double,
            observedSeconds: inout Double
        ) {
            guard let previous, let current, previous.isFinite, current.isFinite else { return }
            let start = interpolate(previous, current, startFraction)
            let end = interpolate(previous, current, endFraction)
            valueSeconds += integral(start, end, duration)
            observedSeconds += duration
        }

        private static func accumulateOptional(
            _ previous: Double?,
            _ current: Double?,
            startFraction: Double,
            endFraction: Double,
            duration: Double,
            valueSeconds: inout Double,
            observedSeconds: inout Double,
            peak: inout Double
        ) {
            guard let previous, let current, previous.isFinite, current.isFinite else { return }
            let start = interpolate(previous, current, startFraction)
            let end = interpolate(previous, current, endFraction)
            valueSeconds += integral(start, end, duration)
            observedSeconds += duration
            peak = max(peak, max(start, end))
        }
    }

    private static let schemaVersion: Int32 = 2
    private static let retention: TimeInterval = 90 * 24 * 60 * 60
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let handle: DatabaseHandle
    private var pendingMinutes: [Int64: MinuteAggregate] = [:]
    private var lastObservation: PowerHistoryObservation?
    private var lastPrunedMinute: Int64?

    init(databaseURL: URL? = nil) throws {
        let resolvedURL = try databaseURL ?? Self.defaultDatabaseURL()
        try FileManager.default.createDirectory(
            at: resolvedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.handle = try Self.openOrResetDatabase(at: resolvedURL)
    }

    func record(observation: PowerHistoryObservation) throws {
        defer { lastObservation = observation }
        guard let previous = lastObservation else { return }
        integrate(previous: previous, current: observation)
        let currentMinute = Self.minute(containing: observation.timestamp)
        try flushPending(pruningAt: currentMinute) { $0 < currentMinute }
    }

    func flush() throws {
        try flushPending { _ in true }
    }

    func close() throws {
        try flush()
        handle.close()
    }

    func report(range: PowerReportRange, endingAt endDate: Date = Date()) throws -> PowerReportState {
        try flushPending(pruningAt: Self.minute(containing: endDate)) { _ in true }
        guard let database = handle.pointer else { return .empty(range: range) }

        let endMinuteExclusive = Self.minute(containing: endDate) + 60
        let startMinute = endMinuteExclusive - Int64(range.duration)
        let points = try reportPoints(
            start: startMinute,
            endExclusive: endMinuteExclusive,
            bucketSeconds: range.chartBucketSeconds,
            in: database
        )
        let summary = try reportSummary(
            start: startMinute,
            endExclusive: endMinuteExclusive,
            expectedSeconds: range.duration,
            in: database
        )
        return PowerReportState(
            range: range,
            points: points,
            summary: summary,
            isLoading: false,
            errorMessage: nil
        )
    }

    func storedMinuteCount() throws -> Int {
        try flush()
        guard let database = handle.pointer else { return 0 }
        let statement = try Self.prepare("SELECT COUNT(*) FROM minute_history", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func integrate(previous: PowerHistoryObservation, current: PowerHistoryObservation) {
        // Missing power is not zero power. Keeping the invalid observation as
        // the next baseline prevents interpolation across sensor outages.
        guard previous.hasValidSystemPower, current.hasValidSystemPower else { return }
        let wallDuration = current.timestamp.timeIntervalSince(previous.timestamp)
        let monotonicDuration: TimeInterval
        if previous.monotonicUptime > 0, current.monotonicUptime > 0 {
            monotonicDuration = current.monotonicUptime - previous.monotonicUptime
        } else {
            // Deterministic fixtures may omit uptime; production snapshots always provide it.
            monotonicDuration = wallDuration
        }

        guard monotonicDuration.isFinite,
              wallDuration.isFinite,
              monotonicDuration > 0,
              monotonicDuration <= PowerflowConstants.maxAppEnergyIntegrationInterval,
              wallDuration > 0,
              abs(wallDuration - monotonicDuration) <= max(2, monotonicDuration * 0.2) else {
            return
        }

        let totalSystemEnergyWs = current.systemEnergyDeltaWh.flatMap { energy -> Double? in
            let wattSeconds = energy * 3_600
            return wattSeconds.isFinite && wattSeconds >= 0 ? wattSeconds : nil
        }
        let startEpoch = previous.timestamp.timeIntervalSince1970
        let endEpoch = current.timestamp.timeIntervalSince1970
        var cursor = startEpoch

        while cursor < endEpoch {
            let minute = Int64(floor(cursor / 60)) * 60
            let segmentEnd = min(endEpoch, TimeInterval(minute + 60))
            let startFraction = (cursor - startEpoch) / wallDuration
            let endFraction = (segmentEnd - startEpoch) / wallDuration
            let duration = monotonicDuration * ((segmentEnd - cursor) / wallDuration)
            let suppliedEnergy = totalSystemEnergyWs.map { $0 * (duration / monotonicDuration) }
            var aggregate = pendingMinutes[minute] ?? MinuteAggregate()
            aggregate.add(
                previous: previous,
                current: current,
                startFraction: startFraction,
                endFraction: endFraction,
                duration: duration,
                systemEnergyWs: suppliedEnergy
            )
            pendingMinutes[minute] = aggregate
            cursor = segmentEnd
        }
    }

    private func flushPending(pruningAt requestedMinute: Int64? = nil, where shouldFlush: (Int64) -> Bool) throws {
        let minutes = pendingMinutes.keys.filter(shouldFlush).sorted()
        let pruneMinute = requestedMinute ?? minutes.last
        let shouldPrune = pruneMinute != nil && pruneMinute != lastPrunedMinute
        guard !minutes.isEmpty || shouldPrune, let database = handle.pointer else { return }

        try Self.execute("BEGIN IMMEDIATE TRANSACTION", in: database)
        do {
            for minute in minutes {
                guard let aggregate = pendingMinutes[minute], aggregate.observedSeconds > 0 else { continue }
                try Self.upsert(aggregate, minute: minute, in: database)
            }
            if shouldPrune, let pruneMinute {
                try prune(nowMinute: pruneMinute, in: database)
            }
            try Self.execute("COMMIT", in: database)
        } catch {
            try? Self.execute("ROLLBACK", in: database)
            throw error
        }
        if shouldPrune {
            lastPrunedMinute = pruneMinute
        }
        for minute in minutes {
            pendingMinutes.removeValue(forKey: minute)
        }
    }

    private func prune(nowMinute: Int64, in database: OpaquePointer) throws {
        let cutoff = nowMinute - Int64(Self.retention)
        let statement = try Self.prepare("DELETE FROM minute_history WHERE minute < ?", in: database)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cutoff)
        try Self.stepDone(statement, in: database)
    }

    private static func upsert(_ value: MinuteAggregate, minute: Int64, in database: OpaquePointer) throws {
        let sql = """
        INSERT INTO minute_history (
            minute, observed_seconds,
            system_energy_ws, system_peak,
            adapter_energy_ws, adapter_peak,
            battery_energy_ws,
            screen_energy_ws, screen_seconds,
            package_energy_ws, package_seconds,
            temperature_value_seconds, temperature_seconds, temperature_peak,
            fan_value_seconds, fan_seconds, fan_peak,
            external_seconds, charging_seconds,
            health_value_seconds, health_seconds,
            full_value_seconds, full_seconds,
            design_value_seconds, design_seconds,
            latest_health, latest_health_at,
            latest_full, latest_full_at,
            latest_design, latest_design_at,
            first_cycle, first_cycle_at,
            latest_cycle, latest_cycle_at
        ) VALUES (
            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
        )
        ON CONFLICT(minute) DO UPDATE SET
            observed_seconds = observed_seconds + excluded.observed_seconds,
            system_energy_ws = system_energy_ws + excluded.system_energy_ws,
            system_peak = MAX(system_peak, excluded.system_peak),
            adapter_energy_ws = adapter_energy_ws + excluded.adapter_energy_ws,
            adapter_peak = MAX(adapter_peak, excluded.adapter_peak),
            battery_energy_ws = battery_energy_ws + excluded.battery_energy_ws,
            screen_energy_ws = screen_energy_ws + excluded.screen_energy_ws,
            screen_seconds = screen_seconds + excluded.screen_seconds,
            package_energy_ws = package_energy_ws + excluded.package_energy_ws,
            package_seconds = package_seconds + excluded.package_seconds,
            temperature_value_seconds = temperature_value_seconds + excluded.temperature_value_seconds,
            temperature_seconds = temperature_seconds + excluded.temperature_seconds,
            temperature_peak = MAX(temperature_peak, excluded.temperature_peak),
            fan_value_seconds = fan_value_seconds + excluded.fan_value_seconds,
            fan_seconds = fan_seconds + excluded.fan_seconds,
            fan_peak = MAX(fan_peak, excluded.fan_peak),
            external_seconds = external_seconds + excluded.external_seconds,
            charging_seconds = charging_seconds + excluded.charging_seconds,
            health_value_seconds = health_value_seconds + excluded.health_value_seconds,
            health_seconds = health_seconds + excluded.health_seconds,
            full_value_seconds = full_value_seconds + excluded.full_value_seconds,
            full_seconds = full_seconds + excluded.full_seconds,
            design_value_seconds = design_value_seconds + excluded.design_value_seconds,
            design_seconds = design_seconds + excluded.design_seconds,
            latest_health = CASE WHEN excluded.latest_health_at IS NOT NULL
                AND (latest_health_at IS NULL OR excluded.latest_health_at >= latest_health_at)
                THEN excluded.latest_health ELSE latest_health END,
            latest_health_at = CASE WHEN latest_health_at IS NULL THEN excluded.latest_health_at
                WHEN excluded.latest_health_at IS NULL THEN latest_health_at
                ELSE MAX(latest_health_at, excluded.latest_health_at) END,
            latest_full = CASE WHEN excluded.latest_full_at IS NOT NULL
                AND (latest_full_at IS NULL OR excluded.latest_full_at >= latest_full_at)
                THEN excluded.latest_full ELSE latest_full END,
            latest_full_at = CASE WHEN latest_full_at IS NULL THEN excluded.latest_full_at
                WHEN excluded.latest_full_at IS NULL THEN latest_full_at
                ELSE MAX(latest_full_at, excluded.latest_full_at) END,
            latest_design = CASE WHEN excluded.latest_design_at IS NOT NULL
                AND (latest_design_at IS NULL OR excluded.latest_design_at >= latest_design_at)
                THEN excluded.latest_design ELSE latest_design END,
            latest_design_at = CASE WHEN latest_design_at IS NULL THEN excluded.latest_design_at
                WHEN excluded.latest_design_at IS NULL THEN latest_design_at
                ELSE MAX(latest_design_at, excluded.latest_design_at) END,
            first_cycle = CASE WHEN excluded.first_cycle_at IS NOT NULL
                AND (first_cycle_at IS NULL OR excluded.first_cycle_at < first_cycle_at)
                THEN excluded.first_cycle ELSE first_cycle END,
            first_cycle_at = CASE WHEN first_cycle_at IS NULL THEN excluded.first_cycle_at
                WHEN excluded.first_cycle_at IS NULL THEN first_cycle_at
                ELSE MIN(first_cycle_at, excluded.first_cycle_at) END,
            latest_cycle = CASE WHEN excluded.latest_cycle_at IS NOT NULL
                AND (latest_cycle_at IS NULL OR excluded.latest_cycle_at >= latest_cycle_at)
                THEN excluded.latest_cycle ELSE latest_cycle END,
            latest_cycle_at = CASE WHEN latest_cycle_at IS NULL THEN excluded.latest_cycle_at
                WHEN excluded.latest_cycle_at IS NULL THEN latest_cycle_at
                ELSE MAX(latest_cycle_at, excluded.latest_cycle_at) END
        """
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        bind(minute, to: statement, at: &index)
        bind(value.observedSeconds, to: statement, at: &index)
        bind(value.systemEnergyWs, to: statement, at: &index)
        bind(value.systemPeak, to: statement, at: &index)
        bind(value.adapterEnergyWs, to: statement, at: &index)
        bind(value.adapterPeak, to: statement, at: &index)
        bind(value.batteryEnergyWs, to: statement, at: &index)
        bind(value.screenEnergyWs, to: statement, at: &index)
        bind(value.screenSeconds, to: statement, at: &index)
        bind(value.packageEnergyWs, to: statement, at: &index)
        bind(value.packageSeconds, to: statement, at: &index)
        bind(value.temperatureValueSeconds, to: statement, at: &index)
        bind(value.temperatureSeconds, to: statement, at: &index)
        bind(value.temperaturePeak, to: statement, at: &index)
        bind(value.fanValueSeconds, to: statement, at: &index)
        bind(value.fanSeconds, to: statement, at: &index)
        bind(value.fanPeak, to: statement, at: &index)
        bind(value.externalSeconds, to: statement, at: &index)
        bind(value.chargingSeconds, to: statement, at: &index)
        bind(value.healthValueSeconds, to: statement, at: &index)
        bind(value.healthSeconds, to: statement, at: &index)
        bind(value.fullValueSeconds, to: statement, at: &index)
        bind(value.fullSeconds, to: statement, at: &index)
        bind(value.designValueSeconds, to: statement, at: &index)
        bind(value.designSeconds, to: statement, at: &index)
        bindOptional(value.latestHealth.value, to: statement, at: &index)
        bindOptional(value.latestHealth.timestamp, to: statement, at: &index)
        bindOptional(value.latestFull.value, to: statement, at: &index)
        bindOptional(value.latestFull.timestamp, to: statement, at: &index)
        bindOptional(value.latestDesign.value, to: statement, at: &index)
        bindOptional(value.latestDesign.timestamp, to: statement, at: &index)
        bindOptional(value.firstCycle.value, to: statement, at: &index)
        bindOptional(value.firstCycle.timestamp, to: statement, at: &index)
        bindOptional(value.latestCycle.value, to: statement, at: &index)
        bindOptional(value.latestCycle.timestamp, to: statement, at: &index)
        try stepDone(statement, in: database)
    }

    private func reportPoints(
        start: Int64,
        endExclusive: Int64,
        bucketSeconds: Int64,
        in database: OpaquePointer
    ) throws -> [PowerReportPoint] {
        let sql = """
        WITH ranged AS (
            SELECT *, (minute / ?) * ? AS bucket
            FROM minute_history
            WHERE minute >= ? AND minute < ? AND observed_seconds > 0
        ), aggregated AS (
            SELECT
                bucket,
                SUM(system_energy_ws) / NULLIF(SUM(observed_seconds), 0),
                SUM(adapter_energy_ws) / NULLIF(SUM(observed_seconds), 0),
                SUM(battery_energy_ws) / NULLIF(SUM(observed_seconds), 0),
                SUM(screen_energy_ws) / NULLIF(SUM(screen_seconds), 0),
                SUM(package_energy_ws) / NULLIF(SUM(package_seconds), 0),
                SUM(temperature_value_seconds) / NULLIF(SUM(temperature_seconds), 0),
                SUM(fan_value_seconds) / NULLIF(SUM(fan_seconds), 0),
                SUM(health_value_seconds) / NULLIF(SUM(health_seconds), 0),
                SUM(full_value_seconds) / NULLIF(SUM(full_seconds), 0),
                SUM(design_value_seconds) / NULLIF(SUM(design_seconds), 0)
            FROM ranged
            GROUP BY bucket
        )
        SELECT
            aggregated.*,
            (SELECT latest_cycle FROM ranged
             WHERE ranged.bucket = aggregated.bucket AND latest_cycle IS NOT NULL
             ORDER BY latest_cycle_at DESC LIMIT 1)
        FROM aggregated
        ORDER BY bucket ASC
        """
        let statement = try Self.prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, bucketSeconds)
        sqlite3_bind_int64(statement, 2, bucketSeconds)
        sqlite3_bind_int64(statement, 3, start)
        sqlite3_bind_int64(statement, 4, endExclusive)

        var points: [PowerReportPoint] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            points.append(
                PowerReportPoint(
                    timestamp: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                    systemLoad: sqlite3_column_double(statement, 1),
                    adapterInput: sqlite3_column_double(statement, 2),
                    batteryPower: sqlite3_column_double(statement, 3),
                    screenPower: Self.optionalDouble(statement, column: 4),
                    packagePower: Self.optionalDouble(statement, column: 5),
                    temperatureC: Self.optionalDouble(statement, column: 6),
                    fanPercent: Self.optionalDouble(statement, column: 7),
                    batteryHealthPercent: Self.optionalDouble(statement, column: 8),
                    fullChargeMAh: Self.optionalDouble(statement, column: 9),
                    designMAh: Self.optionalDouble(statement, column: 10),
                    cycleCount: Self.optionalInt(statement, column: 11)
                )
            )
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw Self.databaseError(database) }
        return points
    }

    private func reportSummary(
        start: Int64,
        endExclusive: Int64,
        expectedSeconds: TimeInterval,
        in database: OpaquePointer
    ) throws -> PowerReportSummary {
        let sql = """
        SELECT
            SUM(observed_seconds),
            SUM(system_energy_ws) / NULLIF(SUM(observed_seconds), 0),
            MAX(system_peak),
            SUM(system_energy_ws) / 3600.0,
            SUM(external_seconds) / NULLIF(SUM(observed_seconds), 0),
            SUM(temperature_value_seconds) / NULLIF(SUM(temperature_seconds), 0),
            MAX(CASE WHEN temperature_seconds > 0 THEN temperature_peak END)
        FROM minute_history
        WHERE minute >= ? AND minute < ? AND observed_seconds > 0
        """
        let statement = try Self.prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, start)
        sqlite3_bind_int64(statement, 2, endExclusive)
        guard sqlite3_step(statement) == SQLITE_ROW else { return .empty }

        let observedSeconds = sqlite3_column_double(statement, 0)
        let latest = try latestBatteryValues(start: start, endExclusive: endExclusive, in: database)
        let cycles = try cycleSummary(start: start, endExclusive: endExclusive, in: database)
        return PowerReportSummary(
            averageSystemLoad: sqlite3_column_double(statement, 1),
            peakSystemLoad: sqlite3_column_double(statement, 2),
            observedEnergyWh: sqlite3_column_double(statement, 3),
            externalPowerFraction: sqlite3_column_double(statement, 4),
            coverageFraction: min(max(observedSeconds / expectedSeconds, 0), 1),
            averageTemperatureC: Self.optionalDouble(statement, column: 5),
            peakTemperatureC: Self.optionalDouble(statement, column: 6),
            latestBatteryHealthPercent: latest.health,
            latestFullChargeMAh: latest.full,
            latestDesignMAh: latest.design,
            latestCycleCount: cycles.latest,
            cycleCountChange: cycles.resetDetected ? nil : cycles.first.flatMap { first in
                cycles.latest.map { $0 - first }
            },
            cycleCountResetDetected: cycles.resetDetected
        )
    }

    private func latestBatteryValues(
        start: Int64,
        endExclusive: Int64,
        in database: OpaquePointer
    ) throws -> (health: Double?, full: Double?, design: Double?) {
        let sql = """
        SELECT latest_health, latest_health_at, latest_full, latest_full_at,
               latest_design, latest_design_at
        FROM minute_history
        WHERE minute >= ? AND minute < ?
        ORDER BY minute DESC
        """
        let statement = try Self.prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, start)
        sqlite3_bind_int64(statement, 2, endExclusive)
        var health: (Double, Double)?
        var full: (Double, Double)?
        var design: (Double, Double)?
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW, health == nil || full == nil || design == nil {
            if let value = Self.optionalDouble(statement, column: 0),
               let timestamp = Self.optionalDouble(statement, column: 1),
               health == nil || timestamp > (health?.1 ?? 0) {
                health = (value, timestamp)
            }
            if let value = Self.optionalDouble(statement, column: 2),
               let timestamp = Self.optionalDouble(statement, column: 3),
               full == nil || timestamp > (full?.1 ?? 0) {
                full = (value, timestamp)
            }
            if let value = Self.optionalDouble(statement, column: 4),
               let timestamp = Self.optionalDouble(statement, column: 5),
               design == nil || timestamp > (design?.1 ?? 0) {
                design = (value, timestamp)
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw Self.databaseError(database) }
        return (health?.0, full?.0, design?.0)
    }

    private func cycleSummary(
        start: Int64,
        endExclusive: Int64,
        in database: OpaquePointer
    ) throws -> (first: Int?, latest: Int?, resetDetected: Bool) {
        let sql = """
        SELECT first_cycle, latest_cycle
        FROM minute_history
        WHERE minute >= ? AND minute < ?
          AND first_cycle IS NOT NULL AND latest_cycle IS NOT NULL
        ORDER BY COALESCE(first_cycle_at, latest_cycle_at) ASC
        """
        let statement = try Self.prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, start)
        sqlite3_bind_int64(statement, 2, endExclusive)
        var first: Int?
        var previous: Int?
        var latest: Int?
        var resetDetected = false
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let firstInMinute = Int(sqlite3_column_int64(statement, 0))
            let latestInMinute = Int(sqlite3_column_int64(statement, 1))
            first = first ?? firstInMinute
            if let previous, firstInMinute < previous {
                resetDetected = true
            }
            if latestInMinute < firstInMinute {
                resetDetected = true
            }
            previous = latestInMinute
            latest = latestInMinute
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw Self.databaseError(database) }
        return (first, latest, resetDetected)
    }

    private static func defaultDatabaseURL() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RepositoryError.applicationSupportUnavailable
        }
        return support
            .appendingPathComponent("Powerflow", isDirectory: true)
            .appendingPathComponent("history.sqlite3")
    }

    private static func openOrResetDatabase(at url: URL) throws -> DatabaseHandle {
        do {
            return try openConfiguredDatabase(at: url)
        } catch let error as RepositoryError where error.isCorruption {
            try quarantineDatabaseFiles(at: url)
            return try createFreshDatabase(at: url)
        }
    }

    private static func openConfiguredDatabase(at url: URL) throws -> DatabaseHandle {
        let handle = try openRawDatabase(at: url)
        guard let database = handle.pointer else { throw databaseError(nil) }
        do {
            try execute("PRAGMA busy_timeout=1500", in: database)
            let version = try userVersion(in: database)
            let hasLegacyTable = version == 0
                ? try tableExists("minute_history", in: database)
                : false
            if version == 1 || hasLegacyTable {
                handle.close()
                try removeDatabaseFiles(at: url)
                return try createFreshDatabase(at: url)
            }
            guard version <= schemaVersion else {
                throw RepositoryError.incompatibleSchema(version)
            }
            try configureAndCreateSchema(in: database)
            return handle
        } catch {
            handle.close()
            throw error
        }
    }

    private static func createFreshDatabase(at url: URL) throws -> DatabaseHandle {
        let handle = try openRawDatabase(at: url)
        guard let database = handle.pointer else { throw databaseError(nil) }
        do {
            try configureAndCreateSchema(in: database)
            return handle
        } catch {
            handle.close()
            throw error
        }
    }

    private static func configureAndCreateSchema(in database: OpaquePointer) throws {
        try execute("PRAGMA journal_mode=WAL", in: database)
        try execute("PRAGMA synchronous=NORMAL", in: database)
        try execute("PRAGMA busy_timeout=1500", in: database)
        try execute(schema, in: database)
        try execute("PRAGMA user_version=\(schemaVersion)", in: database)
    }

    private static func openRawDatabase(at url: URL) throws -> DatabaseHandle {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            let error = databaseError(database, fallbackCode: result)
            if let database { sqlite3_close(database) }
            throw error
        }
        return DatabaseHandle(database)
    }

    private static func removeDatabaseFiles(at url: URL) throws {
        let fileManager = FileManager.default
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
    }

    private static func quarantineDatabaseFiles(at url: URL) throws {
        let directory = url.deletingLastPathComponent()
            .appendingPathComponent("corrupt-\(UUID().uuidString)", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            try manager.moveItem(at: source, to: directory.appendingPathComponent(source.lastPathComponent))
        }
    }

    private static func tableExists(_ name: String, in database: OpaquePointer) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        _ = name.withCString { pointer in
            sqlite3_bind_text(statement, 1, pointer, -1, transient)
        }
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw databaseError(database)
    }

    private static func userVersion(in database: OpaquePointer) throws -> Int32 {
        let statement = try prepare("PRAGMA user_version", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError(database) }
        return sqlite3_column_int(statement, 0)
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS minute_history (
        minute INTEGER PRIMARY KEY,
        observed_seconds REAL NOT NULL,
        system_energy_ws REAL NOT NULL,
        system_peak REAL NOT NULL,
        adapter_energy_ws REAL NOT NULL,
        adapter_peak REAL NOT NULL,
        battery_energy_ws REAL NOT NULL,
        screen_energy_ws REAL NOT NULL,
        screen_seconds REAL NOT NULL,
        package_energy_ws REAL NOT NULL,
        package_seconds REAL NOT NULL,
        temperature_value_seconds REAL NOT NULL,
        temperature_seconds REAL NOT NULL,
        temperature_peak REAL NOT NULL,
        fan_value_seconds REAL NOT NULL,
        fan_seconds REAL NOT NULL,
        fan_peak REAL NOT NULL,
        external_seconds REAL NOT NULL,
        charging_seconds REAL NOT NULL,
        health_value_seconds REAL NOT NULL,
        health_seconds REAL NOT NULL,
        full_value_seconds REAL NOT NULL,
        full_seconds REAL NOT NULL,
        design_value_seconds REAL NOT NULL,
        design_seconds REAL NOT NULL,
        latest_health REAL,
        latest_health_at REAL,
        latest_full REAL,
        latest_full_at REAL,
        latest_design REAL,
        latest_design_at REAL,
        first_cycle INTEGER,
        first_cycle_at REAL,
        latest_cycle INTEGER,
        latest_cycle_at REAL
    );
    """

    private static func minute(containing date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / 60)) * 60
    }

    private static func execute(_ sql: String, in database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw RepositoryError.sqlite(code: sqlite3_errcode(database), message: message)
        }
    }

    private static func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(database)
        }
        return statement
    }

    private static func stepDone(_ statement: OpaquePointer, in database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(database) }
    }

    private static func databaseError(
        _ database: OpaquePointer?,
        fallbackCode: Int32 = SQLITE_ERROR
    ) -> RepositoryError {
        let code = database.map(sqlite3_errcode) ?? fallbackCode
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
        return .sqlite(code: code, message: message)
    }

    private static func optionalDouble(_ statement: OpaquePointer, column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, column)
    }

    private static func optionalInt(_ statement: OpaquePointer, column: Int32) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, column))
    }

    private static func bind(_ value: Double, to statement: OpaquePointer, at index: inout Int32) {
        sqlite3_bind_double(statement, index, value)
        index += 1
    }

    private static func bind(_ value: Int64, to statement: OpaquePointer, at index: inout Int32) {
        sqlite3_bind_int64(statement, index, value)
        index += 1
    }

    private static func bindOptional(_ value: Double?, to statement: OpaquePointer, at index: inout Int32) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
        index += 1
    }

    private static func bindOptional(_ value: Int?, to statement: OpaquePointer, at index: inout Int32) {
        if let value {
            sqlite3_bind_int64(statement, index, Int64(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
        index += 1
    }
}
