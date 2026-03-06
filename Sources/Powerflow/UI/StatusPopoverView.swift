import AppKit
import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject private var popoverStore: PopoverStateStore
    @State private var showingSettings = false
    private let appState: AppState

    init(
        appState: AppState = .shared,
        popoverStore: PopoverStateStore? = nil
    ) {
        self.appState = appState
        _popoverStore = ObservedObject(wrappedValue: popoverStore ?? appState.popoverStore)
    }

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

    @ViewBuilder
    private var mainSections: some View {
        let popoverState = popoverStore.state

        Group {
            OverviewSection(state: popoverState.overview)
            FlowSection(state: popoverState.flow)
            HistorySection(state: popoverState.history)
        }
    }

    private var shellBackground: some View {
        Color.clear
    }
}

private struct OverviewSection: View {
    let state: PopoverOverviewState

    private var appearance: PowerStateAppearance {
        PowerStateAppearance(kind: state.powerState)
    }

    var body: some View {
        CardContainer(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.powerLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(state.displayPowerText)
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .accessibilityLabel("\(state.powerLabel): \(state.displayPowerText)")
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 6) {
                        Text(state.batteryLevelText)
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)

                        PowerStateBadge(appearance: appearance, compact: true)
                    }
                }

                if !state.metrics.isEmpty {
                    CompactOverviewMetricsRow(metrics: state.metrics)
                }
            }
        }
    }
}

private struct CompactOverviewMetricsRow: View {
    let metrics: [PopoverOverviewMetric]

    var body: some View {
        HStack(spacing: 10) {
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
                        .frame(height: 24)
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }
}
