import AppKit
import SwiftUI

struct PowerStateAppearance {
    let label: String
    let systemImage: String
    let tint: Color

    init(snapshot: PowerSnapshot) {
        if snapshot.isChargingActive {
            label = "Charging"
            systemImage = "bolt.fill"
            tint = Color(nsColor: .systemGreen)
        } else if snapshot.isExternalPowerConnected {
            label = "External Power"
            systemImage = "powerplug.fill"
            tint = Color(nsColor: .systemBlue)
        } else {
            label = "On Battery"
            systemImage = "battery.25"
            tint = Color(nsColor: .systemOrange)
        }
    }
}

struct FlowSection: View {
    let snapshot: PowerSnapshot
    @State private var showBreakdown = false

    var body: some View {
        CardContainer(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                CardSectionHeader(
                    title: "Power Flow",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )

                PopoverInfoGroup {
                    PowerFlowView(snapshot: snapshot)
                        .frame(height: 158)
                        .padding(.vertical, 8)

                    Divider()

                    DisclosureGroup(isExpanded: $showBreakdown) {
                        ConsumptionCard(snapshot: snapshot)
                            .padding(.top, 6)
                            .padding(.bottom, 8)
                    } label: {
                        Label("Breakdown", systemImage: "chart.bar.doc.horizontal")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                }
            }
        }
    }
}

struct HistorySection: View {
    let history: [PowerHistoryPoint]
    @Environment(\.colorScheme) private var colorScheme
    @State private var focus: HistoryFocus = .system

    private enum HistoryFocus: String, CaseIterable, Identifiable {
        case system = "Power"
        case thermal = "Thermal"
        case adapter = "Adapter"

        var id: String { rawValue }
    }

    var body: some View {
        let palette = PowerflowPalette(colorScheme: colorScheme)

        CardContainer(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                CardSectionHeader(
                    title: "History"
                )

                PopoverInfoGroup {
                    PopoverInfoRow("View") {
                        Picker("", selection: $focus) {
                            ForEach(HistoryFocus.allCases) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    }

                    Divider()

                    historyContent(palette: palette)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func historyContent(palette: PowerflowPalette) -> some View {
        if history.count < 2 {
            emptyState("Collecting samples…")
        } else {
            let systemSeries = history.map { $0.systemLoad }
            let inputSeries = history.map { $0.inputPower }
            let temperatureSeries = history.map { $0.temperatureC }
            let fanSeries = history.map { $0.fanPercentMax ?? 0 }
            let hasFan = fanSeries.contains { $0 > 0.1 }

            switch focus {
            case .system:
                if !systemSeries.contains(where: { $0 > 0.05 }) {
                    emptyState("No power data yet.")
                } else {
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
                }
            case .thermal:
                if !temperatureSeries.contains(where: { $0 > 0.05 }) {
                    emptyState("No thermal data yet.")
                } else {
                    HistoryChartCard(
                        title: "Primary Temp",
                        values: temperatureSeries,
                        color: palette.temperature,
                        height: 90,
                        formatter: formatTemp,
                        secondaryValues: hasFan ? fanSeries : nil,
                        secondaryColor: palette.fan,
                        secondaryFormatter: formatFan,
                        secondaryLabel: "Fan %"
                    )
                }
            case .adapter:
                if !inputSeries.contains(where: { $0 > 0.05 }) {
                    emptyState("No adapter data yet.")
                } else {
                    HistoryChartCard(
                        title: "Adapter In",
                        values: inputSeries,
                        color: palette.adapter,
                        height: 90,
                        formatter: PowerFormatter.wattsString
                    )
                }
            }
        }
    }

    private func formatTemp(_ value: Double) -> String {
        String(format: "%.1f C", value)
    }

    private func formatFan(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private func emptyState(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PopoverInfoGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.clear)
        )
    }
}

struct PopoverInfoRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        LabeledContent {
            content
                .frame(maxWidth: .infinity, alignment: .trailing)
        } label: {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
    }
}

struct PopoverValueText: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .monospacedDigit()
    }
}

struct HistoryChartCard: View {
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

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatter(latestVal))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
            }

            PowerSparkline(
                values: primaryValues,
                tint: color,
                secondaryValues: secondarySeries,
                secondaryTint: secondaryColor
            )
            .frame(height: height)
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )

            HStack(spacing: 12) {
                chartStat(label: "Min", value: minVal.map(formatter) ?? "--")
                chartStat(label: "Max", value: maxVal.map(formatter) ?? "--")
                chartStat(label: "Now", value: formatter(latestVal))
            }

            if let secondaryMin, let secondaryMax, let secondaryLabel {
                chartStat(label: secondaryLabel, value: "\(secondaryFormatter(secondaryMin))–\(secondaryFormatter(secondaryMax))")
            }
        }
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

    private func chartStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PowerSparkline: View {
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

struct FooterActions: View {
    @Binding var showingSettings: Bool

    var body: some View {
        HStack(spacing: 10) {
            FooterActionButton(
                title: showingSettings ? "Done" : "Settings",
                systemImage: showingSettings ? "checkmark" : "gearshape"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingSettings.toggle()
                }
            }
            .help(showingSettings ? "Return to live view" : "Open settings")

            Spacer()

            FooterActionButton(title: "Quit", systemImage: "power") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
            .help("Quit")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .controlSize(.mini)
    }
}

struct CardContainer<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let content: Content
    let padding: CGFloat
    let tint: Color?

    init(
        padding: CGFloat = 14,
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.padding = padding
        self.tint = tint
    }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        if #available(macOS 26, *) {
            content
                .padding(padding)
                .glassEffect(in: cardShape)
        } else {
            content
                .padding(padding)
                .background {
                    ZStack {
                        if let tint {
                            cardShape.fill(
                                LinearGradient(
                                    colors: [
                                        tint.opacity(colorScheme == .light ? 0.06 : 0.08),
                                        tint.opacity(colorScheme == .light ? 0.02 : 0.03),
                                        Color.clear,
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        }

                        cardShape.fill(.thinMaterial)
                        cardShape.strokeBorder(Color.white.opacity(colorScheme == .light ? 0.10 : 0.06))
                    }
                }
        }
    }
}

struct CardSectionHeader: View {
    let title: String
    let systemImage: String?

    init(
        title: String,
        systemImage: String? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let systemImage {
                Label(title, systemImage: systemImage)
                    .font(.headline)
            } else {
                Text(title)
                    .font(.headline)
            }

            Spacer(minLength: 12)
        }
    }
}

