import Foundation

enum PowerSnapshotDetailLevel {
    case summary
    case full
}

protocol PowerDataProvider {
    func readSnapshot(detailLevel: PowerSnapshotDetailLevel, settings: PowerSettings) -> PowerSnapshot
}

final class MacPowerDataProvider: PowerDataProvider {
    private let ioReader = IORegistryReader()
    private let smcReader: SMCReader
    private let thermalReader = ThermalPressureReader()
    private let hidTemperatureReader = HIDTemperatureReader()
    private let powerSourceReader = PowerSourceReader()
    private let socName: String?
    private let isAppleSilicon: Bool
    private let modelIdentifier: String
    private let polarityStore = BatteryRatePolarityStore()
    private let cpuTempKeyStore = CpuTempKeyStore()
    private var ppbrPolarity: BatteryRatePolarity?
    private var polarityKey: String
    private var batteryCurrentScale: Double?
    private var cachedCpuTemperature: CachedTemperature?
    private var lastSavedCpuTemperature: CachedTemperature?
    private var lastSavedCpuTempKeys: [String] = []

    init() {
        isAppleSilicon = SystemInfoReader.isAppleSilicon()
        socName = isAppleSilicon ? SystemInfoReader.socName() : nil
        modelIdentifier = SystemInfoReader.hardwareModel() ?? "unknown"
        polarityKey = modelIdentifier
        ppbrPolarity = polarityStore.load(for: modelIdentifier)
        let cachedCpuTempKeys = cpuTempKeyStore.loadKeys(for: modelIdentifier)
        lastSavedCpuTempKeys = cachedCpuTempKeys
        smcReader = SMCReader(cachedCpuTempKeys: cachedCpuTempKeys)
        cachedCpuTemperature = loadCachedCpuTemperature()
        lastSavedCpuTemperature = cachedCpuTemperature
    }

    private struct CachedTemperature: Codable {
        let value: Double
        let source: String?
        let timestamp: Date
    }

    private struct CpuTempKeyStore {
        private let defaults = UserDefaults.standard

        func loadKeys(for modelIdentifier: String) -> [String] {
            defaults.stringArray(forKey: keysKey(for: modelIdentifier)) ?? []
        }

        func saveKeys(_ keys: [String], for modelIdentifier: String) {
            defaults.set(keys, forKey: keysKey(for: modelIdentifier))
        }

        private func keysKey(for modelIdentifier: String) -> String {
            "powerflow.cachedCpuTempKeys.\(modelIdentifier)"
        }
    }

    private static let summaryCpuTempRefreshInterval: TimeInterval = 30
    private static let fullCpuTempRefreshInterval: TimeInterval = 5
    private static let maxCachedCpuTempAge: TimeInterval = 120
    private static let cpuTempPersistInterval: TimeInterval = 60

