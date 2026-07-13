import Foundation

enum PowerReportRange: String, CaseIterable, Identifiable, Sendable {
    case hour
    case day
    case week
    case month
    case quarter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hour: return "1h"
        case .day: return "24h"
        case .week: return "7d"
        case .month: return "30d"
        case .quarter: return "90d"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .hour: return 60 * 60
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        case .month: return 30 * 24 * 60 * 60
        case .quarter: return 90 * 24 * 60 * 60
        }
    }

    var chartBucketSeconds: Int64 {
        switch self {
        case .hour: return 60
        case .day: return 5 * 60
        case .week: return 60 * 60
        case .month: return 4 * 60 * 60
        case .quarter: return 12 * 60 * 60
        }
    }
}

struct PowerReportPoint: Equatable, Identifiable, Sendable {
    let timestamp: Date
    let systemLoad: Double
    let adapterInput: Double
    let batteryPower: Double
    let screenPower: Double?
    let packagePower: Double?
    let temperatureC: Double?
    let fanPercent: Double?
    let batteryHealthPercent: Double?
    let fullChargeMAh: Double?
    let designMAh: Double?
    let cycleCount: Int?

    var id: Date { timestamp }
}

struct PowerReportSummary: Equatable, Sendable {
    let averageSystemLoad: Double
    let peakSystemLoad: Double
    let observedEnergyWh: Double
    let externalPowerFraction: Double
    let coverageFraction: Double
    let averageTemperatureC: Double?
    let peakTemperatureC: Double?
    let latestBatteryHealthPercent: Double?
    let latestFullChargeMAh: Double?
    let latestDesignMAh: Double?
    let latestCycleCount: Int?
    let cycleCountChange: Int?

    static let empty = PowerReportSummary(
        averageSystemLoad: 0,
        peakSystemLoad: 0,
        observedEnergyWh: 0,
        externalPowerFraction: 0,
        coverageFraction: 0,
        averageTemperatureC: nil,
        peakTemperatureC: nil,
        latestBatteryHealthPercent: nil,
        latestFullChargeMAh: nil,
        latestDesignMAh: nil,
        latestCycleCount: nil,
        cycleCountChange: nil
    )
}

struct PowerReportState: Equatable, Sendable {
    let range: PowerReportRange
    let points: [PowerReportPoint]
    let summary: PowerReportSummary
    let isLoading: Bool
    let errorMessage: String?

    static func empty(range: PowerReportRange = .day, isLoading: Bool = false) -> PowerReportState {
        PowerReportState(
            range: range,
            points: [],
            summary: .empty,
            isLoading: isLoading,
            errorMessage: nil
        )
    }
}

struct PowerHistoryObservation: Sendable {
    let timestamp: Date
    let systemLoad: Double
    let adapterInput: Double
    let batteryPower: Double
    let screenPower: Double?
    let packagePower: Double?
    let temperatureC: Double?
    let fanPercent: Double?
    let isExternalPowerConnected: Bool
    let isCharging: Bool
    let batteryHealthPercent: Double?
    let remainingMAh: Double?
    let fullChargeMAh: Double?
    let designMAh: Double?
    let cycleCount: Int?

    init(snapshot: PowerSnapshot) {
        timestamp = snapshot.timestamp
        systemLoad = Self.nonnegativePower(snapshot.systemLoad)
        adapterInput = Self.nonnegativePower(snapshot.systemIn)
        batteryPower = snapshot.batteryPower.isFinite ? snapshot.batteryPower : 0
        screenPower = snapshot.screenPowerAvailable
            ? Self.optionalNonnegativePower(snapshot.screenPower)
            : nil
        packagePower = snapshot.heatpipeKey == nil
            ? nil
            : Self.optionalNonnegativePower(snapshot.heatpipePower)
        temperatureC = Self.validTemperature(snapshot.temperatureC)
        fanPercent = snapshot.diagnostics.smc.fanReadings
            .compactMap(\.percentMax)
            .filter { $0.isFinite && (0...100).contains($0) }
            .max()
        isExternalPowerConnected = snapshot.isExternalPowerConnected
        isCharging = snapshot.isChargingActive
        batteryHealthPercent = snapshot.batteryHealthPercent.flatMap(Self.validPercent)
        remainingMAh = snapshot.batteryCapacityDetails?.remainingMAh.flatMap(Self.validCapacity)
        fullChargeMAh = snapshot.batteryCapacityDetails?.fullChargeMAh.flatMap(Self.validCapacity)
        designMAh = snapshot.batteryCapacityDetails?.designMAh.flatMap(Self.validCapacity)
        cycleCount = snapshot.batteryDetails?.cycleCount ?? snapshot.batteryCycleCountSMC
    }

    private static func nonnegativePower(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(value, 0)
    }

    private static func optionalNonnegativePower(_ value: Double) -> Double? {
        guard value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func validTemperature(_ value: Double) -> Double? {
        guard value.isFinite,
              (PowerflowConstants.minValidTemperature...PowerflowConstants.maxValidCpuTemperature)
                .contains(value) else { return nil }
        return value
    }

    private static func validPercent(_ value: Double) -> Double? {
        guard value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    private static func validCapacity(_ value: Double) -> Double? {
        guard value.isFinite, value > 0, value < 100_000 else { return nil }
        return value
    }
}
