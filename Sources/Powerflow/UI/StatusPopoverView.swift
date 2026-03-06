import AppKit
import SwiftUI

struct StatusPopoverView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if showingSettings {
                    SettingsView(layout: .popover)
                        .environmentObject(appState)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            )
                        )
                } else {
                    ScrollView {
                        popoverSections
                            .padding(12)
                    }
                    .scrollIndicators(.hidden)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        )
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            Divider()

            FooterActions(
                showingSettings: $showingSettings
            )
        }
        .frame(width: 402, height: 590)
        .background(shellBackground)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: showingSettings)
    }

    @ViewBuilder
    private var popoverSections: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 10) {
                mainSections
            }
        } else {
            fallbackPopoverSections
        }
        #else
        fallbackPopoverSections
        #endif
    }

    private var fallbackPopoverSections: some View {
        VStack(alignment: .leading, spacing: 10) {
            mainSections
        }
    }

    private var mainSections: some View {
        Group {
            OverviewSection(
                snapshot: appState.snapshot,
                settings: appState.settings
            )

            FlowSection(snapshot: appState.snapshot)

            HistorySection(history: appState.history)
        }
    }

    private var shellBackground: some View {
        Color.clear
    }
}

private struct OverviewSection: View {
    let snapshot: PowerSnapshot
    let settings: PowerSettings

    private var appearance: PowerStateAppearance {
        PowerStateAppearance(snapshot: snapshot)
    }

    private var powerLabel: String {
        if snapshot.isOnExternalPower && settings.showChargingPower {
            return "Input"
        }

        switch settings.statusBarItem {
        case .system:
            return "System Load"
        case .screen:
            return "Screen"
        case .heatpipe:
            return snapshot.packagePowerLabel
        }
    }

    private var sourceSummary: String {
        if snapshot.isChargingActive {
            if snapshot.adapterWatts > 0 {
                return "\(PowerFormatter.wattsString(snapshot.adapterWatts)) adapter"
            }
            return "External power"
        }

        if snapshot.isExternalPowerConnected {
            return "External power"
        }

        return "Battery"
    }

    var body: some View {
        let displayPowerValue = PowerFormatter.displayPowerValue(snapshot: snapshot, settings: settings)
        let displayPowerText = displayPowerValue.map(PowerFormatter.wattsString) ?? "--"
        let details = overviewDetails

        CardContainer(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(powerLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(displayPowerText)
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .accessibilityLabel("\(powerLabel): \(displayPowerText)")
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 6) {
                        Text("\(snapshot.batteryLevel)%")
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)

                        PowerStateBadge(appearance: appearance, compact: true)
                    }
                }

                PopoverInfoGroup {
                    ForEach(Array(details.enumerated()), id: \.element.id) { index, detail in
                        PopoverInfoRow(detail.title) {
                            PopoverValueText(detail.value)
                        }

                        if index < details.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private static let hourMinuteFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let minuteFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static func formatMinutes(_ minutes: Int) -> String {
        let formatter = minutes >= 60 ? hourMinuteFormatter : minuteFormatter
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
    }

    private struct OverviewDetail: Identifiable {
        let id: String
        let title: String
        let value: String
    }

    private var overviewDetails: [OverviewDetail] {
        var details: [OverviewDetail] = [
            OverviewDetail(id: "source", title: "Source", value: sourceSummary)
        ]

        if let minutes = snapshot.timeRemainingMinutes {
            details.append(
                OverviewDetail(
                    id: "time",
                    title: "Time",
                    value: Self.formatMinutes(minutes)
                )
            )
        }

        if let health = snapshot.batteryHealthPercent {
            details.append(
                OverviewDetail(
                    id: "health",
                    title: "Health",
                    value: String(format: "%.0f%%", health)
                )
            )
        }

        if let remainingWh = snapshot.batteryRemainingWh {
            details.append(
                OverviewDetail(
                    id: "remaining",
                    title: "Remaining",
                    value: String(format: "%.1f Wh", remainingWh)
                )
            )
        }

        if let batteryTemp = snapshot.batteryTemperatureC, batteryTemp > 0 {
            details.append(
                OverviewDetail(
                    id: "battery-temp",
                    title: "Temperature",
                    value: String(format: "%.1f C", batteryTemp)
                )
            )
        }

        return details
    }
}