    func readSnapshot(detailLevel: PowerSnapshotDetailLevel, settings: PowerSettings) -> PowerSnapshot {
        let smcHints = smcReadHints(for: settings, detailLevel: detailLevel)
        let batteryInfo = ioReader.readBatteryInfo()
        let smc = smcReader.readPowerData(detailLevel: detailLevel, hints: smcHints)
        updateCpuTempKeyCacheIfNeeded()
        updatePolarityKey(using: smc)
        let telemetry = batteryInfo.powerTelemetry
        let efficiencyLoss = Double(telemetry?.adapterEfficiencyLoss ?? 0) / 1000.0
        let telemetrySystemIn = telemetry.map { Double($0.systemPowerIn) / 1000.0 }
        let telemetrySystemLoad = telemetry.map { Double($0.systemLoad) / 1000.0 }
        let telemetryBatteryPower = telemetry.map { Double($0.batteryPower) / 1000.0 }
        let adapterInputVoltage = smc.hasAdapterInputVoltage ? smc.adapterInputVoltage : nil
        let adapterInputCurrent = smc.hasAdapterInputCurrent ? smc.adapterInputCurrent : nil
        let adapterInputPower = resolveAdapterInputPower(
            voltage: adapterInputVoltage,
            current: adapterInputCurrent
        )
        let hasSmcSystem = smc.hasDeliveryRate && smc.hasSystemTotal
        let hasTelemetrySystem = telemetrySystemIn != nil && telemetrySystemLoad != nil
        let useTelemetrySystem = detailLevel == .summary && !hasSmcSystem && hasTelemetrySystem
        let systemIn = useTelemetrySystem
            ? (telemetrySystemIn ?? 0)
            : (smc.hasDeliveryRate ? smc.deliveryRate : (telemetrySystemIn ?? adapterInputPower ?? 0))
        let systemLoad = useTelemetrySystem
            ? (telemetrySystemLoad ?? 0)
            : (smc.hasSystemTotal ? smc.systemTotal : (telemetrySystemLoad ?? 0))
        let lidClosed = smc.lidClosed
        let screenPowerAvailable = smc.hasBrightness && lidClosed != true
        let screenPower = screenPowerAvailable ? smc.brightness : 0
        let heatpipePower = smc.hasHeatpipe ? smc.heatpipe : 0
        let heatpipeKey = smc.heatpipeKey
        let adjustedBatteryRate = adjustedBatteryRate(from: smc, batteryInfo: batteryInfo)
        let batteryPercentSMC = batteryPercent(from: smc)
        let batteryLevel = resolveBatteryLevel(batteryInfo: batteryInfo, smcPercent: batteryPercentSMC)
        let batteryLevelPrecise = resolveBatteryLevelPrecise(batteryInfo: batteryInfo, smc: smc)
        let batteryCurrentMA = resolveBatteryCurrentMA(smc: smc, batteryInfo: batteryInfo)
        let batteryVoltageMV = resolveBatteryVoltageMV(smc: smc, batteryInfo: batteryInfo)
        let batteryPower = resolveBatteryPower(
            adjustedBatteryRate: adjustedBatteryRate,
            telemetryBatteryPower: telemetryBatteryPower,
            batteryCurrentMA: batteryCurrentMA,
            batteryVoltageMV: batteryVoltageMV,
            systemIn: systemIn,
            systemLoad: systemLoad,
            preferTelemetryBatteryPower: useTelemetrySystem
        )
        let adapterPower = adapterInputPower ?? (systemIn + efficiencyLoss)
        let batteryHealthPercent = batteryHealthPercent(from: smc)
        let batteryRemainingWh = batteryRemainingWh(from: smc, batteryInfo: batteryInfo)
        let smcTime = batteryInfo.isCharging
            ? (smc.hasTimeToFull ? smc.timeToFull : 0)
            : (smc.hasTimeToEmpty ? smc.timeToEmpty : 0)
        let rawTimeRemaining = smcTime > 0
            ? Int(smcTime.rounded())
            : (batteryInfo.timeRemainingMinutes ?? powerSourceReader.timeRemainingMinutes())
        let timeRemainingMinutes = sanitizeTimeRemaining(rawTimeRemaining, batteryInfo: batteryInfo)
        let thermalPressure = thermalReader.readPressure()
        let (temperatureC, temperatureSource) = primaryTemperature(smc: smc, detailLevel: detailLevel)
        let batteryTemperatureC = smc.hasTemperature && smc.temperature > 0 ? smc.temperature : nil
        let batteryCellVoltages = resolveBatteryCellVoltages(smc: smc, batteryInfo: batteryInfo)
        let processInfo = ProcessInfo.processInfo

        return PowerSnapshot(
            timestamp: Date(),
            isCharging: batteryInfo.isCharging,
            isExternalPowerConnected: batteryInfo.isExternalConnected,
            batteryLevel: batteryLevel,
            batteryLevelPrecise: batteryLevelPrecise,
            timeRemainingMinutes: timeRemainingMinutes,
            systemIn: systemIn,
            systemLoad: systemLoad,
            batteryPower: batteryPower,
            adapterPower: adapterPower,
            adapterInputVoltage: adapterInputVoltage,
            adapterInputCurrent: adapterInputCurrent,
            adapterInputPower: adapterInputPower,
            efficiencyLoss: efficiencyLoss,
            screenPower: screenPower,
            screenPowerAvailable: screenPowerAvailable,
            heatpipePower: heatpipePower,
            heatpipeKey: heatpipeKey,
            adapterWatts: batteryInfo.adapterWatts,
            adapterVoltage: batteryInfo.adapterVoltage,
            adapterAmperage: batteryInfo.adapterAmperage,
            adapterInfo: batteryInfo.adapterInfo,
            batteryDetails: batteryInfo.batteryDetails,
            socName: socName,
            isAppleSilicon: isAppleSilicon,
            temperatureC: temperatureC,
            temperatureSource: temperatureSource,
            batteryTemperatureC: batteryTemperatureC,
            batteryHealthPercent: batteryHealthPercent,
            batteryRemainingWh: batteryRemainingWh,
            batteryCurrentMA: batteryCurrentMA,
            batteryCellVoltages: batteryCellVoltages,
            batteryCycleCountSMC: smc.batteryCycleCount,
            batteryPercentSMC: batteryPercentSMC,
            lidClosed: lidClosed,
            platformName: smc.platformName,
            processThermalState: processInfo.thermalState,
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalPressure: thermalPressure,
            diagnostics: PowerDiagnostics(smc: smc, telemetry: telemetry)
        )
    }

