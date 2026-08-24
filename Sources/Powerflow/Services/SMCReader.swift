import Foundation

struct SMCFanReading: Equatable, Identifiable {
    var index: Int
    var rpm: Double
    var maxRpm: Double?
    var minRpm: Double?
    var targetRpm: Double?
    var modeRaw: Int?
    var percentMax: Double?

    var id: Int { index }

    var modeLabel: String? {
        guard let modeRaw else { return nil }
        switch modeRaw {
        case 0:
            return "Auto"
        case 1:
            return "Manual"
        default:
            return "Mode \(modeRaw)"
        }
    }
}

struct SMCPowerData: Equatable {
    var batteryRate: Double
    var deliveryRate: Double
    var systemTotal: Double
    var heatpipe: Double
    var heatpipeKey: String?
    var brightness: Double
    var fullChargeCapacity: Double
    var currentCapacity: Double
    var designCapacity: Double
    var batteryVoltage: Double
    var batteryVoltageKey: String?
    var currentCapacityKey: String?
    var batteryPercent: Double
    var batteryPercentKey: String?
    var batteryCurrent: Double
    var batteryCycleCount: Int?
    var adapterInputVoltage: Double
    var adapterInputCurrent: Double
    var batteryCellVoltages: [Double]
    var lidClosed: Bool?
    var platformName: String?
    var chargingStatus: Double
    var timeToEmpty: Double
    var timeToFull: Double
    var temperature: Double
    var cpuTemperature: Double
    var cpuTemperatureKey: String?
    var hasBatteryRate: Bool
    var hasDeliveryRate: Bool
    var hasSystemTotal: Bool
    var hasHeatpipe: Bool
    var hasBrightness: Bool
    var hasFullChargeCapacity: Bool
    var hasCurrentCapacity: Bool
    var hasDesignCapacity: Bool
    var hasBatteryVoltage: Bool
    var hasBatteryPercent: Bool
    var hasBatteryCurrent: Bool
    var hasAdapterInputVoltage: Bool
    var hasAdapterInputCurrent: Bool
    var hasBatteryCellVoltages: Bool
    var hasChargingStatus: Bool
    var hasTimeToEmpty: Bool
    var hasTimeToFull: Bool
    var hasTemperature: Bool
    var hasCpuTemperature: Bool
    var fanReadings: [SMCFanReading]

    static let empty = SMCPowerData(
        batteryRate: 0,
        deliveryRate: 0,
        systemTotal: 0,
        heatpipe: 0,
        heatpipeKey: nil,
        brightness: 0,
        fullChargeCapacity: 0,
        currentCapacity: 0,
        designCapacity: 0,
        batteryVoltage: 0,
        batteryVoltageKey: nil,
        currentCapacityKey: nil,
        batteryPercent: 0,
        batteryPercentKey: nil,
        batteryCurrent: 0,
        batteryCycleCount: nil,
        adapterInputVoltage: 0,
        adapterInputCurrent: 0,
        batteryCellVoltages: [],
        lidClosed: nil,
        platformName: nil,
        chargingStatus: 0,
        timeToEmpty: 0,
        timeToFull: 0,
        temperature: 0,
        cpuTemperature: 0,
        cpuTemperatureKey: nil,
        hasBatteryRate: false,
        hasDeliveryRate: false,
        hasSystemTotal: false,
        hasHeatpipe: false,
        hasBrightness: false,
        hasFullChargeCapacity: false,
        hasCurrentCapacity: false,
        hasDesignCapacity: false,
        hasBatteryVoltage: false,
        hasBatteryPercent: false,
        hasBatteryCurrent: false,
        hasAdapterInputVoltage: false,
        hasAdapterInputCurrent: false,
        hasBatteryCellVoltages: false,
        hasChargingStatus: false,
        hasTimeToEmpty: false,
        hasTimeToFull: false,
        hasTemperature: false,
        hasCpuTemperature: false,
        fanReadings: []
    )
}

struct SMCReadHints {
    var needsScreenPower: Bool
    var needsHeatpipePower: Bool
    var needsTemperature: Bool
}

