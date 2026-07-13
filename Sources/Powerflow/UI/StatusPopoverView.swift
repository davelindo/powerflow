import AppKit
import SwiftUI

struct StatusPopoverView: View {
    @Environment(\.powerflowSnapshotRendering) private var snapshotRendering
    @ObservedObject private var popoverStore: PopoverStateStore
    @State private var showingSettings: Bool
    private let appState: AppState
    private let initialSelectedTab: PowerflowDashboardTab
    private let initialReportMode: PowerflowReportMode

    @MainActor
    init(
        appState: AppState,
        popoverStore: PopoverStateStore? = nil,
        initialShowingSettings: Bool = false,
        initialSelectedTab: PowerflowDashboardTab = .live,
        initialReportMode: PowerflowReportMode = .power
    ) {
        self.appState = appState
        self.initialSelectedTab = initialSelectedTab
        self.initialReportMode = initialReportMode
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
                    PowerflowWideDashboard(
                        state: popoverStore.state,
                        initialSelectedTab: initialSelectedTab,
                        initialReportMode: initialReportMode,
                        onReportRangeChange: appState.selectReportRange
                    )
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
        .frame(width: 420, height: 460)
        .modifier(SnapshotShellModifier(enabled: snapshotRendering))
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: showingSettings)
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
        .padding(.vertical, 7)
    }
}

private struct PopoverIconButton: View {
    @Environment(\.powerflowSnapshotRendering) private var snapshotRendering

    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        if snapshotRendering {
            fallbackButton
        } else {
        #if compiler(>=6.2)
            if #available(macOS 26, *) {
                Button(action: action) {
                    buttonLabel
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(help)
            } else {
                fallbackButton
            }
        #else
            fallbackButton
        #endif
        }
    }

    private var buttonLabel: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 28, height: 28)
    }

    private var fallbackButton: some View {
        Button(action: action) {
            buttonLabel
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
    @Environment(\.colorScheme) private var colorScheme
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
            content.background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var shellFill: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedWhite: 0.11, alpha: 0.98))
            : Color(nsColor: NSColor(calibratedWhite: 0.96, alpha: 0.96))
    }

    private var shellStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color(nsColor: NSColor(calibratedWhite: 1.0, alpha: 0.72))
    }
}

extension View {
    func longHoverDetails<Detail: View>(
        title: String,
        systemImage: String,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        modifier(
            LongHoverDetailsModifier(
                title: title,
                systemImage: systemImage,
                detail: detail()
            )
        )
    }
}

struct LongHoverDetailsModifier<Detail: View>: ViewModifier {
    let title: String
    let systemImage: String
    let detail: Detail
    @State private var isHovering = false
    @State private var isPresented = false
    @State private var revealTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .background(
                isHovering ? Color.accentColor.opacity(0.07) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isHovering ? 0.75 : 0)
                    .padding(3)
                    .accessibilityHidden(true)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover(perform: updateHover)
            .onTapGesture {
                revealTask?.cancel()
                isPresented.toggle()
            }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                HoverDetailCard(title: title, systemImage: systemImage) {
                    detail
                }
            }
            .accessibilityHint("Pause or click to show advanced details")
            .accessibilityAction(named: "Show advanced details") {
                isPresented = true
            }
            .onDisappear {
                revealTask?.cancel()
            }
    }

    private func updateHover(_ hovering: Bool) {
        isHovering = hovering
        revealTask?.cancel()

        guard hovering else {
            isPresented = false
            return
        }

        revealTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, isHovering else { return }
            isPresented = true
        }
    }
}

struct HoverDetailCard<Content: View>: View {
    @Environment(\.powerflowSnapshotRendering) private var snapshotRendering

    let title: String
    let systemImage: String
    let content: Content

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        if snapshotRendering {
            fallbackCard
        } else {
        #if compiler(>=6.2)
            if #available(macOS 26, *) {
                cardContent
                    .glassEffect(.regular, in: shape)
            } else {
                fallbackCard
            }
        #else
            fallbackCard
        #endif
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            Divider()

            content
        }
        .padding(14)
        .frame(width: 270, alignment: .leading)
    }

    private var fallbackCard: some View {
        cardContent
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.12)))
    }
}