    private func batteryHealthPercent(from smc: SMCPowerData) -> Double? {
        guard smc.hasDesignCapacity, smc.hasFullChargeCapacity,
              smc.designCapacity > 0, smc.fullChargeCapacity > 0 else { return nil }
        let raw = (smc.fullChargeCapacity / smc.designCapacity) * 100.0
        let clamped = max(0, min(raw, 120))
        return clamped
    }

    private func batteryRemainingWh(from smc: SMCPowerData, batteryInfo: BatteryInfo) -> Double? {
        if smc.hasCurrentCapacity, smc.hasBatteryVoltage,
           smc.currentCapacity > 0, smc.batteryVoltage > 0 {
            let ampHours = smc.currentCapacity / 1000.0
            let volts = normalizeVoltageVolts(smc.batteryVoltage)
            return ampHours * volts
        }

        guard batteryInfo.capacityUnits == .mah,
              let voltage = batteryInfo.batteryVoltage,
              batteryInfo.currentCapacity > 0,
              voltage > 0 else { return nil }
        let ampHours = Double(batteryInfo.currentCapacity) / 1000.0
        let volts = normalizeVoltageVolts(Double(voltage))
        return ampHours * volts
    }

    private func primaryTemperature(
        smc: SMCPowerData,
        detailLevel: PowerSnapshotDetailLevel
    ) -> (Double, String?) {
        let now = Date()
        if smc.hasCpuTemperature, smc.cpuTemperature > 0 {
            let source = smc.cpuTemperatureKey.map { "SMC \($0)" } ?? "SMC CPU"
            cacheCpuTemperature(value: smc.cpuTemperature, source: source, timestamp: now)
            return (smc.cpuTemperature, source)
        }

        let cachedAge = cachedCpuTemperatureAge(now: now)
        let refreshInterval = detailLevel == .full
            ? Self.fullCpuTempRefreshInterval
            : Self.summaryCpuTempRefreshInterval
        let shouldRefresh = cachedAge == nil || (cachedAge ?? 0) > refreshInterval
        let shouldReadHid = !smc.hasCpuTemperature && shouldRefresh
        if shouldReadHid, let hidTemp = hidTemperatureReader.readCPUTemperature() {
            cacheCpuTemperature(value: hidTemp, source: "HID CPU", timestamp: now)
            return (hidTemp, "HID CPU")
        }

        if let cachedCpuTemperature,
           let cachedAge,
           cachedAge <= Self.maxCachedCpuTempAge {
            return (cachedCpuTemperature.value, cachedCpuTemperature.source)
        }

        if smc.hasTemperature, smc.temperature > 0 {
            return (smc.temperature, "SMC Battery")
        }

        return (0, nil)
    }

    private func cacheCpuTemperature(value: Double, source: String?, timestamp: Date) {
        let cached = CachedTemperature(value: value, source: source, timestamp: timestamp)
        cachedCpuTemperature = cached
        persistCachedCpuTemperatureIfNeeded(cached)
    }

    private func cachedCpuTemperatureAge(now: Date = Date()) -> TimeInterval? {
        cachedCpuTemperature.map { now.timeIntervalSince($0.timestamp) }
    }

    private func loadCachedCpuTemperature() -> CachedTemperature? {
        guard let data = UserDefaults.standard.data(forKey: cpuTempCacheKey) else { return nil }
        return try? JSONDecoder().decode(CachedTemperature.self, from: data)
    }

    private func persistCachedCpuTemperatureIfNeeded(_ cached: CachedTemperature) {
        if let lastSavedCpuTemperature {
            let age = cached.timestamp.timeIntervalSince(lastSavedCpuTemperature.timestamp)
            if age < Self.cpuTempPersistInterval { return }
        }
        saveCachedCpuTemperature(cached)
        lastSavedCpuTemperature = cached
    }