final class SMCReader {
    private let heatpipeKeys = ["PHPC", "PCPC", "PCPT", "PC0R", "PCPR"]
    private let batteryVoltageKeys = ["B0AV", "SBAV"]
    private let batteryPercentKeys = ["SBAS", "BRSC"]
    private let batteryCapacityKeys = ["SBAR", "B0RM"]
    // Deduplicated CPU temperature keys - discovered dynamically and cached
    private let cpuTempKeys: [String] = [
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
        "Tg05", "Tg0D", "Tg0L", "Tg0T",
        "TC10", "TC11", "TC12", "TC13",
        "TC20", "TC21", "TC22", "TC23",
        "TC30", "TC31", "TC32", "TC33",
        "TC40", "TC41", "TC42", "TC43",
        "TC50", "TC51", "TC52", "TC53",
        "Tg04", "Tg0C", "Tg0K", "Tg0S",
        "Tp1h", "Tp1t", "Tp1p", "Tp1l",
        "Tp0V", "Tp0Y", "Tp0e", "Tp0f", "Tp0j",
        "Tg0f", "Tg0j", "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0d", "Tg0e", "Tg0k",
        "Te05", "Te0L", "Te0P", "Te0S", "Te09", "Te0H",
        "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
        "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
        "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A",
    ]

    private var connection: FanKeyReading?
    private var preferredHeatpipeKey: String?
    private var preferredBatteryVoltageKey: String?
    private var preferredBatteryPercentKey: String?
    private var preferredCapacityKey: String?
    private var cachedCpuTempKeys: [String] = []
    private var cachedSummaryFanReadings: [SMCFanReading]?
    private var cachedFanCount: Int?
    private var cachedFanDetails: [Int: FanStaticDetails] = [:]
    private var cachedCpuTemperature: CPUTemperatureSample?
    private var didScanCpuTempKeys = false
    private let cpuTempScanCooldown = PowerflowConstants.cpuTempScanCooldown
    private var lastCpuTempScanFailure: Date?

    init(cachedCpuTempKeys: [String] = []) {
        if !cachedCpuTempKeys.isEmpty {
            self.cachedCpuTempKeys = cachedCpuTempKeys
            self.didScanCpuTempKeys = true
        }
    }

    init(cachedCpuTempKeys: [String], keyReader: FanKeyReading) {
        if !cachedCpuTempKeys.isEmpty {
            self.cachedCpuTempKeys = cachedCpuTempKeys
            self.didScanCpuTempKeys = true
        }
        self.connection = keyReader
    }

    var cpuTemperatureKeysCache: [String] {
        cachedCpuTempKeys
    }

    func resetCachedCPUTemperature() {
        cachedCpuTemperature = nil
    }

    func readPowerData(detailLevel: PowerSnapshotDetailLevel, hints: SMCReadHints) -> SMCPowerData {
        guard let smcConnection = getConnection() else { return .empty }
        switch detailLevel {
        case .summary:
            return readSummaryPowerData(smcConnection, hints: hints)
        case .full:
            return readFullPowerData(smcConnection)
        }
    }

    private func readSummaryPowerData(
        _ connection: FanKeyReading,
        hints: SMCReadHints
    ) -> SMCPowerData {
        var data = SMCPowerData.empty

        if let value = connection.readKey("PPBR")?.floatValue() {
            data.batteryRate = value
            data.hasBatteryRate = true
        }
        if let value = connection.readKey("PDTR")?.floatValue() {
            data.deliveryRate = value
            data.hasDeliveryRate = true
        }
        if let value = connection.readKey("PSTR")?.floatValue() {
            data.systemTotal = value
            data.hasSystemTotal = true
        }

        if let value = connection.readKey("VD0R")?.floatValue() {
            data.adapterInputVoltage = value
            data.hasAdapterInputVoltage = value > 0
        }
        if let value = connection.readKey("ID0R")?.floatValue() {
            data.adapterInputCurrent = value
            data.hasAdapterInputCurrent = value > 0
        }

        if let voltage = readPreferredValue(
            connection,
            preferredKey: &preferredBatteryVoltageKey,
            candidates: batteryVoltageKeys,
            requirePositive: true
        ) {
            data.batteryVoltage = voltage.value
            data.batteryVoltageKey = voltage.key
            data.hasBatteryVoltage = true
        }
        if let value = connection.readKey("B0AC")?.floatValue() {
            data.batteryCurrent = value
            data.hasBatteryCurrent = true
        }

        if hints.needsScreenPower, let value = connection.readKey("PDBR")?.floatValue() {
            data.brightness = value
            data.hasBrightness = true
        }

        if hints.needsHeatpipePower,
           let heatpipe = readPreferredValue(
               connection,
               preferredKey: &preferredHeatpipeKey,
               candidates: heatpipeKeys,
               requirePositive: true
           ) {
            data.heatpipe = heatpipe.value
            data.heatpipeKey = heatpipe.key
            data.hasHeatpipe = true
        }

        if hints.needsTemperature {
            let now = Date()
            let canUseTemperatureCache = !shouldRefreshCachedCPUTemperature(now: now)
                && cachedCpuTemperature != nil
            if !canUseTemperatureCache,
               let value = connection.readKey("TB0T")?.floatValue() {
                data.temperature = value
                data.hasTemperature = true
            }
            let shouldRefresh = shouldRefreshCachedCPUTemperature(now: now)
            if !shouldRefresh, let cached = cachedCpuTemperature {
                data.cpuTemperature = cached.value
                data.cpuTemperatureKey = cached.key
                data.hasCpuTemperature = true
            } else if let cpuTemp = readCPUTemperature(connection, allowScan: true) {
                data.cpuTemperature = cpuTemp.value
                data.cpuTemperatureKey = cpuTemp.key
                data.hasCpuTemperature = true
                storeCPUTemperature(cpuTemp, now: now)
            }
        }

        data.fanReadings = summaryFanReadings(connection)

        return data
    }

