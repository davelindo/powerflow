import Foundation

struct AdapterInfo: Equatable {
    var name: String?
    var manufacturer: String?
    var model: String?
    var serialNumber: String?
    var familyCode: String?
    var adapterID: String?
    var vendorID: String?
    var productID: String?
}

struct BatteryDetails: Equatable {
    var name: String?
    var manufacturer: String?
    var model: String?
    var serialNumber: String?
    var firmwareVersion: String?
    var hardwareRevision: String?
    var cycleCount: Int?
}

struct ThermalPressure: Equatable {
    let level: Int

    var label: String {
        switch level {
        case 0:
            return "Nominal"
        case 1:
            return "Moderate"
        case 2:
            return "Heavy"
        case 3, 4:
            return "Critical"
        default:
            return "Unknown"
        }
    }

    var displayValue: String {
        label == "Unknown" ? label : "\(label) (\(level))"
    }
}

struct PowerDiagnostics: Equatable {
    var smc: SMCPowerData
    var telemetry: PowerTelemetry?

    static let empty = PowerDiagnostics(smc: .empty, telemetry: nil)
}

struct AppEnergyOffender: Equatable, Identifiable {
    let groupID: String
    let primaryPID: Int32
    let name: String
    let iconPath: String?
    let processCount: Int
    let impactScore: Double
    let cpuPercent: Double
    let memoryBytes: UInt64
    let pageinsPerSecond: Double

    var id: String { groupID }
}

struct PowerSnapshot: Equatable {
    var timestamp: Date
    var isCharging: Bool
    var isExternalPowerConnected: Bool
    var batteryLevel: Int
    var batteryLevelPrecise: Double
    var timeRemainingMinutes: Int?
    var systemIn: Double
    var systemLoad: Double
    var batteryPower: Double
    var adapterPower: Double
    var adapterInputVoltage: Double?
    var adapterInputCurrent: Double?
    var adapterInputPower: Double?
    var efficiencyLoss: Double
    var screenPower: Double
    var screenPowerAvailable: Bool
    var heatpipePower: Double
    var heatpipeKey: String?
    var adapterWatts: Double
    var adapterVoltage: Double
    var adapterAmperage: Double
    var adapterInfo: AdapterInfo?
    var batteryDetails: BatteryDetails?
    var socName: String?
    var isAppleSilicon: Bool
    var temperatureC: Double
    var temperatureSource: String?
    var batteryTemperatureC: Double?
    var batteryHealthPercent: Double?
    var batteryRemainingWh: Double?
    var batteryCurrentMA: Double?
    var batteryCellVoltages: [Double]
    var batteryCycleCountSMC: Int?
    var batteryPercentSMC: Int?
    var lidClosed: Bool?
    var platformName: String?
    var processThermalState: ProcessInfo.ThermalState?
    var isLowPowerModeEnabled: Bool
    var thermalPressure: ThermalPressure?
    var appEnergyOffenders: [AppEnergyOffender]
    var diagnostics: PowerDiagnostics

    static let empty = PowerSnapshot(
        timestamp: Date(),
        isCharging: false,
        isExternalPowerConnected: false,
        batteryLevel: 0,
        batteryLevelPrecise: 0,
        timeRemainingMinutes: nil,
        systemIn: 0,
        systemLoad: 0,
        batteryPower: 0,
        adapterPower: 0,
        adapterInputVoltage: nil,
        adapterInputCurrent: nil,
        adapterInputPower: nil,
        efficiencyLoss: 0,
        screenPower: 0,
        screenPowerAvailable: false,
        heatpipePower: 0,
        heatpipeKey: nil,
        adapterWatts: 0,
        adapterVoltage: 0,
        adapterAmperage: 0,
        adapterInfo: nil,
        batteryDetails: nil,
        socName: nil,
        isAppleSilicon: false,
        temperatureC: 0,
        temperatureSource: nil,
        batteryTemperatureC: nil,
        batteryHealthPercent: nil,
        batteryRemainingWh: nil,
        batteryCurrentMA: nil,
        batteryCellVoltages: [],
        batteryCycleCountSMC: nil,
        batteryPercentSMC: nil,
        lidClosed: nil,
        platformName: nil,
        processThermalState: nil,
        isLowPowerModeEnabled: false,
        thermalPressure: nil,
        appEnergyOffenders: [],
        diagnostics: .empty
    )
}

struct PowerHistoryPoint: Equatable {
    let timestamp: Date
    let systemLoad: Double
    let screenPower: Double
    let inputPower: Double
    let temperatureC: Double
    let fanPercentMax: Double?
}

extension PowerSnapshot {
    var isOnExternalPower: Bool {
        isCharging || isExternalPowerConnected
    }

    var powerStateLabel: String {
        isCharging ? "Charging" : (isExternalPowerConnected ? "On Power" : "On Battery")
    }

    var isChargingActive: Bool {
        isCharging || diagnostics.smc.chargingStatus > 0.5
    }

    var socDisplayName: String? {
        guard isAppleSilicon, let socName else { return nil }
        let trimmed = socName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("Apple ") {
            return String(trimmed.dropFirst("Apple ".count))
        }
        return trimmed
    }

    var packagePowerLabel: String {
        if isAppleSilicon {
            return (socDisplayName ?? "SoC") + " (Heatpipe)"
        }

        if let key = heatpipeKey, key.hasPrefix("PC") {
            return "CPU Package"
        }

        return "Heatpipe"
    }

    var processThermalLabel: String? {
        guard let processThermalState else { return nil }
        switch processThermalState {
        case .nominal:
            return "Nominal"
        case .fair:
            return "Fair"
        case .serious:
            return "Serious"
        case .critical:
            return "Critical"
        @unknown default:
            return "Unknown"
        }
    }
}

extension PowerSnapshot {
    var hasSystemPowerData: Bool {
        diagnostics.smc.hasDeliveryRate
            || diagnostics.smc.hasSystemTotal
            || (diagnostics.telemetry?.hasSystemPowerData ?? false)
    }

    var powerBalanceMismatch: Double {
        abs((systemIn - systemLoad) - batteryPower)
    }

    var isPowerBalanceConsistent: Bool {
        guard hasSystemPowerData else { return true }
        let net = systemIn - systemLoad
        let netMagnitude = abs(net)
        let batteryMagnitude = abs(batteryPower)
        let minMagnitude = PowerflowConstants.minimumPowerMagnitude
        if netMagnitude < minMagnitude && batteryMagnitude < minMagnitude {
            return true
        }

        let tolerance = PowerflowConstants.powerBalanceMismatchTolerance
        let baseMismatch = PowerflowConstants.defaultPowerBalanceMismatch
        let allowedMismatch = max(baseMismatch, max(netMagnitude, batteryMagnitude) * tolerance)
        let signMatches = net == 0 || batteryPower == 0 || (net > 0) == (batteryPower > 0)
        return signMatches && powerBalanceMismatch <= allowedMismatch
    }
}