    private func saveCachedCpuTemperature(_ cached: CachedTemperature) {
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: cpuTempCacheKey)
    }

    private var cpuTempCacheKey: String {
        "powerflow.cachedCpuTemperature.\(modelIdentifier)"
    }

    private func updateCpuTempKeyCacheIfNeeded() {
        let keys = smcReader.cpuTemperatureKeysCache
        guard !keys.isEmpty, keys != lastSavedCpuTempKeys else { return }
        cpuTempKeyStore.saveKeys(keys, for: modelIdentifier)
        lastSavedCpuTempKeys = keys
    }

    private func sanitizeTimeRemaining(_ minutes: Int?, batteryInfo: BatteryInfo) -> Int? {
        guard let minutes, minutes > 0 else { return nil }

        let maxChargeMinutes = 12 * 60
        let maxDischargeMinutes = 48 * 60

        if batteryInfo.isCharging {
            return minutes <= maxChargeMinutes ? minutes : nil
        }

        if batteryInfo.isExternalConnected {
            return nil
        }

        return minutes <= maxDischargeMinutes ? minutes : nil
    }

    private func smcReadHints(
        for settings: PowerSettings,
        detailLevel: PowerSnapshotDetailLevel
    ) -> SMCReadHints {
        let resolvedFormat = resolvedStatusBarFormat(from: settings)
        let needsScreen = settings.statusBarItem == .screen || resolvedFormat.contains("{screen}")
        let needsHeatpipe = settings.statusBarItem == .heatpipe || resolvedFormat.contains("{heatpipe}")
        let needsTempToken = resolvedFormat.contains("{temp}")
        let cachedAge = cachedCpuTemperatureAge()
        let needsTempRefresh = cachedAge == nil || (cachedAge ?? 0) > Self.summaryCpuTempRefreshInterval
        let needsTemp = detailLevel == .full || needsTempToken || needsTempRefresh
        return SMCReadHints(
            needsScreenPower: needsScreen,
            needsHeatpipePower: needsHeatpipe,
            needsTemperature: needsTemp
        )
    }

    private func resolvedStatusBarFormat(from settings: PowerSettings) -> String {
        let trimmed = settings.statusBarFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? PowerSettings.default.statusBarFormat : trimmed
    }

    private func adjustedBatteryRate(from smc: SMCPowerData, batteryInfo: BatteryInfo) -> Double? {
        guard smc.hasBatteryRate else { return nil }
        let batteryRate = smc.batteryRate
        let threshold = 0.05

        if ppbrPolarity == nil, abs(batteryRate) > threshold {
            if !batteryInfo.isExternalConnected && !batteryInfo.isCharging {
                ppbrPolarity = batteryRate < 0 ? .normal : .inverted
            } else if batteryInfo.isCharging && batteryInfo.isExternalConnected {
                ppbrPolarity = batteryRate > 0 ? .normal : .inverted
            }

            if let polarity = ppbrPolarity {
                polarityStore.save(polarity, for: polarityKey)
            }
        }

        let polarity = ppbrPolarity ?? .normal
        return batteryRate * Double(polarity.rawValue)
    }

    private func resolveBatteryPower(
        adjustedBatteryRate: Double?,
        telemetryBatteryPower: Double?,
        batteryCurrentMA: Double?,
        batteryVoltageMV: Double?,
        systemIn: Double,
        systemLoad: Double,
        preferTelemetryBatteryPower: Bool
    ) -> Double {
        if preferTelemetryBatteryPower,
           let telemetryBatteryPower,
           abs(telemetryBatteryPower) > 0.01 {
            return telemetryBatteryPower
        }

        if let adjustedBatteryRate, abs(adjustedBatteryRate) > 0.01 {
            return adjustedBatteryRate
        }

        if let telemetryBatteryPower, abs(telemetryBatteryPower) > 0.01 {
            return telemetryBatteryPower
        }

        if let voltageMV = batteryVoltageMV,
           let currentMA = batteryCurrentMA,
           voltageMV != 0, currentMA != 0 {
            return (voltageMV * currentMA) / 1_000_000.0
        }

        if systemIn > 0, systemLoad > 0 {
            return systemIn - systemLoad
        }

        if systemIn <= 0, systemLoad > 0 {
            return -systemLoad
        }

        return 0
    }

    private func updatePolarityKey(using smc: SMCPowerData) {
        guard let platform = smc.platformName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !platform.isEmpty else { return }
        guard platform != polarityKey else { return }
        polarityKey = platform
        if let stored = polarityStore.load(for: platform) {
            ppbrPolarity = stored
        }
    }

    private func resolveAdapterInputPower(voltage: Double?, current: Double?) -> Double? {
        guard let voltage, let current, voltage > 0, current > 0 else { return nil }
        return voltage * current
    }

    private func batteryPercent(from smc: SMCPowerData) -> Int? {
        guard smc.hasBatteryPercent else { return nil }
        let clamped = max(0, min(smc.batteryPercent, 100))
        return Int(clamped.rounded())
    }

    private func resolveBatteryLevelPrecise(batteryInfo: BatteryInfo, smc: SMCPowerData) -> Double {
        if smc.hasBatteryPercent, smc.batteryPercent > 0 {
            return clampPercent(smc.batteryPercent)
        }

        if smc.hasCurrentCapacity,
           (smc.hasFullChargeCapacity || smc.hasDesignCapacity),
           smc.currentCapacity > 0 {
            let maxCapacity = smc.hasFullChargeCapacity ? smc.fullChargeCapacity : smc.designCapacity
            if maxCapacity > 0 {
                return clampPercent((smc.currentCapacity / maxCapacity) * 100.0)
            }
        }

        if batteryInfo.capacityUnits == .mah,
           let maxCapacity = batteryInfo.maxCapacity,
           maxCapacity > 0,
           batteryInfo.currentCapacity > 0 {
            return clampPercent((Double(batteryInfo.currentCapacity) / Double(maxCapacity)) * 100.0)
        }

        let fallback = resolveBatteryLevel(
            batteryInfo: batteryInfo,
            smcPercent: batteryPercent(from: smc)
        )
        return Double(fallback)
    }

    private func resolveBatteryLevel(batteryInfo: BatteryInfo, smcPercent: Int?) -> Int {
        if batteryInfo.capacityUnits == .percent {
            return batteryInfo.batteryPercent
        }

        if let maxCapacity = batteryInfo.maxCapacity, maxCapacity > 0, batteryInfo.batteryPercent > 0 {
            return batteryInfo.batteryPercent
        }

        if let smcPercent {
            return smcPercent
        }

        return batteryInfo.batteryPercent
    }

    private func clampPercent(_ value: Double) -> Double {
        max(0, min(100, value))
    }

    private func resolveBatteryCurrentMA(smc: SMCPowerData, batteryInfo: BatteryInfo) -> Double? {
        if let ioCurrent = batteryInfo.instantAmperage {
            let ioValue = Double(ioCurrent)
            if smc.hasBatteryCurrent, let inferred = inferredBatteryCurrentScale(
                smcCurrent: smc.batteryCurrent,
                ioCurrent: ioValue
            ) {
                batteryCurrentScale = inferred
            }
            return ioValue
        }

        guard smc.hasBatteryCurrent, let scale = batteryCurrentScale else { return nil }
        return smc.batteryCurrent * scale
    }

    private func inferredBatteryCurrentScale(smcCurrent: Double, ioCurrent: Double) -> Double? {
        let absSMC = abs(smcCurrent)
        let absIO = abs(ioCurrent)
        guard absSMC > 0.01, absIO > 0.01 else { return nil }
        let ratio = absIO / absSMC
        let candidates: [Double] = [0.001, 0.01, 0.1, 1, 10, 100, 1000]
        guard let best = candidates.min(by: { abs(ratio - $0) < abs(ratio - $1) }) else {
            return nil
        }
        let lower = best * 0.5
        let upper = best * 2.0
        guard ratio >= lower, ratio <= upper else { return nil }
        return best
    }

    private func resolveBatteryVoltageMV(smc: SMCPowerData, batteryInfo: BatteryInfo) -> Double? {
        if smc.hasBatteryVoltage, smc.batteryVoltage > 0 {
            return normalizeVoltageMillivolts(smc.batteryVoltage)
        }
        if let voltage = batteryInfo.batteryVoltage, voltage > 0 {
            return normalizeVoltageMillivolts(Double(voltage))
        }
        return nil
    }

    private func resolveBatteryCellVoltages(smc: SMCPowerData, batteryInfo: BatteryInfo) -> [Double] {
        let values: [Double]
        if !smc.batteryCellVoltages.isEmpty {
            values = smc.batteryCellVoltages
        } else if let cellVoltages = batteryInfo.cellVoltages {
            values = cellVoltages.map(Double.init)
        } else {
            values = []
        }
        return values.map(normalizeVoltageVolts).filter { $0 > 0 }
    }

    private func normalizeVoltageVolts(_ value: Double) -> Double {
        guard value > 0 else { return 0 }
        return value > 100 ? value / 1000.0 : value
    }

    private func normalizeVoltageMillivolts(_ value: Double) -> Double {
        guard value > 0 else { return 0 }
        return value > 100 ? value : value * 1000.0
    }
}