    private func summaryFanReadings(_ connection: FanKeyReading) -> [SMCFanReading] {
        if let cachedSummaryFanReadings {
            return cachedSummaryFanReadings
        }
        let readings = readFanReadings(connection, includeDetails: false)
        cachedSummaryFanReadings = readings
        return readings
    }

    private struct FanStaticDetails {
        let maxRpm: Double?
        let minRpm: Double?
        let targetRpm: Double?
        let modeRaw: Int?
    }

    private func readFullPowerData(_ connection: FanKeyReading) -> SMCPowerData {
        var data = SMCPowerData.empty

        if let value = connection.readKey("PPBR")?.floatValue() {
            data.batteryRate = value
            data.hasBatteryRate = true
        }
        if let value = connection.readKey("PDTR")?.floatValue() {
            data.deliveryRate = value
            data.hasDeliveryRate = true
        }
        if let value = connection.readKey("PSTR")?.floatValue() {
            data.systemTotal = value
            data.hasSystemTotal = true
        }

        if let heatpipe = readPreferredValue(
            connection,
            preferredKey: &preferredHeatpipeKey,
            candidates: heatpipeKeys,
            requirePositive: true
        ) {
            data.heatpipe = heatpipe.value
            data.heatpipeKey = heatpipe.key
            data.hasHeatpipe = true
        }

        if let value = connection.readKey("PDBR")?.floatValue() {
            data.brightness = value
            data.hasBrightness = true
        }

        if let value = connection.readKey("VD0R")?.floatValue() {
            data.adapterInputVoltage = value
            data.hasAdapterInputVoltage = value > 0
        }
        if let value = connection.readKey("ID0R")?.floatValue() {
            data.adapterInputCurrent = value
            data.hasAdapterInputCurrent = value > 0
        }

        if let value = connection.readKey("B0FC")?.floatValue() {
            data.fullChargeCapacity = value
            data.hasFullChargeCapacity = true
        }
        if let value = connection.readKey("B0DC")?.floatValue() {
            data.designCapacity = value
            data.hasDesignCapacity = true
        }

        if let capacity = readPreferredValue(
            connection,
            preferredKey: &preferredCapacityKey,
            candidates: batteryCapacityKeys,
            requirePositive: true
        ) {
            data.currentCapacity = capacity.value
            data.currentCapacityKey = capacity.key
            data.hasCurrentCapacity = true
        }

        if let voltage = readPreferredValue(
            connection,
            preferredKey: &preferredBatteryVoltageKey,
            candidates: batteryVoltageKeys,
            requirePositive: true
        ) {
            data.batteryVoltage = voltage.value
            data.batteryVoltageKey = voltage.key
            data.hasBatteryVoltage = true
        }

        if let percent = readPreferredValue(
            connection,
            preferredKey: &preferredBatteryPercentKey,
            candidates: batteryPercentKeys,
            requirePositive: true
        ) {
            data.batteryPercent = percent.value
            data.batteryPercentKey = percent.key
            data.hasBatteryPercent = true
        }

        if let value = connection.readKey("B0AC")?.floatValue() {
            data.batteryCurrent = value
            data.hasBatteryCurrent = true
        }

        if let value = connection.readKey("B0CT")?.floatValue() {
            let rounded = Int(value.rounded())
            data.batteryCycleCount = rounded > 0 ? rounded : data.batteryCycleCount
        }

        if let value = connection.readKey("CHCC")?.floatValue() {
            data.chargingStatus = value
            data.hasChargingStatus = true
        }

        if let value = connection.readKey("B0TE")?.floatValue() {
            data.timeToEmpty = value
            data.hasTimeToEmpty = true
        }
        if let value = connection.readKey("B0TF")?.floatValue() {
            data.timeToFull = value
            data.hasTimeToFull = true
        }

        if let value = connection.readKey("TB0T")?.floatValue() {
            data.temperature = value
            data.hasTemperature = true
        }

        // Dynamically scan for battery cell voltages (supports 1-8 cells).
        for cellIndex in 1...8 {
            let key = "SBA\(cellIndex)"
            guard let value = connection.readKey(key)?.floatValue(), value > 0 else { continue }
            data.batteryCellVoltages.append(value)
            data.hasBatteryCellVoltages = true
        }

        if let value = connection.readKey("MSLD")?.floatValue() {
            data.lidClosed = value > 0.5
        }

        data.platformName = connection.readKey("RPlt")?.stringValue()
        data.fanReadings = readFanReadings(connection, includeDetails: true)
        let shouldRefresh = shouldRefreshCachedCPUTemperature(now: Date())
        if !shouldRefresh, let cached = cachedCpuTemperature {
            data.cpuTemperature = cached.value
            data.cpuTemperatureKey = cached.key
            data.hasCpuTemperature = true
        } else if let cpuTemp = readCPUTemperature(connection, allowScan: true) {
            data.cpuTemperature = cpuTemp.value
            data.cpuTemperatureKey = cpuTemp.key
            data.hasCpuTemperature = true
            storeCPUTemperature(cpuTemp, now: Date())
        }

        return data
    }

