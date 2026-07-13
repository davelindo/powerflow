import Foundation
import SQLite3

actor PowerHistoryRepository {
    enum RepositoryError: LocalizedError {
        case applicationSupportUnavailable
        case sqlite(message: String)

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                return "Application Support is unavailable."
            case let .sqlite(message):
                return "History database error: \(message)"
            }
        }
    }

    private static let retention: TimeInterval = 90 * 24 * 60 * 60
    private static let appImpactRetention: TimeInterval = 10 * 60
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var database: OpaquePointer?
    private var lastPrunedMinute: Int64?

    init(databaseURL: URL? = nil) throws {
        let resolvedURL = try databaseURL ?? Self.defaultDatabaseURL()
        try FileManager.default.createDirectory(
            at: resolvedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        do {
            database = try Self.openDatabase(at: resolvedURL)
        } catch {
            let corruptURL = resolvedURL
                .deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).sqlite3")
            try? FileManager.default.moveItem(at: resolvedURL, to: corruptURL)
            database = try Self.openDatabase(at: resolvedURL)
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func record(observation: PowerHistoryObservation, appImpact: AppImpactSample?) throws {
        guard let database else { return }
        try performTransaction(in: database) {
            try upsert(observation, in: database)
            if let appImpact {
                try insert(appImpact, in: database)
            }
            try pruneIfNeeded(now: observation.timestamp, in: database)
        }
    }

    func record(appImpact: AppImpactSample) throws {
        guard let database else { return }
        try performTransaction(in: database) {
            try insert(appImpact, in: database)
            try pruneIfNeeded(now: appImpact.timestamp, in: database)
        }
    }

    private func performTransaction(
        in database: OpaquePointer,
        updates: () throws -> Void
    ) throws {
        try Self.execute("BEGIN IMMEDIATE TRANSACTION", in: database)
        do {
            try updates()
            try Self.execute("COMMIT", in: database)
        } catch {
            try? Self.execute("ROLLBACK", in: database)
            throw error
        }
    }

    func report(range: PowerReportRange, endingAt endDate: Date = Date()) throws -> PowerReportState {
        guard let database else { return .empty(range: range) }
        let end = Int64(endDate.timeIntervalSince1970)
        let start = Int64(endDate.addingTimeInterval(-range.duration).timeIntervalSince1970)
        let points = try reportPoints(
            start: start,
            end: end,
            bucketSeconds: range.chartBucketSeconds,
            in: database
        )
        let summary = try reportSummary(
            start: start,
            end: end,
            expectedMinutes: max(Int(range.duration / 60), 1),
            points: points,
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

    func recentAppImpactSamples(endingAt endDate: Date = Date()) throws -> [AppImpactSample] {
        guard let database else { return [] }
        let sql = """
        SELECT timestamp, payload
        FROM app_impact_samples
        WHERE timestamp >= ? AND timestamp <= ?
        ORDER BY timestamp ASC
        """
        let statement = try Self.prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, endDate.addingTimeInterval(-Self.appImpactRetention).timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, endDate.timeIntervalSince1970)

        let decoder = JSONDecoder()
        var samples: [AppImpactSample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            guard let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 1))
            let data = Data(bytes: bytes, count: count)
            guard let offenders = try? decoder.decode([AppEnergyOffender].self, from: data) else { continue }
            samples.append(AppImpactSample(timestamp: timestamp, offenders: offenders))
        }
        try Self.checkCompletion(of: statement, in: database)
        return samples
    }

    func clearAppImpact() throws {
        guard let database else { return }
        try Self.execute("DELETE FROM app_impact_samples", in: database)
    }

    func storedMinuteCount() throws -> Int {
        guard let database else { return 0 }
        let statement = try Self.prepare("SELECT COUNT(*) FROM minute_history", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func upsert(_ observation: PowerHistoryObservation, in database: OpaquePointer) throws {
        let sql = """
        INSERT INTO minute_history (
            minute, sample_count,
            system_sum, system_peak,
            adapter_sum, adapter_peak,
            battery_sum,
            screen_sum, screen_count,
            package_sum, package_count,
            temperature_sum, temperature_count, temperature_peak,
            fan_sum, fan_count, fan_peak,
            external_count, charging_count,
            health_sum, health_count,
            remaining_sum, remaining_count,
            full_sum, full_count,
            design_sum, design_count,
            cycle_min, cycle_max
        ) VALUES (
            ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
        )
        ON CONFLICT(minute) DO UPDATE SET
            sample_count = sample_count + 1,
            system_sum = system_sum + excluded.system_sum,
            system_peak = MAX(system_peak, excluded.system_peak),
            adapter_sum = adapter_sum + excluded.adapter_sum,
            adapter_peak = MAX(adapter_peak, excluded.adapter_peak),
            battery_sum = battery_sum + excluded.battery_sum,
            screen_sum = screen_sum + excluded.screen_sum,
            screen_count = screen_count + excluded.screen_count,
            package_sum = package_sum + excluded.package_sum,
            package_count = package_count + excluded.package_count,
            temperature_sum = temperature_sum + excluded.temperature_sum,
            temperature_count = temperature_count + excluded.temperature_count,
            temperature_peak = MAX(temperature_peak, excluded.temperature_peak),
            fan_sum = fan_sum + excluded.fan_sum,
            fan_count = fan_count + excluded.fan_count,
            fan_peak = MAX(fan_peak, excluded.fan_peak),
            external_count = external_count + excluded.external_count,
            charging_count = charging_count + excluded.charging_count,
            health_sum = health_sum + excluded.health_sum,
            health_count = health_count + excluded.health_count,
            remaining_sum = remaining_sum + excluded.remaining_sum,
            remaining_count = remaining_count + excluded.remaining_count,
            full_sum = full_sum + excluded.full_sum,
            full_count = full_count + excluded.full_count,
            design_sum = design_sum + excluded.design_sum,
            design_count = design_count + excluded.design_count,
            cycle_min = CASE
                WHEN excluded.cycle_min IS NULL THEN cycle_min
                WHEN cycle_min IS NULL THEN excluded.cycle_min
                ELSE MIN(cycle_min, excluded.cycle_min)
            END,
            cycle_max = CASE
                WHEN excluded.cycle_max IS NULL THEN cycle_max
                WHEN cycle_max IS NULL THEN excluded.cycle_max
                ELSE MAX(cycle_max, excluded.cycle_max)
            END
        """
        let statement = try Self.prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }

        let minute = Int64(observation.timestamp.timeIntervalSince1970 / 60) * 60
        var index: Int32 = 1
        Self.bind(minute, to: statement, at: &index)
        Self.bind(observation.systemLoad, to: statement, at: &index)
        Self.bind(observation.systemLoad, to: statement, at: &index)
        Self.bind(observation.adapterInput, to: statement, at: &index)
        Self.bind(observation.adapterInput, to: statement, at: &index)
        Self.bind(observation.batteryPower, to: statement, at: &index)
        Self.bindOptional(observation.screenPower, to: statement, at: &index)
        Self.bind(observation.screenPower == nil ? 0 : 1, to: statement, at: &index)
        Self.bindOptional(observation.packagePower, to: statement, at: &index)
        Self.bind(observation.packagePower == nil ? 0 : 1, to: statement, at: &index)
        Self.bindOptional(observation.temperatureC, to: statement, at: &index)
        Self.bind(observation.temperatureC == nil ? 0 : 1, to: statement, at: &index)
        Self.bindOptional(observation.temperatureC, to: statement, at: &index)
        Self.bindOptional(observation.fanPercent, to: statement, at: &index)
        Self.bind(observation.fanPercent == nil ? 0 : 1, to: statement, at: &index)
        Self.bindOptional(observation.fanPercent, to: statement, at: &index)
        Self.bind(observation.isExternalPowerConnected ? 1 : 0, to: statement, at: &index)
        Self.bind(observation.isCharging ? 1 : 0, to: statement, at: &index)
        Self.bindOptional(observation.batteryHealthPercent, to: statement, at: &index)
        Self.bind(observation.batteryHealthPercent == nil ? 0 : 1, to: statement, at: &index)
        Self.bindOptional(observation.remainingMAh, to: statement, at: &index)
        Self.bind(observation.remainingMAh == nil ? 0 : 1, to: statement, at: &index)
        Self.bindOptional(observation.fullChargeMAh, to: statement, at: &index)
        Self.bind(observation.fullChargeMAh == nil ? 0 : 1, to: statement, at: &index)
        Self.bindOptional(observation.designMAh, to: statement, at: &index)
        Self.bind(observation.designMAh == nil ? 0 : 1, to: statement, at: &index)
        Self.bindOptional(observation.cycleCount, to: statement, at: &index)
        Self.bindOptional(observation.cycleCount, to: statement, at: &index)

        try Self.stepDone(statement, in: database)
    }

    private func insert(_ sample: AppImpactSample, in database: OpaquePointer) throws {
        let payload = try JSONEncoder().encode(sample.offenders)
        let sql = "INSERT OR REPLACE INTO app_impact_samples (timestamp, payload) VALUES (?, ?)"
        let statement = try Self.prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, sample.timestamp.timeIntervalSince1970)
        _ = payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
        try Self.stepDone(statement, in: database)
    }

    private func pruneIfNeeded(now: Date, in database: OpaquePointer) throws {
        let minute = Int64(now.timeIntervalSince1970 / 60) * 60
        guard lastPrunedMinute != minute else { return }
        lastPrunedMinute = minute

        let historyCutoff = Int64(now.addingTimeInterval(-Self.retention).timeIntervalSince1970)
        let appCutoff = now.addingTimeInterval(-Self.appImpactRetention).timeIntervalSince1970
        try Self.execute("DELETE FROM minute_history WHERE minute < \(historyCutoff)", in: database)
        try Self.execute("DELETE FROM app_impact_samples WHERE timestamp < \(appCutoff)", in: database)
    }

    private func reportPoints(
        start: Int64,
        end: Int64,
        bucketSeconds: Int64,
        in database: OpaquePointer
    ) throws -> [PowerReportPoint] {
        let sql = """
        SELECT
            (minute / ?) * ? AS bucket,
            SUM(system_sum) / NULLIF(SUM(sample_count), 0),
            SUM(adapter_sum) / NULLIF(SUM(sample_count), 0),
            SUM(battery_sum) / NULLIF(SUM(sample_count), 0),
            SUM(screen_sum) / NULLIF(SUM(screen_count), 0),
            SUM(package_sum) / NULLIF(SUM(package_count), 0),
            SUM(temperature_sum) / NULLIF(SUM(temperature_count), 0),
            SUM(fan_sum) / NULLIF(SUM(fan_count), 0),
            SUM(health_sum) / NULLIF(SUM(health_count), 0),
            SUM(full_sum) / NULLIF(SUM(full_count), 0),
            SUM(design_sum) / NULLIF(SUM(design_count), 0),
            MAX(cycle_max)
        FROM minute_history
        WHERE minute >= ? AND minute <= ?
        GROUP BY bucket
        ORDER BY bucket ASC
        """
        let statement = try Self.prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, bucketSeconds)
        sqlite3_bind_int64(statement, 2, bucketSeconds)
        sqlite3_bind_int64(statement, 3, start)
        sqlite3_bind_int64(statement, 4, end)

        var points: [PowerReportPoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
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
        }
        try Self.checkCompletion(of: statement, in: database)
        return points
    }

    private func reportSummary(
        start: Int64,
        end: Int64,
        expectedMinutes: Int,
        points: [PowerReportPoint],
        in database: OpaquePointer
    ) throws -> PowerReportSummary {
        let sql = """
        SELECT
            COUNT(*),
            SUM(system_sum) / NULLIF(SUM(sample_count), 0),
            MAX(system_peak),
            SUM(system_sum / NULLIF(sample_count, 0)) / 60.0,
            SUM(external_count) * 1.0 / NULLIF(SUM(sample_count), 0),
            SUM(temperature_sum) / NULLIF(SUM(temperature_count), 0),
            MAX(CASE WHEN temperature_count > 0 THEN temperature_peak END),
            MIN(cycle_min),
            MAX(cycle_max)
        FROM minute_history
        WHERE minute >= ? AND minute <= ?
        """
        let statement = try Self.prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, start)
        sqlite3_bind_int64(statement, 2, end)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            try Self.checkCompletion(of: statement, in: database)
            return .empty
        }

        let observedMinutes = Int(sqlite3_column_int64(statement, 0))
        let firstCycle = Self.optionalInt(statement, column: 7)
        let lastCycle = Self.optionalInt(statement, column: 8)
        let latestHealth = points.reversed().compactMap(\.batteryHealthPercent).first
        let latestFull = points.reversed().compactMap(\.fullChargeMAh).first
        let latestDesign = points.reversed().compactMap(\.designMAh).first

        return PowerReportSummary(
            averageSystemLoad: sqlite3_column_double(statement, 1),
            peakSystemLoad: sqlite3_column_double(statement, 2),
            observedEnergyWh: sqlite3_column_double(statement, 3),
            externalPowerFraction: sqlite3_column_double(statement, 4),
            coverageFraction: min(Double(observedMinutes) / Double(expectedMinutes), 1),
            averageTemperatureC: Self.optionalDouble(statement, column: 5),
            peakTemperatureC: Self.optionalDouble(statement, column: 6),
            latestBatteryHealthPercent: latestHealth,
            latestFullChargeMAh: latestFull,
            latestDesignMAh: latestDesign,
            latestCycleCount: lastCycle,
            cycleCountChange: firstCycle.flatMap { first in lastCycle.map { $0 - first } }
        )
    }

    private static func defaultDatabaseURL() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RepositoryError.applicationSupportUnavailable
        }
        return support
            .appendingPathComponent("Powerflow", isDirectory: true)
            .appendingPathComponent("history.sqlite3")
    }

    private static func openDatabase(at url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK,
        let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let database { sqlite3_close(database) }
            throw RepositoryError.sqlite(message: message)
        }

        do {
            try execute("PRAGMA journal_mode=WAL", in: database)
            try execute("PRAGMA synchronous=NORMAL", in: database)
            try execute("PRAGMA busy_timeout=1500", in: database)
            try execute(schema, in: database)
            try execute("PRAGMA user_version=1", in: database)
            return database
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS minute_history (
        minute INTEGER PRIMARY KEY,
        sample_count INTEGER NOT NULL,
        system_sum REAL NOT NULL,
        system_peak REAL NOT NULL,
        adapter_sum REAL NOT NULL,
        adapter_peak REAL NOT NULL,
        battery_sum REAL NOT NULL,
        screen_sum REAL NOT NULL,
        screen_count INTEGER NOT NULL,
        package_sum REAL NOT NULL,
        package_count INTEGER NOT NULL,
        temperature_sum REAL NOT NULL,
        temperature_count INTEGER NOT NULL,
        temperature_peak REAL NOT NULL,
        fan_sum REAL NOT NULL,
        fan_count INTEGER NOT NULL,
        fan_peak REAL NOT NULL,
        external_count INTEGER NOT NULL,
        charging_count INTEGER NOT NULL,
        health_sum REAL NOT NULL,
        health_count INTEGER NOT NULL,
        remaining_sum REAL NOT NULL,
        remaining_count INTEGER NOT NULL,
        full_sum REAL NOT NULL,
        full_count INTEGER NOT NULL,
        design_sum REAL NOT NULL,
        design_count INTEGER NOT NULL,
        cycle_min INTEGER,
        cycle_max INTEGER
    );
    CREATE TABLE IF NOT EXISTS app_impact_samples (
        timestamp REAL PRIMARY KEY,
        payload BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS app_impact_timestamp ON app_impact_samples(timestamp);
    """

    private static func execute(_ sql: String, in database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw RepositoryError.sqlite(message: message)
        }
    }

    private static func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RepositoryError.sqlite(message: String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private static func stepDone(_ statement: OpaquePointer, in database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RepositoryError.sqlite(message: String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func checkCompletion(of statement: OpaquePointer, in database: OpaquePointer) throws {
        let result = sqlite3_errcode(database)
        guard result == SQLITE_OK || result == SQLITE_DONE || result == SQLITE_ROW else {
            throw RepositoryError.sqlite(message: String(cString: sqlite3_errmsg(database)))
        }
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

    private static func bind(_ value: Int, to statement: OpaquePointer, at index: inout Int32) {
        sqlite3_bind_int(statement, index, Int32(value))
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
            sqlite3_bind_double(statement, index, 0)
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