struct InspectorRow: View {
    let label: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct AdapterInspector: View {
    let snapshot: PowerSnapshot

    var body: some View {
        VStack(spacing: 7) {
            if let identityText {
                InspectorRow(label: "Adapter", value: identityText)
            }
            InspectorRow(label: "Input", value: InspectorText.watts(inputPower))
            if snapshot.adapterWatts > 0 {
                InspectorRow(label: "Rated", value: InspectorText.watts(snapshot.adapterWatts))
            }
            if let voltage {
                InspectorRow(label: "Voltage", value: String(format: "%.2f V", voltage))
            }
            if let current {
                InspectorRow(label: "Current", value: String(format: "%.2f A", current))
            }
            if snapshot.efficiencyLoss > 0.05 {
                InspectorRow(label: "Conversion loss", value: InspectorText.watts(snapshot.efficiencyLoss))
            }
        }
    }

    private var identityText: String? {
        guard let info = snapshot.adapterInfo else { return nil }
        return InspectorText.identity([info.name, info.manufacturer, info.model])
    }

    private var inputPower: Double {
        snapshot.adapterInputPower ?? snapshot.adapterPower
    }

    private var voltage: Double? {
        if let value = snapshot.adapterInputVoltage, value > 0 { return value }
        return snapshot.adapterVoltage > 0 ? snapshot.adapterVoltage : nil
    }

    private var current: Double? {
        if let value = snapshot.adapterInputCurrent, value > 0 { return value }
        return snapshot.adapterAmperage > 0 ? snapshot.adapterAmperage : nil
    }
}

struct BatteryInspector: View {
    let snapshot: PowerSnapshot

    var body: some View {
        VStack(spacing: 7) {
            if let identityText {
                InspectorRow(label: "Battery", value: identityText)
            }
            InspectorRow(label: "Charge", value: String(format: "%.1f%%", snapshot.batteryLevelPrecise))
            if let health = snapshot.batteryHealthPercent {
                InspectorRow(label: "Health", value: String(format: "%.0f%%", health), tint: healthTint(health))
            }
            if let remaining = snapshot.batteryRemainingWh {
                InspectorRow(label: "Remaining", value: String(format: "%.1f Wh", remaining))
            }
            if let temperature = snapshot.batteryTemperatureC {
                InspectorRow(label: "Temperature", value: String(format: "%.1f °C", temperature))
            }
            if let cycles = snapshot.batteryDetails?.cycleCount ?? snapshot.batteryCycleCountSMC {
                InspectorRow(label: "Cycles", value: String(cycles))
            }
            if let current = snapshot.batteryCurrentMA {
                InspectorRow(label: "Current", value: String(format: "%.0f mA", current))
            }
            capacityRows
            if !snapshot.batteryCellVoltages.isEmpty {
                InspectorRow(label: "Cells", value: cellVoltageText)
            }
        }
    }

    @ViewBuilder
    private var capacityRows: some View {
        if let remaining = snapshot.batteryCapacityDetails?.remainingMAh {
            InspectorRow(label: "Remaining capacity", value: String(format: "%.0f mAh", remaining))
        }
        if let fullCharge = snapshot.batteryCapacityDetails?.fullChargeMAh {
            InspectorRow(label: "Full-charge capacity", value: String(format: "%.0f mAh", fullCharge))
        }
        if let design = snapshot.batteryCapacityDetails?.designMAh {
            InspectorRow(label: "Design capacity", value: String(format: "%.0f mAh", design))
        }
    }

    private var identityText: String? {
        guard let details = snapshot.batteryDetails else { return nil }
        return InspectorText.identity([details.name, details.manufacturer, details.model])
    }

    private var cellVoltageText: String {
        snapshot.batteryCellVoltages
            .map { String(format: "%.2f V", $0) }
            .joined(separator: " · ")
    }

    private func healthTint(_ health: Double) -> Color {
        if health < 70 { return Color(nsColor: .systemRed) }
        if health < 80 { return Color(nsColor: .systemOrange) }
        return Color(nsColor: .systemGreen)
    }
}

struct SystemInspector: View {
    let snapshot: PowerSnapshot

    var body: some View {
        VStack(spacing: 7) {
            InspectorRow(label: "System load", value: InspectorText.watts(snapshot.systemLoad))
            InspectorRow(label: "Input", value: InspectorText.watts(snapshot.systemIn))
            if snapshot.screenPowerAvailable {
                InspectorRow(label: "Display", value: InspectorText.watts(snapshot.screenPower))
            }
            if snapshot.heatpipeKey != nil {
                InspectorRow(
                    label: snapshot.packagePowerLabel,
                    value: InspectorText.watts(snapshot.heatpipePower)
                )
            }
            if snapshot.temperatureC > 0 {
                InspectorRow(label: "Primary temp", value: String(format: "%.1f °C", snapshot.temperatureC))
            }
            if let source = snapshot.temperatureSource {
                InspectorRow(label: "Temp source", value: source)
            }
            if let pressure = snapshot.thermalPressure {
                InspectorRow(label: "Thermal pressure", value: pressure.label)
            }
            if !snapshot.diagnostics.smc.fanReadings.isEmpty {
                InspectorRow(label: "Fans", value: fanText)
            }
        }
    }

    private var fanText: String {
        snapshot.diagnostics.smc.fanReadings
            .map { reading in
                let percent = reading.percentMax.map { String(format: " · %.0f%%", $0) } ?? ""
                return String(format: "F%d %.0f rpm", reading.index, reading.rpm) + percent
            }
            .joined(separator: "\n")
    }
}

private enum InspectorText {
    static func identity(_ components: [String?]) -> String? {
        let parts = components.compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func watts(_ value: Double) -> String {
        String(format: "%.1f W", abs(value) < 0.05 ? 0 : value)
    }
}