    private struct CPUTemperatureSample {
        let value: Double
        let key: String?
        let timestamp: Date
    }

    private static let cpuTemperatureCacheInterval = PowerflowConstants.fullCpuTempRefreshInterval

    private func shouldRefreshCachedCPUTemperature(now: Date) -> Bool {
        guard let cachedCpuTemperature else { return true }
        return now.timeIntervalSince(cachedCpuTemperature.timestamp) >= Self.cpuTemperatureCacheInterval
    }

    private func storeCPUTemperature(_ sample: (value: Double, key: String)?, now: Date) {
        guard let sample else { return }
        cachedCpuTemperature = CPUTemperatureSample(
            value: sample.value,
            key: sample.key,
            timestamp: now
        )
    }

    private func readPreferredValue(
        _ connection: FanKeyReading,
        preferredKey: inout String?,
        candidates: [String],
        requirePositive: Bool
    ) -> (value: Double, key: String)? {
        if let key = preferredKey, let value = connection.readKey(key)?.floatValue() {
            if !requirePositive || value > 0 {
                return (value, key)
            }
        }

        for key in candidates {
            guard let value = connection.readKey(key)?.floatValue() else { continue }
            if requirePositive && value <= 0 { continue }
            preferredKey = key
            return (value, key)
        }

        return nil
    }

    func readFanReadings(
        _ connection: FanKeyReading,
        includeDetails: Bool
    ) -> [SMCFanReading] {
        let count: Int
        if let cachedFanCount {
            count = cachedFanCount
        } else if let cachedCount = cachedSummaryFanReadings?.count, cachedCount > 0 {
            count = min(cachedCount, 6)
            cachedFanCount = count
        } else {
            let countValue = connection.readKey("FNum")?.floatValue() ?? 0
            count = min(max(0, Int(countValue.rounded())), 6)
            cachedFanCount = count
        }
        let indices = count > 0 ? Array(0..<count) : [0, 1]
        var readings: [SMCFanReading] = []

        for index in indices {
            let key = "F\(index)Ac"
            guard let rpm = connection.readKey(key)?.floatValue(), rpm > 0 else { continue }
            if includeDetails {
                let maxKey = "F\(index)Mx"
                let details = fanDetails(
                    for: index,
                    connection: connection,
                    maxRpm: connection.readKey(maxKey)?.floatValue()
                )
                readings.append(Self.fanReading(
                    index: index,
                    rpm: rpm,
                    details: details,
                    includeDetails: includeDetails
                ))
            } else {
                let maxRpm = cachedFanDetails[index]?.maxRpm ?? connection.readKey("F\(index)Mx")?.floatValue()
                readings.append(Self.fanReading(
                    index: index,
                    rpm: rpm,
                    maxRpm: maxRpm,
                    minRpm: nil,
                    targetRpm: nil,
                    modeRaw: nil,
                    includeDetails: false
                ))
            }
        }

        return readings
    }

