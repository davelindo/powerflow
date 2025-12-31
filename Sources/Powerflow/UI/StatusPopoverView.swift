import AppKit
import SwiftUI

// MARK: - Main View
struct StatusPopoverView: View {
    @EnvironmentObject private var appState: AppState
    @State private var diagnosticsExpanded = false
    @State private var showingSettings = false

    var body: some View {
        let snapshot = appState.snapshot

        VStack(spacing: 0) {
            if showingSettings {
                SettingsView(layout: .popover)
                    .environmentObject(appState)
                    .transition(.opacity)
                    .layoutPriority(1)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        OverviewSection(snapshot: snapshot, settings: appState.settings)

                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                PowerFlowView(snapshot: snapshot)
                                Divider()
                                ConsumptionCard(snapshot: snapshot)
                            }
                            .padding(.vertical, 4)
                        }

                        HistorySection(history: appState.history)

                        GroupBox {
                            if diagnosticsExpanded {
                                DiagnosticsSection(snapshot: snapshot)
                                    .padding(.top, 4)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        } label: {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    diagnosticsExpanded.toggle()
                                }
                            } label: {
                                HStack {
                                    Text("Diagnostics")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .rotationEffect(.degrees(diagnosticsExpanded ? 90 : 0))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
                .transition(.opacity)
                .layoutPriority(1)
            }

            Divider()
            FooterActions(showingSettings: $showingSettings)
        }
        .frame(width: 360, height: 520)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}

// MARK: - Overview
private struct OverviewSection: View {
    let snapshot: PowerSnapshot
    let settings: PowerSettings

