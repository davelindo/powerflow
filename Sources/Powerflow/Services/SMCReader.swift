import Foundation

enum SMCSwitchState: String, Equatable {
    case enabled
    case disabled
    case unknown

    var label: String {
        switch self {
        case .enabled:
            return "Enabled"
        case .disabled:
            return "Disabled"
        case .unknown:
            return "Unknown"
        }
    }
}

struct SMCControlState: Equatable {
    var state: SMCSwitchState
    var key: String?
    var rawHex: String?

    var displayValue: String {
        let stateLabel = state.label
        guard let key else { return stateLabel }
        if let rawHex {
            return "\(stateLabel) (\(key) 0x\(rawHex))"
        }
        return "\(stateLabel) (\(key))"
    }
}

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
    var chargingControl: SMCControlState
    var dischargingControl: SMCControlState
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
        chargingControl: SMCControlState(state: .unknown, key: nil, rawHex: nil),
        dischargingControl: SMCControlState(state: .unknown, key: nil, rawHex: nil),
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
    private let cpuTempKeys = [
        "Tp09", "Tp0T",
        "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
        "Tg05", "Tg0D", "Tg0L", "Tg0T",
        "TC10", "TC11", "TC12", "TC13",
        "TC20", "TC21", "TC22", "TC23",
        "TC30", "TC31", "TC32", "TC33",
        "TC40", "TC41", "TC42", "TC43",
        "TC50", "TC51", "TC52", "TC53",
        "Tg04", "Tg05", "Tg0C", "Tg0D", "Tg0K", "Tg0L", "Tg0S", "Tg0T",
        "Tp1h", "Tp1t", "Tp1p", "Tp1l",
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j",
        "Tg0f", "Tg0j",
        "Te05", "Te0L", "Te0P", "Te0S",
        "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
        "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
        "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A",
        "Te05", "Te0S", "Te09", "Te0H",
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e",
        "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k",
    ]
    private let chargeControlKeys = ["CHTE", "CH0B", "CH0C"]
    private let dischargeControlKeys = ["CHIE", "CH0J", "CH0I"]

    private var connection: SMCConnection?
    private var preferredHeatpipeKey: String?
    private var preferredBatteryVoltageKey: String?
    private var preferredBatteryPercentKey: String?
    private var preferredCapacityKey: String?
    private var cachedCpuTempKeys: [String] = []
    private var didScanCpuTempKeys = false
    private let cpuTempScanCooldown: TimeInterval = 30
    private var lastCpuTempScanFailure: Date?

    init(cachedCpuTempKeys: [String] = []) {
        if !cachedCpuTempKeys.isEmpty {
            self.cachedCpuTempKeys = cachedCpuTempKeys
            self.didScanCpuTempKeys = true
        }
    }

    var cpuTemperatureKeysCache: [String] {
        cachedCpuTempKeys
    }

    func readPowerData(detailLevel: PowerSnapshotDetailLevel, hints: SMCReadHints) -> SMCPowerData {
        guard let connection = getConnection() else { return .empty }
        switch detailLevel {
        case .summary:
            return readSummaryPowerData(connection, hints: hints)
        case .full:
            return readFullPowerData(connection)
        }
    }

    private func readSummaryPowerData(_ connection: SMCConnection, hints: SMCReadHints) -> SMCPowerData {
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
            if let value = connection.readKey("TB0T")?.floatValue() {
                data.temperature = value
                data.hasTemperature = true
            }
            if let cpuTemp = readCPUTemperature(connection, allowScan: false) {
                data.cpuTemperature = cpuTemp.value
                data.cpuTemperatureKey = cpuTemp.key
                data.hasCpuTemperature = true
            }
        }

        return data
    }

    private func readFullPowerData(_ connection: SMCConnection) -> SMCPowerData {
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

        for key in ["SBA1", "SBA2", "SBA3"] {
            guard let value = connection.readKey(key)?.floatValue(), value > 0 else { continue }
            data.batteryCellVoltages.append(value)
            data.hasBatteryCellVoltages = true
        }

        if let value = connection.readKey("MSLD")?.floatValue() {
            data.lidClosed = value > 0.5
        }

        data.platformName = connection.readKey("RPlt")?.stringValue()
        data.chargingControl = readChargingControlState(connection)
        data.dischargingControl = readDischargingControlState(connection)
        data.fanReadings = readFanReadings(connection)
        if let cpuTemp = readCPUTemperature(connection, allowScan: true) {
            data.cpuTemperature = cpuTemp.value
            data.cpuTemperatureKey = cpuTemp.key
            data.hasCpuTemperature = true
        }

        return data
    }

    private func readPreferredValue(
        _ connection: SMCConnection,
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

    private func readChargingControlState(_ connection: SMCConnection) -> SMCControlState {
        for key in chargeControlKeys {
            guard let value = connection.readKey(key) else { continue }
            let rawHex = rawHexString(for: value)
            let state: SMCSwitchState
            if key == "CHTE" {
                state = parseTahoeChargeState(value)
            } else {
                state = parseLegacyChargeState(value)
            }
            return SMCControlState(state: state, key: key, rawHex: rawHex)
        }
        return SMCControlState(state: .unknown, key: nil, rawHex: nil)
    }

    private func readDischargingControlState(_ connection: SMCConnection) -> SMCControlState {
        for key in dischargeControlKeys {
            guard let value = connection.readKey(key) else { continue }
            let rawHex = rawHexString(for: value)
            let state = parseDischargeState(value)
            return SMCControlState(state: state, key: key, rawHex: rawHex)
        }
        return SMCControlState(state: .unknown, key: nil, rawHex: nil)
    }

    private func readFanReadings(_ connection: SMCConnection) -> [SMCFanReading] {
        let countValue = connection.readKey("FNum")?.floatValue() ?? 0
        let count = max(0, Int(countValue.rounded()))
        let maxFans = min(count, 6)
        let indices = maxFans > 0 ? Array(0..<maxFans) : [0, 1]
        var readings: [SMCFanReading] = []
        var seen = Set<Int>()

        for index in indices where !seen.contains(index) {
            seen.insert(index)
            let key = "F\(index)Ac"
            guard let rpm = connection.readKey(key)?.floatValue(), rpm > 0 else { continue }
            let maxKey = "F\(index)Mx"
            let maxRpm = connection.readKey(maxKey)?.floatValue()
            let minKey = "F\(index)Mn"
            let minRpm = connection.readKey(minKey)?.floatValue()
            let targetKey = "F\(index)Tg"
            let targetRpm = connection.readKey(targetKey)?.floatValue()
            let modeKey = "F\(index)Md"
            let modeRaw = connection.readKey(modeKey)?.floatValue().map { Int($0.rounded()) }
            let percentMax: Double?
            if let maxRpm, maxRpm > 0 {
                if let minRpm, minRpm > 0, maxRpm > minRpm {
                    percentMax = min(100, max(0, (rpm - minRpm) / (maxRpm - minRpm) * 100))
                } else {
                    percentMax = min(100, (rpm / maxRpm) * 100)
                }
            } else {
                percentMax = nil
            }
            readings.append(
                SMCFanReading(
                    index: index,
                    rpm: rpm,
                    maxRpm: maxRpm,
                    minRpm: minRpm,
                    targetRpm: targetRpm,
                    modeRaw: modeRaw,
                    percentMax: percentMax
                )
            )
        }

        return readings
    }

    private func readCPUTemperature(
        _ connection: SMCConnection,
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
            if !useCachedKeys {
                discoveredKeys.append(key)
            }
            if value > maxTemp, value < 150 {
                maxTemp = value
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

        return maxTemp > 0 ? (maxTemp, maxKey) : nil
    }


    private func parseLegacyChargeState(_ value: SMCValue) -> SMCSwitchState {
        guard let byte = value.bytes.first else { return .unknown }
        switch byte {
        case 0x00:
            return .enabled
        case 0x02:
            return .disabled
        default:
            return .unknown
        }
    }

    private func parseTahoeChargeState(_ value: SMCValue) -> SMCSwitchState {
        let size = max(0, min(value.dataSize, value.bytes.count))
        let slice = value.bytes.prefix(max(size, 4))
        let allZero = slice.allSatisfy { $0 == 0 }
        return allZero ? .enabled : .disabled
    }

    private func parseDischargeState(_ value: SMCValue) -> SMCSwitchState {
        guard let byte = value.bytes.first else { return .unknown }
        return byte == 0x00 ? .disabled : .enabled
    }

    private func rawHexString(for value: SMCValue) -> String? {
        let size = max(0, min(value.dataSize, value.bytes.count))
        guard size > 0 else { return nil }
        return value.bytes.prefix(size)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    private func getConnection() -> SMCConnection? {
        if let connection = connection {
            return connection
        }
        let newConnection = SMCConnection()
        connection = newConnection
        return newConnection
    }
}