struct PowerStateBadge: View {
    let appearance: PowerStateAppearance
    var compact: Bool = false

    var body: some View {
        Label(appearance.label, systemImage: appearance.systemImage)
            .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .foregroundStyle(appearance.tint)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 4 : 6)
            .background(appearance.tint.opacity(compact ? 0.14 : 0.16), in: Capsule())
    }
}

struct FooterActionButton: View {
    let title: String
    let systemImage: String
    var isProminent: Bool = false
    let action: () -> Void

    var body: some View {
        if #available(macOS 26, *) {
            if isProminent {
                Button(action: action) { label }
                .buttonStyle(GlassProminentButtonStyle())
            } else {
                Button(action: action) { label }
                .buttonStyle(GlassButtonStyle())
            }
        } else {
            Button(action: action) {
                label
                    .foregroundStyle(isProminent ? Color.accentColor : .primary)
                    .background(backgroundStyle, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(isProminent ? 0.12 : 0.08))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var label: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    private var backgroundStyle: some ShapeStyle {
        if isProminent {
            return AnyShapeStyle(.tint.opacity(0.18))
        }

        return AnyShapeStyle(.thinMaterial)
    }
}

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
            let railY = size.height * 0.68
            let adapterPoint = CGPoint(x: 42, y: railY)
            let junctionPoint = CGPoint(x: size.width * 0.5, y: railY)
            let systemPoint = CGPoint(x: size.width - 42, y: railY)
            let batteryPoint = CGPoint(x: size.width * 0.5, y: size.height * 0.18)

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
                    layout: .stacked
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
        .frame(height: 166)
        .padding(.horizontal, 12)
    }
}

struct FlowDiagramState {
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

struct ConsumptionCard: View {
    let snapshot: PowerSnapshot
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let visibleSegments = segments

        VStack(alignment: .leading, spacing: 10) {
            PopoverInfoRow("Total") {
                PopoverValueText(PowerFormatter.wattsString(smcSystemTotal))
            }

            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(visibleSegments) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: geo.size.width * (segment.value / totalLoad))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(height: 12)

            PopoverInfoGroup {
                ForEach(Array(visibleSegments.enumerated()), id: \.element.id) { index, segment in
                    PopoverInfoRow(segment.name) {
                        PopoverValueText(PowerFormatter.wattsString(segment.value))
                    }

                    if index < visibleSegments.count - 1 {
                        Divider()
                    }
                }
            }
        }
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
                .frame(width: 48, height: 48)
            if let iconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 15)
                    .foregroundStyle(color)
            } else {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
            }
        }

        let textAlignment: HorizontalAlignment = layout == .stacked ? .center : .leading
        let textView = VStack(alignment: textAlignment, spacing: 1) {
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
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .multilineTextAlignment(layout == .stacked ? .center : .leading)

        let content = Group {
            switch layout {
            case .stacked:
                VStack(spacing: 8) {
                    iconView
                    textView
                }
                .frame(minWidth: 72)
            case .side:
                HStack(spacing: 10) {
                    iconView
                    textView
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
        return CGPoint(x: nx * 14, y: ny * 14)
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

struct PowerflowPalette {
    let colorScheme: ColorScheme

    var adapter: Color { toned(.systemBlue, fraction: 0.25) }
    var system: Color { toned(.systemGreen, fraction: 0.22) }
    var batteryCharging: Color { toned(.systemIndigo, fraction: 0.22) }
    var batteryDischarging: Color { toned(.systemOrange, fraction: 0.24) }
    var screen: Color { toned(.systemCyan, fraction: 0.22) }
    var heatpipe: Color { toned(.systemOrange, fraction: 0.18) }
    var other: Color { toned(.systemGray, fraction: 0.12) }
    var temperature: Color { toned(.systemOrange, fraction: 0.2) }
    var fan: Color { toned(.systemTeal, fraction: 0.2) }

    private func toned(_ base: NSColor, fraction: CGFloat) -> Color {
        guard colorScheme == .light else { return Color(nsColor: base) }
        if let blended = base.blended(withFraction: fraction, of: .black) {
            return Color(nsColor: blended)
        }
        return Color(nsColor: base)
    }
}

struct StatusPopoverView_Previews: PreviewProvider {
    static var previews: some View {
        StatusPopoverView()
            .environmentObject(AppState.shared)
            .padding()
            .background(Color.blue)
    }
}