    var body: some View {
        let displayPowerValue = PowerFormatter.displayPowerValue(snapshot: snapshot, settings: settings)
        let displayPowerText = displayPowerValue.map(PowerFormatter.wattsString) ?? "--"

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Powerflow", systemImage: "bolt.ring.closed")
                        .font(.headline)

                    Spacer()

                    Label(
                        snapshot.powerStateLabel,
                        systemImage: snapshot.powerStateIconName
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(powerLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(displayPowerText)
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Battery")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("\(snapshot.batteryLevel)%")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }
                }

                ProgressView(value: Double(snapshot.batteryLevel), total: 100)

                if !overviewMetrics.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(overviewMetrics) { metric in
                            overviewMetricLabel(metric)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var powerLabel: String {
        if snapshot.isOnExternalPower && settings.showChargingPower {
            return "Input"
        }
        switch settings.statusBarItem {
        case .system:
            return "System load"
        case .screen:
            return "Screen"
        case .heatpipe:
            return snapshot.packagePowerLabel
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

    private struct OverviewMetric: Identifiable {
        let id: String
        let systemImage: String
        let value: String
        let helpText: String?
    }

    private var overviewMetrics: [OverviewMetric] {
        var metrics: [OverviewMetric] = []

        if let minutes = snapshot.timeRemainingMinutes {
            metrics.append(
                OverviewMetric(
                    id: "time",
                    systemImage: "clock",
                    value: Self.formatMinutes(minutes),
                    helpText: nil
                )
            )
        }

        if let batteryTemp = snapshot.batteryTemperatureC, batteryTemp > 0 {
            metrics.append(
                OverviewMetric(
                    id: "battery-temp",
                    systemImage: "thermometer",
                    value: String(format: "%.1f C", batteryTemp),
                    helpText: "Battery temperature"
                )
            )
        }

        if let health = snapshot.batteryHealthPercent {
            metrics.append(
                OverviewMetric(
                    id: "battery-health",
                    systemImage: "heart.circle",
                    value: String(format: "%.0f%%", health),
                    helpText: "Battery health"
                )
            )
        }

        if let remainingWh = snapshot.batteryRemainingWh {
            metrics.append(
                OverviewMetric(
                    id: "battery-remaining",
                    systemImage: "bolt.circle",
                    value: String(format: "%.1f Wh", remainingWh),
                    helpText: "Remaining capacity"
                )
            )
        }

        return metrics
    }

    @ViewBuilder
    private func overviewMetricLabel(_ metric: OverviewMetric) -> some View {
        let label = Label(metric.value, systemImage: metric.systemImage)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)

        if let helpText = metric.helpText, !helpText.isEmpty {
            label.help(helpText)
        } else {
            label
        }
    }
}

// MARK: - Diagnostics
private struct DiagnosticsSection: View {
    let snapshot: PowerSnapshot

    var body: some View {
        let smc = snapshot.diagnostics.smc

        VStack(alignment: .leading, spacing: 10) {
            let details = snapshot.batteryDetails
            let hasBatteryDetails = details?.hasAnyValue ?? false
            let showBatteryCycleFallback = details?.cycleCount == nil && snapshot.batteryCycleCountSMC != nil
            let showBatterySensors = snapshot.batteryCurrentMA != nil || !snapshot.batteryCellVoltages.isEmpty
            let showBatterySection = hasBatteryDetails || showBatteryCycleFallback || showBatterySensors
            let showAdapterSection = hasAdapterDetails

            if showBatterySection {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Battery")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let name = details?.name {
                        LabeledValueRow(label: "Name", value: name)
                    }
                    if let manufacturer = details?.manufacturer {
                        LabeledValueRow(label: "Manufacturer", value: manufacturer)
                    }
                    if let model = details?.model {
                        LabeledValueRow(label: "Model", value: model)
                    }
                    if let serial = details?.serialNumber {
                        LabeledValueRow(label: "Serial", value: serial)
                    }
                    if let firmware = details?.firmwareVersion {
                        LabeledValueRow(label: "Firmware", value: firmware)
                    }
                    if let hardware = details?.hardwareRevision {
                        LabeledValueRow(label: "Hardware", value: hardware)
                    }
                    if let cycles = details?.cycleCount {
                        LabeledValueRow(label: "Cycles", value: String(cycles))
                    }
                    if showBatteryCycleFallback, let cycles = snapshot.batteryCycleCountSMC {
                        LabeledValueRow(label: "Cycles (SMC)", value: String(cycles))
                    }
                    if let currentMA = snapshot.batteryCurrentMA {
                        LabeledValueRow(
                            label: "Current",
                            value: String(format: "%.2f A", currentMA / 1000.0)
                        )
                    }
                    if !snapshot.batteryCellVoltages.isEmpty {
                        let cells = snapshot.batteryCellVoltages
                            .map { String(format: "%.2f V", $0) }
                            .joined(separator: " · ")
                        LabeledValueRow(label: "Cells", value: cells)
                    }
                }

                Divider()
            }

            if showAdapterSection {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Adapter")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let name = snapshot.adapterInfo?.name {
                        LabeledValueRow(label: "Type", value: name)
                    }

                    if snapshot.adapterWatts > 0 {
                        LabeledValueRow(
                            label: "Rating",
                            value: PowerFormatter.wattsString(snapshot.adapterWatts)
                        )
                    }

                    if snapshot.adapterVoltage > 0 && snapshot.adapterAmperage > 0 {
                        LabeledValueRow(
                            label: "Output",
                            value: String(format: "%.1f V x %.2f A", snapshot.adapterVoltage, snapshot.adapterAmperage)
                        )
                    }

                    if let inputText = adapterInputText {
                        LabeledValueRow(label: "Input (SMC)", value: inputText)
                    }
                }

                Divider()
            }

            let showBatteryTemp = snapshot.batteryTemperatureC == nil && smc.temperature > 0
            let showProcessThermal = snapshot.processThermalLabel != nil
            let showLowPower = snapshot.isLowPowerModeEnabled
            if snapshot.thermalPressure != nil || showBatteryTemp || showProcessThermal || showLowPower {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Thermals")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if showBatteryTemp {
                        LabeledValueRow(
                            label: "Battery temp",
                            value: String(format: "%.1f C", smc.temperature)
                        )
                    }

                    if let pressure = snapshot.thermalPressure {
                        LabeledValueRow(label: "Pressure", value: pressure.displayValue)
                    }

                    if let thermalLabel = snapshot.processThermalLabel {
                        LabeledValueRow(label: "Process state", value: thermalLabel)
                    }

                    if showLowPower {
                        LabeledValueRow(label: "Low power mode", value: "Enabled")
                    }
                }

                Divider()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("SMC")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if smc.chargingControl.key != nil {
                    LabeledValueRow(label: "Charge control", value: smc.chargingControl.displayValue)
                }
                if smc.dischargingControl.key != nil {
                    LabeledValueRow(label: "Adapter discharge", value: smc.dischargingControl.displayValue)
                }
                if smc.chargingStatus > 0 {
                    LabeledValueRow(
                        label: "Charge status",
                        value: String(format: "%.0f", smc.chargingStatus)
                    )
                }
                if let lidClosed = snapshot.lidClosed {
                    LabeledValueRow(label: "Lid", value: lidClosed ? "Closed" : "Open")
                }
                if let platform = snapshot.platformName {
                    LabeledValueRow(label: "Platform", value: platform)
                }
                if !smc.fanReadings.isEmpty {
                    FanReadingsView(fans: smc.fanReadings)
                }
            }