    private func fanDetails(
        for index: Int,
        connection: FanKeyReading,
        maxRpm: Double?
    ) -> FanStaticDetails {
        if let details = cachedFanDetails[index] {
            return details
        }
        let minRpm = connection.readKey("F\(index)Mn")?.floatValue()
        let targetRpm = connection.readKey("F\(index)Tg")?.floatValue()
        let modeRaw = connection.readKey("F\(index)Md")?.floatValue().map { Int($0.rounded()) }
        let details = FanStaticDetails(
            maxRpm: maxRpm,
            minRpm: minRpm,
            targetRpm: targetRpm,
            modeRaw: modeRaw
        )
        cachedFanDetails[index] = details
        return details
    }

    private static func fanReading(
        index: Int,
        rpm: Double,
        details: FanStaticDetails,
        includeDetails: Bool
    ) -> SMCFanReading {
        fanReading(
            index: index,
            rpm: rpm,
            maxRpm: details.maxRpm,
            minRpm: includeDetails ? details.minRpm : nil,
            targetRpm: includeDetails ? details.targetRpm : nil,
            modeRaw: includeDetails ? details.modeRaw : nil,
            includeDetails: includeDetails
        )
    }

    private static func fanReading(
        index: Int,
        rpm: Double,
        maxRpm: Double?,
        minRpm: Double?,
        targetRpm: Double?,
        modeRaw: Int?,
        includeDetails: Bool
    ) -> SMCFanReading {
        var percentMax: Double?
        if let maxRpm, maxRpm > 0 {
            if includeDetails, let minRpm, minRpm > 0, maxRpm > minRpm {
                percentMax = min(100, max(0, (rpm - minRpm) / (maxRpm - minRpm) * 100))
            } else {
                percentMax = min(100, (rpm / maxRpm) * 100)
            }
        }
        return SMCFanReading(
            index: index,
            rpm: rpm,
            maxRpm: maxRpm,
            minRpm: minRpm,
            targetRpm: targetRpm,
            modeRaw: modeRaw,
            percentMax: percentMax
       )
    }

    private func readCPUTemperature(
        _ connection: FanKeyReading,
        allowScan: Bool
    ) -> (value: Double, key: String)? {
        let now = Date()
        let useCachedKeys = didScanCpuTempKeys && !cachedCpuTempKeys.isEmpty
        if !useCachedKeys,
           !allowScan {
            return nil
        }
        if !useCachedKeys,
           let lastCpuTempScanFailure,
           now.timeIntervalSince(lastCpuTempScanFailure) < cpuTempScanCooldown {
            return nil
        }
        let keys = useCachedKeys ? cachedCpuTempKeys : cpuTempKeys
        var maxTemp: Double = 0
        var maxKey: String = ""
        var seen = Set<String>()
        var discoveredKeys: [String] = []

        for key in keys where !seen.contains(key) {
            seen.insert(key)
            guard let value = connection.readKey(key)?.floatValue() else { continue }
            // Normalize temperature: some keys report tenths of degrees
            let normalizedValue = value > 1000 ? value / 10.0 : value
            // Validate temperature is in reasonable range (0-150°C)
            let isValid = normalizedValue > PowerflowConstants.minValidTemperature
                && normalizedValue < PowerflowConstants.maxValidCpuTemperature
            if isValid, !useCachedKeys {
                discoveredKeys.append(key)
            }
            if isValid, normalizedValue > maxTemp {
                maxTemp = normalizedValue
                maxKey = key
            }
        }

        if !useCachedKeys {
            if !discoveredKeys.isEmpty {
                cachedCpuTempKeys = discoveredKeys
                didScanCpuTempKeys = true
                lastCpuTempScanFailure = nil
            } else {
                didScanCpuTempKeys = false
                lastCpuTempScanFailure = now
            }
        }

        if useCachedKeys, maxTemp <= 0 {
            cachedCpuTempKeys = []
            didScanCpuTempKeys = false
            lastCpuTempScanFailure = now
            return nil
        }

        return maxTemp > 0 ? (maxTemp, maxKey) : nil
    }

    private func getConnection() -> FanKeyReading? {
        if let connection = connection {
            return connection
        }
        let newConnection = SMCConnection()
        connection = newConnection
        return newConnection
    }
}

protocol FanKeyReading {
    func readKey(_ key: String) -> SMCValue?
}

extension SMCConnection: FanKeyReading {}
