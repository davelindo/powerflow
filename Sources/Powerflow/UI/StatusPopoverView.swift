import AppKit
import SwiftUI

struct StatusPopoverView: View {
    @Environment(\.powerflowSnapshotRendering) private var snapshotRendering
    @ObservedObject private var popoverStore: PopoverStateStore
    @State private var showingSettings: Bool
    private let appState: AppState

    @MainActor
    init(
        appState: AppState,
        popoverStore: PopoverStateStore? = nil,
        initialShowingSettings: Bool = false
    ) {
        self.appState = appState
        _popoverStore = ObservedObject(wrappedValue: popoverStore ?? appState.popoverStore)
        _showingSettings = State(initialValue: initialShowingSettings)
    }

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader(showingSettings: $showingSettings)

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
        }
        .frame(width: 402, height: 590)
        .modifier(SnapshotShellModifier(enabled: snapshotRendering))
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: showingSettings)
    }

    @ViewBuilder
    private var popoverSections: some View {
        if snapshotRendering {
            fallbackPopoverSections
        } else {
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
    }

    private var fallbackPopoverSections: some View {
        VStack(alignment: .leading, spacing: 10) {
            mainSections
        }
    }

    @ViewBuilder
    private var mainSections: some View {
        let popoverState = popoverStore.state

        Group {
            OverviewSection(state: popoverState.overview, snapshot: popoverState.flow.snapshot)
            FlowSection(state: popoverState.flow)
            if !popoverState.connectedDevices.isEmpty {
                ConnectedDevicesSection(state: popoverState.connectedDevices)
            }
            HistorySection(state: popoverState.history)
        }
    }
}

private struct PopoverHeader: View {
    @Binding var showingSettings: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 26, height: 26)

                Image(systemName: "bolt.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(nsColor: .systemGreen))
            }

            Text(showingSettings ? "Settings" : "Powerflow")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            PopoverIconButton(
                systemImage: showingSettings ? "checkmark" : "gearshape",
                help: showingSettings ? "Return to live view" : "Open settings"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingSettings.toggle()
                }
            }

            PopoverIconButton(systemImage: "power", help: "Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct PopoverIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.28))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct SnapshotShellModifier: ViewModifier {
    let enabled: Bool

    private var shellShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    func body(content: Content) -> some View {
        if enabled {
            content
                .background(shellFill, in: shellShape)
                .overlay(shellShape.stroke(shellStroke, lineWidth: 1))
                .clipShape(shellShape)
                .compositingGroup()
        } else {
            content.background(Color.clear)
        }
    }

    private var shellFill: Color {
        Color(nsColor: NSColor(calibratedWhite: 0.96, alpha: 0.96))
    }

    private var shellStroke: Color {
        Color(nsColor: NSColor(calibratedWhite: 1.0, alpha: 0.72))
    }
}

private struct OverviewSection: View {
    let state: PopoverOverviewState
    let snapshot: PowerSnapshot

    private var appearance: PowerStateAppearance {
        PowerStateAppearance(kind: state.powerState)
    }

    var body: some View {
        CardContainer(padding: 0) {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    primaryPowerBlock

                    Divider()
                        .frame(height: 72)

                    batteryBlock

                    VStack(spacing: 8) {
                        HealthChip(
                            title: "Health",
                            value: healthText,
                            systemImage: "heart",
                            tint: Color(nsColor: .systemGreen)
                        )

                        HealthChip(
                            title: "Cycles",
                            value: cycleText,
                            systemImage: "arrow.triangle.2.circlepath",
                            tint: Color(nsColor: .systemGray)
                        )
                    }
                    .frame(width: 92)
                }
                .padding(12)

                Divider()

                CompactOverviewMetricsRow(metrics: overviewMetricChips)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
        }
    }

    private var primaryPowerBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(state.powerLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(state.displayPowerText)
                .font(.system(size: 33, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .accessibilityLabel("\(state.powerLabel): \(state.displayPowerText)")

            PowerStateBadge(appearance: appearance, compact: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var batteryBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Battery")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(state.batteryLevelText)
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)

            BatteryLevelBar(level: snapshot.batteryLevelPrecise)
                .frame(height: 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var overviewMetricChips: [PopoverOverviewMetric] {
        [
            PopoverOverviewMetric(id: "thermal", title: "Thermal", value: thermalText),
            PopoverOverviewMetric(id: "adapter", title: "Adapter", value: adapterText),
            PopoverOverviewMetric(id: "remaining", title: "Energy", value: remainingText),
        ]
    }

    private var healthText: String {
        snapshot.batteryHealthPercent.map { String(format: "%.0f%%", $0) } ?? "--"
    }

    private var cycleText: String {
        let cycles = snapshot.batteryDetails?.cycleCount ?? snapshot.batteryCycleCountSMC
        return cycles.map(String.init) ?? "--"
    }

    private var thermalText: String {
        if snapshot.temperatureC > 0 {
            return String(format: "%.1f C", snapshot.temperatureC)
        }
        return snapshot.thermalPressure?.label ?? "--"
    }

    private var adapterText: String {
        if let adapterInputPower = snapshot.adapterInputPower, adapterInputPower > 0 {
            return PowerFormatter.wattsString(adapterInputPower)
        }
        if snapshot.adapterWatts > 0 {
            return PowerFormatter.wattsString(snapshot.adapterWatts)
        }
        return "--"
    }

    private var remainingText: String {
        snapshot.batteryRemainingWh.map { String(format: "%.1f Wh", $0) } ?? "--"
    }
}

private struct CompactOverviewMetricsRow: View {
    let metrics: [PopoverOverviewMetric]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                VStack(alignment: .leading, spacing: 3) {
                    Text(metric.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text(metric.value)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if index < metrics.count - 1 {
                    Divider()
                        .frame(height: 22)
                }
            }
        }
    }
}

private struct HealthChip: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct BatteryLevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            let fillWidth = max(0, min(level / 100, 1)) * proxy.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))

                Capsule()
                    .fill(barColor)
                    .frame(width: fillWidth)
            }
        }
    }

    private var barColor: Color {
        if level < 20 {
            return Color(nsColor: .systemRed)
        }
        if level < 45 {
            return Color(nsColor: .systemOrange)
        }
        return Color(nsColor: .systemGreen)
    }
}