            if let telemetry = snapshot.diagnostics.telemetry {
                let adapterLoss = Double(telemetry.adapterEfficiencyLoss) / 1000.0
                if adapterLoss > 0.01 {
                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("IORegistry")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        LabeledValueRow(
                            label: "Adapter loss",
                            value: PowerFormatter.wattsString(adapterLoss)
                        )
                    }
                }
            }
        }
        .font(.caption)
    }

    private var hasAdapterDetails: Bool {
        snapshot.adapterWatts > 0 ||
        snapshot.adapterInfo != nil ||
        (snapshot.adapterInputVoltage ?? 0) > 0 ||
        (snapshot.adapterInputCurrent ?? 0) > 0 ||
        (snapshot.adapterInputPower ?? 0) > 0
    }

    private var adapterInputText: String? {
        let voltage = snapshot.adapterInputVoltage ?? 0
        let current = snapshot.adapterInputCurrent ?? 0
        let power = snapshot.adapterInputPower ?? 0

        if power > 0, voltage > 0, current > 0 {
            return String(format: "%@ (%.1f V x %.2f A)", PowerFormatter.wattsString(power), voltage, current)
        }
        if power > 0 {
            return PowerFormatter.wattsString(power)
        }
        if voltage > 0, current > 0 {
            return String(format: "%.1f V x %.2f A", voltage, current)
        }
        return nil
    }
}

// MARK: - History
private struct HistorySection: View {
    let history: [PowerHistoryPoint]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = PowerflowPalette(colorScheme: colorScheme)
        let systemSeries = history.map { $0.systemLoad }
        let inputSeries = history.map { $0.inputPower }
        let temperatureSeries = history.map { $0.temperatureC }
        let fanSeries = history.map { $0.fanPercentMax ?? 0 }
        let hasInput = inputSeries.contains { $0 > 0.05 }
        let hasTemp = temperatureSeries.contains { $0 > 0.05 }
        let hasFan = fanSeries.contains { $0 > 0.1 }

        GroupBox {
            if history.count < 2 {
                Text("Collecting samples...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 12) {
                    HistoryChartCard(
                        title: "System Load",
                        values: systemSeries,
                        color: palette.system,
                        formatter: PowerFormatter.wattsString,
                        secondaryValues: hasFan ? fanSeries : nil,
                        secondaryColor: palette.fan,
                        secondaryFormatter: formatFan,
                        secondaryLabel: "Fan %"
                    )

                    if hasTemp || hasInput {
                        HStack(spacing: 12) {
                            if hasTemp {
                                HistoryChartCard(
                                    title: "Primary Temp",
                                    values: temperatureSeries,
                                    color: palette.temperature,
                                    height: 70,
                                    formatter: formatTemp
                                )
                            }

                            if hasInput {
                                HistoryChartCard(
                                    title: "Adapter In",
                                    values: inputSeries,
                                    color: palette.adapter,
                                    height: 70,
                                    formatter: PowerFormatter.wattsString
                                )
                            }
                        }
                    }
                }
            }
        } label: {
            Label("History", systemImage: "chart.xyaxis.line")
        }
    }

    private func formatTemp(_ value: Double) -> String {
        String(format: "%.1f C", value)
    }

    private func formatFan(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }
}

private struct HistoryChartCard: View {
    let title: String
    let values: [Double]
    let color: Color
    var height: CGFloat = 90
    var formatter: (Double) -> String = { String(format: "%.1f", $0) }
    var skipZerosForStats: Bool = true
    var secondaryValues: [Double]? = nil
    var secondaryColor: Color = .secondary
    var secondaryFormatter: (Double) -> String = { String(format: "%.0f", $0) }
    var secondaryLabel: String? = nil

