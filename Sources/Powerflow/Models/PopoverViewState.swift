import AppKit
import CoreGraphics
import Foundation

enum PowerStateKind: Equatable {
    case charging
    case externalPower
    case onBattery

    init(snapshot: PowerSnapshot) {
        if snapshot.isChargingActive {
            self = .charging
        } else if snapshot.isExternalPowerConnected {
            self = .externalPower
        } else {
            self = .onBattery
        }
    }
}

struct PopoverOverviewMetric: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
}

struct PopoverOverviewState: Equatable {
    let powerLabel: String
    let displayPowerText: String
    let batteryLevelText: String
    let powerState: PowerStateKind
    let metrics: [PopoverOverviewMetric]
}

struct PopoverFlowState: Equatable {
    let snapshot: PowerSnapshot
    let diagram: FlowDiagramState
    let batteryLevelPrecise: Double
    let batteryOverlay: BatteryIconRenderer.Overlay
}

enum HistoryChartStyle: Equatable {
    case system
    case thermal
    case adapter
}

struct PopoverHistoryChartState: Identifiable, Equatable {
    let id: String
    let title: String
    let style: HistoryChartStyle
    let height: CGFloat
    let primaryValues: [Double]
    let secondaryValues: [Double]?
    let latestValueText: String
    let minValueText: String
    let maxValueText: String
    let secondaryRangeText: String?
    let secondaryLabel: String?
    let cacheKey: String
}

struct PopoverOffenderRowState: Identifiable, Equatable {
    let id: String
    let name: String
    let detailText: String
    let impactText: String
    let iconPath: String?
}

struct PopoverHistoryState: Equatable {
    let hasEnoughSamples: Bool
    let systemChart: PopoverHistoryChartState?
    let thermalChart: PopoverHistoryChartState?
    let adapterChart: PopoverHistoryChartState?
    let offenders: [PopoverOffenderRowState]
}

struct PopoverViewState: Equatable {
    let overview: PopoverOverviewState
    let flow: PopoverFlowState
    let history: PopoverHistoryState

    static let empty = PopoverViewState(
        overview: PopoverOverviewState(
            powerLabel: "System Load",
            displayPowerText: "--",
            batteryLevelText: "0%",
            powerState: .onBattery,
            metrics: []
        ),
        flow: PopoverFlowState(
            snapshot: .empty,
            diagram: FlowDiagramState(snapshot: .empty),
            batteryLevelPrecise: 0,
            batteryOverlay: .none
        ),
        history: PopoverHistoryState(
            hasEnoughSamples: false,
            systemChart: nil,
            thermalChart: nil,
            adapterChart: nil,
            offenders: []
        )
    )
}

final class PopoverStateStore: ObservableObject {
    @Published private(set) var state = PopoverViewState.empty

    func update(_ newState: PopoverViewState) {
        guard state != newState else { return }
        state = newState
    }
}

struct FlowDiagramState: Equatable {
    let adapterActive: Bool
    let systemValue: Double
    let adapterValue: Double?
    let batteryValue: Double?
    let adapterToJunction: Double
    let junctionToSystem: Double
    let junctionToBattery: Double
    let batteryToJunction: Double
    let batteryCharging: Bool
    let batteryMagnitude: Double
    let batteryActive: Bool

    init(snapshot: PowerSnapshot) {
        let systemLoad = max(snapshot.systemLoad, 0)
        let systemIn = max(snapshot.systemIn, 0)
        let adapterPresent = snapshot.adapterWatts > 0 || systemIn > 0.05

        adapterActive = adapterPresent
        systemValue = systemLoad
        if adapterPresent {
            adapterValue = snapshot.adapterWatts > 0 ? snapshot.adapterWatts : systemIn
        } else {
            adapterValue = nil
        }

        adapterToJunction = systemIn
        junctionToSystem = systemLoad
        junctionToBattery = max(systemIn - systemLoad, 0)
        batteryToJunction = max(systemLoad - systemIn, 0)

        let batteryRate = snapshot.batteryPower
        let batteryRateMagnitude = abs(batteryRate)
        let threshold = 0.05
        let netFlow = systemIn - systemLoad
        let netMagnitude = abs(netFlow)
        let netIsMeaningful = netMagnitude > 1.0
        let allowedDiscrepancy = max(1.0, netMagnitude * 0.3)
        let batteryRateReliable = batteryRateMagnitude > threshold
            && (!netIsMeaningful || (batteryRate * netFlow >= 0
                && abs(batteryRateMagnitude - netMagnitude) <= allowedDiscrepancy))

        var charging = false
        if batteryRateReliable {
            charging = batteryRate > 0
            if netIsMeaningful, batteryRate * netFlow < 0 {
                charging = netFlow > 0
            }
        } else if netIsMeaningful {
            charging = netFlow > 0
        } else if snapshot.isChargingActive {
            charging = true
        } else {
            charging = false
        }
        batteryCharging = charging

        let magnitude: Double
        if batteryRateReliable {
            magnitude = batteryRateMagnitude
        } else if netIsMeaningful {
            magnitude = netMagnitude
        } else {
            magnitude = batteryRateMagnitude
        }
        batteryMagnitude = magnitude
        batteryActive = magnitude > 0.05
        batteryValue = batteryActive ? magnitude : nil
    }

    var hasActiveFlow: Bool {
        showAdapterToJunction || showJunctionToSystem || batteryActive
    }

    var showAdapterToJunction: Bool {
        adapterToJunction > 0.05
    }

    var showJunctionToSystem: Bool {
        junctionToSystem > 0.05
    }

    var showJunctionToBattery: Bool {
        junctionToBattery > 0.05
    }

    var showBatteryToJunction: Bool {
        batteryToJunction > 0.05
    }
}