    var body: some View {
        let maxSamples = 240
        let primaryValues = truncatedValues(values, maxSamples: maxSamples)
        let secondarySeries = secondaryValues.map { truncatedValues($0, maxSamples: maxSamples) }
        let statsValues = filteredStatsValues(primaryValues)
        let minVal = statsValues.min()
        let maxVal = statsValues.max()
        let latestVal = primaryValues.last ?? 0
        let secondaryStats = secondaryStatsValues(secondarySeries)
        let secondaryMin = secondaryStats?.min()
        let secondaryMax = secondaryStats?.max()

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatter(latestVal))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
            }

            ZStack(alignment: .leading) {
                PowerSparkline(
                    values: primaryValues,
                    tint: color,
                    secondaryValues: secondarySeries,
                    secondaryTint: secondaryColor
                )

                if let minVal, let maxVal {
                    VStack(alignment: .leading) {
                        Text(formatter(maxVal))
                        Spacer()
                        Text(formatter(minVal))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .opacity(0.6)
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
                }
            }
            .frame(height: height)

            if let secondaryMin, let secondaryMax, let secondaryLabel {
                HStack {
                    Text("\(secondaryLabel) \(secondaryFormatter(secondaryMin))–\(secondaryFormatter(secondaryMax))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func filteredStatsValues(_ values: [Double]) -> [Double] {
        let filtered = skipZerosForStats ? values.filter { $0 > 0.01 } : values
        return filtered.isEmpty ? values : filtered
    }

    private func secondaryStatsValues(_ values: [Double]?) -> [Double]? {
        guard let values else { return nil }
        let filtered = values.filter { $0 > 0.1 }
        return filtered.isEmpty ? nil : filtered
    }

    private func truncatedValues(_ values: [Double], maxSamples: Int) -> [Double] {
        values.count > maxSamples ? Array(values.suffix(maxSamples)) : values
    }
}

private struct PowerSparkline: View {
    let values: [Double]
    let tint: Color
    var secondaryValues: [Double]? = nil
    var secondaryTint: Color = .secondary

    var body: some View {
        GeometryReader { proxy in
            let w = max(proxy.size.width, 1)
            let h = max(proxy.size.height, 1)
            let maxSamples = 240
            let primaryValues = values.count > maxSamples ? Array(values.suffix(maxSamples)) : values
            let clampedSecondaryValues = secondaryValues.map { values in
                values.count > maxSamples ? Array(values.suffix(maxSamples)) : values
            }
            let target = max(2, min(Int(w.rounded(.down)), maxSamples))
            let points = downsample(values: primaryValues, target: target)
            let maxVal = max(points.max() ?? 1.0, 1.0) * 1.1
            let minVal = 0.0
            let range = max(maxVal - minVal, 0.001)
            let secondaryPoints = clampedSecondaryValues.map { downsample(values: $0, target: target) }
            let secondaryRange = 100.0

            ZStack {
                Path { path in
                    guard points.count > 1 else { return }
                    path.move(to: CGPoint(x: 0, y: h))
                    for (i, v) in points.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(points.count - 1)
                        let y = h * (1 - CGFloat((v - minVal) / range))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.35), tint.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Path { path in
                    guard points.count > 1 else { return }
                    for (i, v) in points.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(points.count - 1)
                        let y = h * (1 - CGFloat((v - minVal) / range))
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
                )

                if let secondaryPoints {
                    Path { path in
                        guard secondaryPoints.count > 1 else { return }
                        for (i, v) in secondaryPoints.enumerated() {
                            let x = w * CGFloat(i) / CGFloat(secondaryPoints.count - 1)
                            let clamped = min(max(v, 0), secondaryRange)
                            let y = h * (1 - CGFloat(clamped / secondaryRange))
                            if i == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(
                        secondaryTint.opacity(0.7),
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round, dash: [4, 4])
                    )
                }
            }
        }
    }

    private func downsample(values: [Double], target: Int) -> [Double] {
        guard values.count > target, target > 0 else { return values }
        let chunkSize = Int(ceil(Double(values.count) / Double(target)))
        return stride(from: 0, to: values.count, by: chunkSize).map {
            let end = min($0 + chunkSize, values.count)
            return values[$0..<end].reduce(0, +) / Double(end - $0)
        }
    }
}

// MARK: - Footer actions
private struct FooterActions: View {
    @Binding var showingSettings: Bool

    var body: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingSettings.toggle()
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help(showingSettings ? "Back" : "Settings")

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .help("Quit")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .controlSize(.mini)
    }
}

// MARK: - Common row
private struct LabeledValueRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .monospacedDigit()
        } label: {
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FanReadingsView: View {
    let fans: [SMCFanReading]

    var body: some View {
        Group {
            fanRow(at: 0)
            fanRow(at: 1)
            fanRow(at: 2)
            fanRow(at: 3)
            fanRow(at: 4)
            fanRow(at: 5)
        }
    }

    @ViewBuilder
    private func fanRow(at index: Int) -> some View {
        if fans.indices.contains(index) {
            let fan = fans[index]
            LabeledValueRow(
                label: "Fan \(fan.index)",
                value: fanValue(fan)
            )
        }
    }

    private func fanValue(_ fan: SMCFanReading) -> String {
        let rpmText = String(format: "%.0f RPM", fan.rpm)
        let percentText = fan.percentMax.map { String(format: "%.0f%%", $0) }
        var parts = [rpmText]
        if let percentText {
            parts.append(percentText)
        }
        if let target = fan.targetRpm, target > 0 {
            parts.append(String(format: "target %.0f", target))
        }
        if let minRpm = fan.minRpm, minRpm > 0 {
            parts.append(String(format: "min %.0f", minRpm))
        }
        if let mode = fan.modeLabel {
            parts.append(mode)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Flow
struct PowerFlowView: View {
    let snapshot: PowerSnapshot
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let flow = FlowDiagramState(snapshot: snapshot)
        let shouldAnimate = appState.isPopoverVisible && !reduceMotion
        let palette = PowerflowPalette(colorScheme: colorScheme)
        let batteryEndpointValue: Double? = flow.batteryActive ? nil : flow.batteryValue
        let systemEndpointValue: Double? = flow.showJunctionToSystem ? nil : flow.systemValue

        GeometryReader { geo in
            let size = geo.size
            let railY = size.height * 0.6
            let adapterPoint = CGPoint(x: 30, y: railY)
            let junctionPoint = CGPoint(x: size.width * 0.5, y: railY)
            let systemPoint = CGPoint(x: size.width - 30, y: railY)
            let batteryPoint = CGPoint(x: size.width * 0.5, y: size.height * 0.2)

            let batteryCharging = flow.batteryCharging
            let batteryFlowValue = flow.batteryMagnitude
            let batteryFlowActive = flow.batteryActive
            let batteryFlowColor: Color = batteryCharging ? palette.batteryCharging : palette.batteryDischarging
            let batteryFrom = batteryCharging ? junctionPoint : batteryPoint
            let batteryTo = batteryCharging ? batteryPoint : junctionPoint
            let batteryIconImage = BatteryIconRenderer.dynamicBatteryImage(
                level: snapshot.batteryLevelPrecise,
                overlay: batteryCharging ? .charging : .none
            )

            ZStack {
                FlowConnection(
                    from: adapterPoint,
                    to: junctionPoint,
                    value: flow.adapterToJunction,
                    color: palette.adapter,
                    isActive: flow.showAdapterToJunction,
                    shouldAnimate: shouldAnimate,
                    canvasSize: size
                )

                FlowConnection(
                    from: junctionPoint,
                    to: systemPoint,
                    value: flow.junctionToSystem,
                    color: palette.system,
                    isActive: flow.showJunctionToSystem,
                    shouldAnimate: shouldAnimate,
                    canvasSize: size
                )

                FlowConnection(
                    from: batteryFrom,
                    to: batteryTo,
                    value: batteryFlowValue,
                    color: batteryFlowColor,
                    isActive: batteryFlowActive,
                    shouldAnimate: shouldAnimate,
                    canvasSize: size
                )

                FlowJunction()
                    .position(junctionPoint)

                FlowEndpoint(
                    icon: "powerplug.fill",
                    iconImage: nil,
                    label: "Adapter",
                    value: flow.adapterValue,
                    valueNote: "Capacity",
                    color: palette.adapter,
                    isActive: flow.adapterActive,
                    helpText: nil,
                    layout: .stacked
                )
                .position(adapterPoint)

                FlowEndpoint(
                    icon: "battery.100",
                    iconImage: batteryIconImage,
                    label: "Battery",
                    value: batteryEndpointValue,
                    valueNote: nil,
                    color: batteryFlowColor,
                    isActive: true,
                    helpText: nil,
                    layout: .side
                )
                .position(batteryPoint)

                FlowEndpoint(
                    icon: "macbook.gen2",
                    iconImage: nil,
                    label: "System",
                    value: systemEndpointValue,
                    valueNote: nil,
                    color: .primary,
                    isActive: true,
                    helpText: nil,
                    layout: .stacked
                )
                .position(systemPoint)
            }
        }
        .frame(height: 150)
        .padding(.horizontal, 4)
    }

}

private struct FlowDiagramState {
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

// MARK: - Breakdown
struct ConsumptionCard: View {
    let snapshot: PowerSnapshot
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Total System Draw")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(PowerFormatter.wattsString(smcSystemTotal))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(segments) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: geo.size.width * (segment.value / totalLoad))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(height: 12)

            let legendSegments = segments.filter { $0.value > 0.5 }
            if !legendSegments.isEmpty {
                Grid(horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        ForEach(legendSegments.prefix(2)) { segment in
                            LegendItem(segment: segment)
                        }
                    }
                    if legendSegments.count > 2 {
                        GridRow {
                            ForEach(legendSegments.dropFirst(2)) { segment in
                                LegendItem(segment: segment)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    struct Segment: Identifiable {
        let id: String
        let name: String
        let value: Double
        let color: Color
        let helpText: String?
    }

    private var segments: [Segment] {
        let palette = PowerflowPalette(colorScheme: colorScheme)
        let systemTotal = smcSystemTotal
        let screen = snapshot.screenPowerAvailable ? max(snapshot.screenPower, 0) : 0
        let heatpipe = max(snapshot.heatpipePower, 0)
        let other = max(0, systemTotal - screen - heatpipe)
        let packageLabel = snapshot.packagePowerLabel
        let derivedHelp = snapshot.screenPowerAvailable
            ? "Derived from SMC total minus screen and \(packageLabel)."
            : "Derived from SMC total minus \(packageLabel) (screen unavailable)."

        var list: [Segment] = []
        if snapshot.screenPowerAvailable {
            list.append(Segment(id: "screen", name: "Screen", value: screen, color: palette.screen, helpText: nil))
        }
        list.append(
            Segment(
                id: "package",
                name: packageLabel,
                value: heatpipe,
                color: palette.heatpipe,
                helpText: "Heatpipe-domain reading; proxy for package load."
            )
        )
        list.append(
            Segment(
                id: "other",
                name: "Fans + IO",
                value: other,
                color: palette.other,
                helpText: derivedHelp
            )
        )

        return list.filter { $0.value > 0.01 }
    }

    private var effectiveSystemTotal: Double {
        let smcTotal = max(snapshot.diagnostics.smc.systemTotal, 0)
        return smcTotal
    }

    private var totalLoad: Double {
        max(smcSystemTotal, 1.0)
    }

    private var smcSystemTotal: Double {
        if snapshot.diagnostics.smc.hasSystemTotal, snapshot.diagnostics.smc.systemTotal > 0 {
            return snapshot.diagnostics.smc.systemTotal
        }
        return max(snapshot.systemLoad, 0)
    }
}

// MARK: - Components
struct FlowEndpoint: View {
    enum LayoutStyle {
        case stacked
        case side
    }

    let icon: String
    let iconImage: NSImage?
    let label: String
    let value: Double?
    let valueNote: String?
    let color: Color
    let isActive: Bool
    let helpText: String?
    let layout: LayoutStyle

    var body: some View {
        let iconView = ZStack {
            Circle()
                .fill(color.opacity(isActive ? 0.12 : 0.05))
                .frame(width: 44, height: 44)
            if let iconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 14)
                    .foregroundStyle(color)
            } else {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
            }
        }

        let textView = VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let valueNote {
                Text(valueNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let value {
                Text(PowerFormatter.wattsString(value))
                    .font(.caption2)
                    .bold()
                    .foregroundStyle(.primary)
            }
        }

        let content = Group {
            switch layout {
            case .stacked:
                VStack(spacing: 6) {
                    iconView
                    textView
                }
                .frame(minWidth: 60)
            case .side:
                iconView
                    .overlay(alignment: .trailing) {
                        textView.offset(x: 40)
                    }
            }
        }
        .opacity(isActive ? 1 : 0.35)

        Group {
            if let helpText, !helpText.isEmpty {
                content.help(helpText)
            } else {
                content
            }
        }
    }
}

struct FlowJunction: View {
    var body: some View {
        Circle()
            .fill(Color.secondary.opacity(0.2))
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
            )
    }
}

struct FlowConnection: View {
    let from: CGPoint
    let to: CGPoint
    let value: Double
    let color: Color
    let isActive: Bool
    let shouldAnimate: Bool
    let canvasSize: CGSize
    private let dashPattern: [CGFloat] = [3, 14]
    private let animationDuration: Double = 6.4

    var body: some View {
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let pillOffset = pillOffset(from: from, to: to)

        let path = Path { path in
            path.move(to: from)
            path.addLine(to: to)
        }

        ZStack {
            path
                .stroke(
                    Color.secondary.opacity(0.14),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
                )

            if isActive {
                if shouldAnimate {
                    TimelineView(.periodic(from: .now, by: animationTick)) { context in
                        let phase = dashPhase(for: context.date)
                        path
                            .stroke(
                                color.opacity(0.4),
                                style: StrokeStyle(
                                    lineWidth: 2,
                                    lineCap: .round,
                                    dash: dashPattern,
                                    dashPhase: phase
                                )
                            )
                    }
                } else {
                    path
                        .stroke(
                            color.opacity(0.3),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                }

                if value > 0.05 {
                    FlowValuePill(value: value, color: color)
                        .position(x: mid.x + pillOffset.x, y: mid.y + pillOffset.y)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private var dashCycle: CGFloat {
        dashPattern.reduce(0, +)
    }

    private var animationTick: TimeInterval {
        let refreshRate = Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
        let halfRate = refreshRate * 0.5
        let clamped = min(max(halfRate, 24), 60)
        return 1.0 / clamped
    }

    private func dashPhase(for date: Date) -> CGFloat {
        guard dashCycle > 0 else { return 0 }
        let progress = date.timeIntervalSinceReferenceDate / animationDuration
        let phase = progress.truncatingRemainder(dividingBy: 1) * Double(dashCycle)
        return -CGFloat(phase)
    }

    private func pillOffset(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(sqrt(dx * dx + dy * dy), 0.001)
        var nx = -dy / length
        var ny = dx / length
        if abs(dy) > abs(dx) {
            if nx < 0 {
                nx = -nx
                ny = -ny
            }
        } else if ny > 0 {
            nx = -nx
            ny = -ny
        }
        return CGPoint(x: nx * 10, y: ny * 10)
    }
}

struct FlowValuePill: View {
    let value: Double
    let color: Color

    var body: some View {
        Text(PowerFormatter.wattsString(value))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct LegendItem: View {
    let segment: ConsumptionCard.Segment

    var body: some View {
        let content = HStack(spacing: 6) {
            Circle()
                .fill(segment.color)
                .frame(width: 6, height: 6)

            HStack(spacing: 4) {
                Text(segment.name)
                    .foregroundStyle(.secondary)
                Text(PowerFormatter.wattsString(segment.value))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            .font(.caption2)
        }

        Group {
            if let helpText = segment.helpText, !helpText.isEmpty {
                content.help(helpText)
            } else {
                content
            }
        }
    }
}

private struct PowerflowPalette {
    let colorScheme: ColorScheme

    var adapter: Color { toned(.systemBlue, fraction: 0.25) }
    var system: Color { toned(.systemGreen, fraction: 0.22) }
    var batteryCharging: Color { toned(.systemIndigo, fraction: 0.22) }
    var batteryDischarging: Color { toned(.systemOrange, fraction: 0.24) }
    var screen: Color { toned(.systemCyan, fraction: 0.22) }
    var heatpipe: Color { toned(.systemOrange, fraction: 0.18) }
    var other: Color { toned(.systemGray, fraction: 0.12) }
    var temperature: Color { toned(.systemOrange, fraction: 0.2) }
    var fan: Color { toned(.systemPurple, fraction: 0.2) }

    private func toned(_ base: NSColor, fraction: CGFloat) -> Color {
        guard colorScheme == .light else { return Color(nsColor: base) }
        if let blended = base.blended(withFraction: fraction, of: .black) {
            return Color(nsColor: blended)
        }
        return Color(nsColor: base)
    }
}

private extension BatteryDetails {
    var hasAnyValue: Bool {
        name != nil ||
        manufacturer != nil ||
        model != nil ||
        serialNumber != nil ||
        firmwareVersion != nil ||
        hardwareRevision != nil ||
        cycleCount != nil
    }
}

// MARK: - Previews
struct StatusPopoverView_Previews: PreviewProvider {
    static var previews: some View {
        StatusPopoverView()
            .environmentObject(AppState.shared)
            .padding()
            .background(Color.blue)
    }
}
