import Charts
import SwiftUI

enum PowerflowDashboardTab: String, CaseIterable, Identifiable {
    case live = "Live"
    case reports = "Reports"
    case devices = "Devices"

    var id: String { rawValue }
}

enum PowerflowReportMode: String, CaseIterable, Identifiable {
    case power = "Power"
    case battery = "Battery"

    var id: String { rawValue }
}

struct PowerflowWideDashboard: View {
    @Environment(\.powerflowSnapshotRendering) private var snapshotRendering
    let state: PopoverViewState
    let onReportRangeChange: (PowerReportRange) -> Void
    let onTabChange: (PowerflowDashboardTab) -> Void
    private let initialReportMode: PowerflowReportMode

    @State private var selectedTab: PowerflowDashboardTab

    init(
        state: PopoverViewState,
        initialSelectedTab: PowerflowDashboardTab = .live,
        initialReportMode: PowerflowReportMode = .power,
        onReportRangeChange: @escaping (PowerReportRange) -> Void = { _ in },
        onTabChange: @escaping (PowerflowDashboardTab) -> Void = { _ in }
    ) {
        self.state = state
        self.initialReportMode = initialReportMode
        self.onReportRangeChange = onReportRangeChange
        self.onTabChange = onTabChange
        _selectedTab = State(initialValue: initialSelectedTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            navigation
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            LinearGradient(
                colors: [
                    Color(nsColor: .systemGreen).opacity(0.025),
                    Color(nsColor: .systemBlue).opacity(0.018),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .onAppear {
            if !snapshotRendering {
                onTabChange(selectedTab)
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if !snapshotRendering {
                onTabChange(tab)
            }
        }
    }

    private var navigation: some View {
        HStack(spacing: 10) {
            Picker("Dashboard", selection: $selectedTab) {
                ForEach(PowerflowDashboardTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 210)

            Spacer()

            Label(statusText, systemImage: statusIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusTint)
                .lineLimit(1)

        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .live:
            WideLiveDashboard(state: state)
                .padding(9)
        case .reports:
            WideReportsDashboard(
                state: state.report,
                initialMode: initialReportMode,
                onRangeChange: onReportRangeChange
            )
            .padding(9)
        case .devices:
            WideDevicesDashboard(state: state.connectedDevices)
                .padding(9)
        }
    }

    private var statusText: String {
        switch state.overview.powerState {
        case .charging: return "Charging"
        case .externalPower: return "On adapter"
        case .onBattery: return "On battery"
        }
    }

    private var statusIcon: String {
        switch state.overview.powerState {
        case .charging: return "bolt.fill"
        case .externalPower: return "powerplug.fill"
        case .onBattery: return "battery.75"
        }
    }

    private var statusTint: Color {
        switch state.overview.powerState {
        case .charging: return Color(nsColor: .systemGreen)
        case .externalPower: return Color(nsColor: .systemBlue)
        case .onBattery: return Color(nsColor: .systemOrange)
        }
    }
}

private struct WideLiveDashboard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let state: PopoverViewState

    var body: some View {
        VStack(spacing: 8) {
            liveSummary
            SankeyPowerFlowView(state: state.flow)
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 270 : 230)
            LiveAppImpactCard(
                rows: state.history.appImpact,
                isEnabled: state.history.isAppImpactEnabled
            )
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 96 : 68)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var liveSummary: some View {
    #if compiler(>=6.2)
        Group {
            if #available(macOS 26, *) {
                GlassEffectContainer(spacing: 4) {
                    liveSummaryContent
                }
            } else {
                liveSummaryContent
            }
        }
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 72 : 50)
    #else
        liveSummaryContent
            .frame(height: dynamicTypeSize.isAccessibilitySize ? 72 : 50)
    #endif
    }

    private var liveSummaryContent: some View {
        HStack(spacing: 0) {
            CompactLiveMetric(
                title: "System load",
                value: snapshot.systemLoadAvailable ? PowerFormatter.wattsString(snapshot.systemLoad) : "--"
            )
            .longHoverDetails(title: "System details", systemImage: "laptopcomputer") {
                SystemInspector(snapshot: snapshot)
            }

            summaryDivider

            CompactLiveMetric(
                title: "Battery",
                value: "\(snapshot.batteryLevel)%"
            )
            .longHoverDetails(title: "Battery details", systemImage: "battery.100") {
                BatteryInspector(snapshot: snapshot)
            }

            summaryDivider

            CompactLiveMetric(
                title: "Health",
                value: snapshot.batteryHealthPercent.map { String(format: "%.0f%%", $0) } ?? "--",
                tint: Color(nsColor: .systemGreen)
            )
            .longHoverDetails(title: "Battery details", systemImage: "heart") {
                BatteryInspector(snapshot: snapshot)
            }

            summaryDivider

            CompactLiveMetric(
                title: "Temperature",
                value: snapshot.temperatureC > 0 ? String(format: "%.0f°", snapshot.temperatureC) : "--",
                tint: Color(nsColor: .systemOrange)
            )
            .longHoverDetails(title: "Thermal details", systemImage: "thermometer.medium") {
                SystemInspector(snapshot: snapshot)
            }
        }
    }

    private var snapshot: PowerSnapshot { state.flow.snapshot }

    private var summaryDivider: some View { Spacer().frame(width: 4) }
}

private struct CompactLiveMetric: View {
    @Environment(\.powerflowSnapshotRendering) private var snapshotRendering

    let title: String
    let value: String
    var tint: Color = .primary

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        if snapshotRendering {
            fallbackMetric
        } else {
        #if compiler(>=6.2)
            if #available(macOS 26, *) {
                metricContent
                    .glassEffect(.regular.tint(tint.opacity(0.08)).interactive(), in: shape)
            } else {
                fallbackMetric
            }
        #else
            fallbackMetric
        #endif
        }
    }

    private var metricContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var fallbackMetric: some View {
        metricContent
            .background(.thinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.12)))
    }
}

private struct SankeyPowerFlowView: View {
    @Environment(\.colorScheme) private var colorScheme

    let state: PopoverFlowState

    var body: some View {
        CardContainer(padding: 0) {
            GeometryReader { proxy in
                let layout = SankeyLayout(size: proxy.size, flow: state.breakdown)
                let palette = PowerflowPalette(colorScheme: colorScheme)

                ZStack {
                    SankeyCanvas(layout: layout, palette: palette)
                    nodeLayer(layout: layout, palette: palette)
                }
            }
            .padding(7)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live power flow")
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private func nodeLayer(layout: SankeyLayout, palette: PowerflowPalette) -> some View {
    #if compiler(>=6.2)
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 14) {
                positionedNodes(layout: layout, palette: palette)
            }
        } else {
            positionedNodes(layout: layout, palette: palette)
        }
    #else
        positionedNodes(layout: layout, palette: palette)
    #endif
    }

    private func positionedNodes(layout: SankeyLayout, palette: PowerflowPalette) -> some View {
        ZStack {
            nodes(layout: layout, palette: palette)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func nodes(layout: SankeyLayout, palette: PowerflowPalette) -> some View {
        if layout.adapterVisible {
            SankeyNode(
                label: "Adapter",
                value: state.breakdown.adapterSourceTotal,
                systemImage: "powerplug.fill",
                tint: palette.adapter,
                active: true
            )
            .longHoverDetails(title: "Adapter details", systemImage: "powerplug.fill") {
                AdapterInspector(snapshot: state.snapshot)
            }
            .position(layout.adapterNode)
        }

        if layout.batterySourceVisible {
            SankeyNode(
                label: "Battery",
                value: state.breakdown.batteryToSystem,
                systemImage: "battery.75",
                tint: palette.batteryDischarging,
                active: true
            )
            .longHoverDetails(title: "Battery details", systemImage: "battery.100") {
                BatteryInspector(snapshot: state.snapshot)
            }
            .position(layout.batterySourceNode)
        }

        SankeyNode(
            label: "System",
            value: state.breakdown.systemLoad,
            systemImage: "laptopcomputer",
            tint: palette.system,
            active: state.breakdown.systemLoad > 0.05
        )
        .longHoverDetails(title: "System details", systemImage: "laptopcomputer") {
            SystemInspector(snapshot: state.snapshot)
        }
        .position(layout.systemNode)

        if layout.batteryDestinationVisible {
            SankeyNode(
                label: "To Battery",
                value: state.breakdown.adapterToBattery,
                systemImage: "battery.100.bolt",
                tint: palette.batteryCharging,
                active: true
            )
            .longHoverDetails(title: "Battery details", systemImage: "battery.100") {
                BatteryInspector(snapshot: state.snapshot)
            }
            .position(layout.batteryDestinationNode)
        }

        if let package = state.breakdown.packagePower {
            SankeyNode(
                label: state.breakdown.packageLabel,
                value: package,
                systemImage: "cpu",
                tint: palette.heatpipe,
                active: true
            )
            .longHoverDetails(title: "\(state.breakdown.packageLabel) details", systemImage: "cpu") {
                PowerChannelInspector(
                    snapshot: state.snapshot,
                    flow: state.breakdown,
                    channel: .package
                )
            }
            .position(layout.packageNode)
        }

        if let display = state.breakdown.displayPower {
            SankeyNode(
                label: "Display",
                value: display,
                systemImage: "display",
                tint: palette.screen,
                active: true
            )
            .longHoverDetails(title: "Display details", systemImage: "display") {
                PowerChannelInspector(
                    snapshot: state.snapshot,
                    flow: state.breakdown,
                    channel: .display
                )
            }
            .position(layout.displayNode)
        }

        SankeyNode(
            label: "Other",
            value: state.breakdown.otherPower,
            systemImage: "ellipsis",
            tint: Color(nsColor: .systemGray),
            active: state.breakdown.otherPower > 0.05
        )
        .longHoverDetails(title: "Other load details", systemImage: "ellipsis") {
            PowerChannelInspector(
                snapshot: state.snapshot,
                flow: state.breakdown,
                channel: .other
            )
        }
        .position(layout.otherNode)
    }

    private var accessibilityValue: String {
        let flow = state.breakdown
        var parts: [String] = []
        if flow.adapterSourceTotal > 0.05 {
            parts.append("adapter supplying \(PowerFormatter.wattsString(flow.adapterSourceTotal))")
        }
        if flow.batteryToSystem > 0.05 {
            parts.append("battery supplying \(PowerFormatter.wattsString(flow.batteryToSystem))")
        }
        parts.append("system using \(PowerFormatter.wattsString(flow.systemLoad))")
        if flow.adapterToBattery > 0.05 {
            parts.append("battery charging at \(PowerFormatter.wattsString(flow.adapterToBattery))")
        }
        if let package = flow.packagePower {
            parts.append("\(flow.packageLabel) \(PowerFormatter.wattsString(package))")
        }
        if let display = flow.displayPower {
            parts.append("display \(PowerFormatter.wattsString(display))")
        }
        parts.append("other derived load \(PowerFormatter.wattsString(flow.otherPower))")
        return parts.joined(separator: ", ")
    }
}

private struct SankeyNode: View {
    @Environment(\.powerflowSnapshotRendering) private var snapshotRendering

    let label: String
    let value: Double
    let systemImage: String
    let tint: Color
    let active: Bool

    private let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)

    var body: some View {
        if snapshotRendering {
            fallbackNode
        } else {
        #if compiler(>=6.2)
            if #available(macOS 26, *) {
                nodeContent
                    .glassEffect(.regular.tint(tint.opacity(0.10)).interactive(), in: shape)
            } else {
                fallbackNode
            }
        #else
            fallbackNode
        #endif
        }
    }

    private var nodeContent: some View {
        VStack(spacing: 1) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(PowerFormatter.wattsString(value))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 64, height: 42)
        .opacity(active ? 1 : 0.55)
    }

    private var fallbackNode: some View {
        nodeContent
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.30)))
            .shadow(color: Color.black.opacity(0.07), radius: 4, y: 2)
    }
}

private struct SankeyLayout {
    let size: CGSize
    let flow: DetailedFlowState
    let adapterNode: CGPoint
    let batterySourceNode: CGPoint
    let systemNode: CGPoint
    let batteryDestinationNode: CGPoint
    let packageNode: CGPoint
    let displayNode: CGPoint
    let otherNode: CGPoint

    init(size: CGSize, flow: DetailedFlowState) {
        self.size = size
        self.flow = flow
        let leftX: CGFloat = 36
        let systemX = size.width * 0.47
        let rightX = size.width - 36
        let centerY = size.height * 0.52

        adapterNode = CGPoint(x: leftX, y: flow.hasBatterySource ? size.height * 0.72 : centerY)
        batterySourceNode = CGPoint(x: leftX, y: flow.adapterSourceTotal > 0.05 ? size.height * 0.28 : centerY)
        systemNode = CGPoint(x: systemX, y: centerY)
        batteryDestinationNode = CGPoint(x: systemX, y: size.height * 0.18)
        packageNode = CGPoint(x: rightX, y: size.height * 0.20)
        displayNode = CGPoint(x: rightX, y: size.height * 0.50)
        otherNode = CGPoint(x: rightX, y: size.height * 0.80)
    }

    var adapterVisible: Bool { flow.adapterSourceTotal > 0.05 }
    var batterySourceVisible: Bool { flow.hasBatterySource }
    var batteryDestinationVisible: Bool { flow.hasBatteryDestination }

    var bands: [SankeyBand] {
        var result: [SankeyBand] = []
        if flow.adapterToSystem > 0.05 {
            result.append(
                SankeyBand(
                    start: CGPoint(x: adapterNode.x + 32, y: adapterNode.y),
                    end: CGPoint(x: systemNode.x - 32, y: systemNode.y),
                    value: flow.adapterToSystem,
                    colorRole: .adapter
                )
            )
        }
        if flow.adapterToBattery > 0.05 {
            result.append(
                SankeyBand(
                    start: CGPoint(x: adapterNode.x + 32, y: adapterNode.y - 5),
                    end: CGPoint(x: batteryDestinationNode.x - 32, y: batteryDestinationNode.y),
                    value: flow.adapterToBattery,
                    colorRole: .batteryCharging
                )
            )
        }
        if flow.batteryToSystem > 0.05 {
            result.append(
                SankeyBand(
                    start: CGPoint(x: batterySourceNode.x + 32, y: batterySourceNode.y),
                    end: CGPoint(x: systemNode.x - 32, y: systemNode.y - 5),
                    value: flow.batteryToSystem,
                    colorRole: .batteryDischarging
                )
            )
        }
        if let package = flow.packagePower {
            result.append(outputBand(to: packageNode, value: package, role: .package, offset: -7))
        }
        if let display = flow.displayPower {
            result.append(outputBand(to: displayNode, value: display, role: .display, offset: 0))
        }
        if flow.otherPower > 0.05 {
            result.append(outputBand(to: otherNode, value: flow.otherPower, role: .other, offset: 7))
        }
        return result
    }

    private func outputBand(
        to node: CGPoint,
        value: Double,
        role: SankeyBand.ColorRole,
        offset: CGFloat
    ) -> SankeyBand {
        SankeyBand(
            start: CGPoint(x: systemNode.x + 32, y: systemNode.y + offset),
            end: CGPoint(x: node.x - 32, y: node.y),
            value: value,
            colorRole: role
        )
    }
}

private struct SankeyBand {
    enum ColorRole {
        case adapter
        case batteryCharging
        case batteryDischarging
        case package
        case display
        case other
    }

    let start: CGPoint
    let end: CGPoint
    let value: Double
    let colorRole: ColorRole
}

private struct SankeyCanvas: View {
    let layout: SankeyLayout
    let palette: PowerflowPalette

    var body: some View {
        Canvas { context, _ in
            let reference = max(layout.flow.systemLoad, layout.flow.adapterSourceTotal, 1)
            for band in layout.bands {
                let color = color(for: band.colorRole)
                let thickness = max(3, min(CGFloat(band.value / reference) * 20, 20))
                let path = ribbonPath(from: band.start, to: band.end, thickness: thickness)
                context.fill(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [
                            color.opacity(0.20),
                            color.opacity(0.52),
                            color.opacity(0.34),
                        ]),
                        startPoint: band.start,
                        endPoint: band.end
                    )
                )
            }
        }
        .accessibilityHidden(true)
    }

    private func ribbonPath(from start: CGPoint, to end: CGPoint, thickness: CGFloat) -> Path {
        let half = thickness / 2
        let controlX = (start.x + end.x) / 2
        var path = Path()
        path.move(to: CGPoint(x: start.x, y: start.y - half))
        path.addCurve(
            to: CGPoint(x: end.x, y: end.y - half),
            control1: CGPoint(x: controlX, y: start.y - half),
            control2: CGPoint(x: controlX, y: end.y - half)
        )
        path.addLine(to: CGPoint(x: end.x, y: end.y + half))
        path.addCurve(
            to: CGPoint(x: start.x, y: start.y + half),
            control1: CGPoint(x: controlX, y: end.y + half),
            control2: CGPoint(x: controlX, y: start.y + half)
        )
        path.closeSubpath()
        return path
    }

    private func color(for role: SankeyBand.ColorRole) -> Color {
        switch role {
        case .adapter: return palette.adapter
        case .batteryCharging: return palette.batteryCharging
        case .batteryDischarging: return palette.batteryDischarging
        case .package: return palette.heatpipe
        case .display: return palette.screen
        case .other: return Color(nsColor: .systemGray)
        }
    }
}

private enum PowerChannel {
    case package
    case display
    case other
}

private struct PowerChannelInspector: View {
    let snapshot: PowerSnapshot
    let flow: DetailedFlowState
    let channel: PowerChannel

    var body: some View {
        VStack(spacing: 7) {
            switch channel {
            case .package:
                InspectorRow(label: "Measured power", value: watts(flow.packagePower))
                InspectorRow(label: "System share", value: share(flow.packagePower))
                InspectorRow(label: "Sensor", value: snapshot.heatpipeKey ?? "Unavailable")
                if snapshot.temperatureC > 0 {
                    InspectorRow(label: "Primary temp", value: String(format: "%.1f °C", snapshot.temperatureC))
                }
            case .display:
                InspectorRow(label: "Measured power", value: watts(flow.displayPower))
                InspectorRow(label: "System share", value: share(flow.displayPower))
                InspectorRow(label: "Sensor available", value: snapshot.screenPowerAvailable ? "Yes" : "No")
                if let lidClosed = snapshot.lidClosed {
                    InspectorRow(label: "Lid", value: lidClosed ? "Closed" : "Open")
                }
            case .other:
                InspectorRow(label: "Derived load", value: watts(flow.otherPower))
                InspectorRow(label: "System share", value: share(flow.otherPower))
                InspectorRow(label: "System load", value: watts(flow.systemLoad))
                InspectorRow(label: "Measured channels", value: watts(measuredChannels))
                InspectorRow(label: "Calculation", value: "System − package − display")
            }
        }
    }

    private var measuredChannels: Double {
        (flow.packagePower ?? 0) + (flow.displayPower ?? 0)
    }

    private func watts(_ value: Double?) -> String {
        guard let value else { return "--" }
        return PowerFormatter.wattsString(value)
    }

    private func share(_ value: Double?) -> String {
        guard let value, flow.systemLoad > 0.05 else { return "--" }
        return String(format: "%.0f%%", value / flow.systemLoad * 100)
    }
}

private struct LiveAppImpactCard: View {
    let rows: [PopoverAppImpactRowState]
    let isEnabled: Bool

    var body: some View {
        DashboardSurface {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Application energy", systemImage: "app.badge.clock")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("Last 10 min · estimated")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !isEnabled {
                    Text("Disabled in Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else if rows.isEmpty {
                    Text("Collecting application activity…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    HStack(spacing: 10) {
                        ForEach(rows) { row in
                            HStack(spacing: 6) {
                                WideAppIcon(path: row.iconPath)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.name)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                    Text(row.energyText)
                                        .font(.caption2.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(Color(nsColor: .systemGreen))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .longHoverDetails(title: row.name, systemImage: "app.badge") {
                                AppImpactRowInspector(row: row)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AppImpactRowInspector: View {
    let row: PopoverAppImpactRowState

    var body: some View {
        VStack(spacing: 7) {
            InspectorRow(label: "Energy used", value: row.energyText)
            InspectorRow(label: "Energy share", value: row.shareText)
            InspectorRow(label: "Peak sampled interval", value: row.peakPowerText)
            InspectorRow(label: "Activity", value: row.detailText)
        }
    }
}

private struct WideAppIcon: View {
    let path: String?

    var body: some View {
        Group {
            if let image = AppIconCache.shared.cachedImage(for: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

private struct DashboardSurface<Content: View>: View {
    @Environment(\.powerflowSnapshotRendering) private var snapshotRendering

    let content: Content

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if snapshotRendering {
            fallbackSurface
        } else {
        #if compiler(>=6.2)
            if #available(macOS 26, *) {
                surfaceContent
                    .glassEffect(.regular, in: shape)
            } else {
                fallbackSurface
            }
        #else
            fallbackSurface
        #endif
        }
    }

    private var surfaceContent: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var fallbackSurface: some View {
        surfaceContent
            .background(.thinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.10)))
    }
}

private struct WideReportsDashboard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let state: PowerReportState
    let onRangeChange: (PowerReportRange) -> Void

    @State private var mode: PowerflowReportMode
    @State private var batteryMetric = BatteryReportMetric.health
    @State private var selectedPowerDate: Date?
    @State private var selectedBatteryDate: Date?

    private enum BatteryReportMetric: String, CaseIterable, Identifiable {
        case health = "Health"
        case temperature = "Temperature"
        case cycles = "Cycles"
        var id: String { rawValue }

        var tint: Color {
            switch self {
            case .health: return Color(nsColor: .systemGreen)
            case .temperature: return Color(nsColor: .systemOrange)
            case .cycles: return Color(nsColor: .systemIndigo)
            }
        }

        var explanation: String {
            switch self {
            case .health: return "Full-charge capacity as a percentage of design capacity."
            case .temperature: return "Primary system temperature observed by Powerflow."
            case .cycles: return "Battery cycle count reported by the battery controller."
            }
        }

        func format(_ value: Double) -> String {
            switch self {
            case .health: return String(format: "%.0f%%", value)
            case .temperature: return String(format: "%.0f°", value)
            case .cycles: return String(format: "%.0f", value)
            }
        }
    }

    init(
        state: PowerReportState,
        initialMode: PowerflowReportMode,
        onRangeChange: @escaping (PowerReportRange) -> Void
    ) {
        self.state = state
        self.onRangeChange = onRangeChange
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        VStack(spacing: 8) {
            controls
            reportContent
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Report", selection: $mode) {
                ForEach(PowerflowReportMode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 124)

            Picker("Range", selection: rangeBinding) {
                ForEach(PowerReportRange.allCases) { range in
                    Text(range.label).tag(range)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
        }
    }

    @ViewBuilder
    private var reportContent: some View {
        if let errorMessage = state.errorMessage, state.points.isEmpty {
            ContentUnavailableView(
                "Reports Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.points.isEmpty {
            ContentUnavailableView(
                state.isLoading ? "Loading Reports" : "Collecting History",
                systemImage: state.isLoading ? "clock.arrow.circlepath" : "chart.xyaxis.line",
                description: Text("Powerflow records local one-minute summaries while it is running.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                if let errorMessage = state.errorMessage {
                    Label {
                        Text("Report refresh failed. Showing saved data.")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .systemOrange).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .help(errorMessage)
                    .accessibilityHint(errorMessage)
                }

                DashboardSurface {
                    if mode == .power {
                        powerChart
                    } else {
                        batteryChart
                    }
                }

                reportSummary
                    .frame(
                        height: dynamicTypeSize.isAccessibilitySize
                            ? (mode == .power ? 128 : 168)
                            : (mode == .power ? 86 : 112)
                    )
            }
        }
    }

    private var powerChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Observed power")
                    .font(.headline)
                Spacer()
                reportLegend
            }

            Chart {
                ForEach(state.points) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("System", point.systemLoad),
                        series: .value("Series", "System")
                    )
                    .foregroundStyle(Color(nsColor: .systemGreen))
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Adapter", point.adapterInput),
                        series: .value("Series", "Adapter")
                    )
                    .foregroundStyle(Color(nsColor: .systemBlue))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [8, 3]))

                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Battery", point.batteryPower),
                        series: .value("Series", "Battery")
                    )
                    .foregroundStyle(Color(nsColor: .systemIndigo))
                    .lineStyle(StrokeStyle(lineWidth: 1.3, dash: [2, 3]))
                }

                if let selectedPowerPoint {
                    RuleMark(x: .value("Selected time", selectedPowerPoint.timestamp))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .annotation(position: .top, spacing: 4) {
                            powerSelectionCard(selectedPowerPoint)
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                        .foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: axisDateFormat)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let watts = value.as(Double.self) {
                            Text(String(format: "%.0f W", watts))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            updatePowerSelection(phase, proxy: proxy, geometry: geometry)
                        }
                }
            }
            .focusable()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Observed power chart")
            .accessibilityValue(powerSelectionAccessibilityValue)
            .accessibilityAdjustableAction(movePowerSelection)
            .frame(maxHeight: .infinity)

            Text("Energy totals cover only minutes recorded while Powerflow was running.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var reportLegend: some View {
        HStack(spacing: 10) {
            legendItem("System", Color(nsColor: .systemGreen), dash: [])
            legendItem("Adapter", Color(nsColor: .systemBlue), dash: [8, 3])
            legendItem("Battery ±", Color(nsColor: .systemIndigo), dash: [2, 3])
        }
    }

    private func legendItem(_ label: String, _ color: Color, dash: [CGFloat]) -> some View {
        HStack(spacing: 4) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 3))
                path.addLine(to: CGPoint(x: 12, y: 3))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: dash))
            .frame(width: 12, height: 6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var batteryChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Battery history")
                    .font(.headline)
                Spacer()
                Picker("Battery metric", selection: $batteryMetric) {
                    ForEach(BatteryReportMetric.allCases) { metric in
                        Text(metric.rawValue).tag(metric)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 188)
            }

            let values = batteryPlotPoints
            if values.isEmpty {
                ContentUnavailableView(
                    "No \(batteryMetric.rawValue) Samples",
                    systemImage: "battery.100",
                    description: Text("This sensor has not reported a valid value in the selected range.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(values) { point in
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            yStart: .value("Baseline", point.baseline),
                            yEnd: .value(batteryMetric.rawValue, point.value)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [batteryMetric.tint.opacity(0.24), batteryMetric.tint.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value(batteryMetric.rawValue, point.value)
                        )
                        .foregroundStyle(batteryMetric.tint)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }

                    if let selectedBatteryPoint {
                        RuleMark(x: .value("Selected time", selectedBatteryPoint.timestamp))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .annotation(position: .top, spacing: 4) {
                                batterySelectionCard(selectedBatteryPoint)
                            }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                            .foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: axisDateFormat)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(batteryMetric.format(number))
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                updateBatterySelection(phase, proxy: proxy, geometry: geometry)
                            }
                    }
                }
                .focusable()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(batteryMetric.rawValue) history chart")
                .accessibilityValue(batterySelectionAccessibilityValue)
                .accessibilityAdjustableAction(moveBatterySelection)
                .frame(maxHeight: .infinity)
            }

            Text(batteryMetric.explanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var batteryPlotPoints: [BatteryPlotPoint] {
        let values = state.points.compactMap { point -> (Date, Double)? in
            switch batteryMetric {
            case .health:
                guard let health = point.batteryHealthPercent else { return nil }
                return (point.timestamp, health)
            case .temperature:
                guard let temperature = point.temperatureC else { return nil }
                return (point.timestamp, temperature)
            case .cycles:
                guard let cycles = point.cycleCount else { return nil }
                return (point.timestamp, Double(cycles))
            }
        }
        let baseline = values.map(\.1).min() ?? 0
        return values.map { BatteryPlotPoint(timestamp: $0.0, value: $0.1, baseline: baseline) }
    }

    private var reportSummary: some View {
        DashboardSurface {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(mode == .power ? "Power summary" : "Battery summary")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if state.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Label(percent(state.summary.coverageFraction), systemImage: "record.circle")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .help("Recording coverage while Powerflow was running")
                }

                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 7) {
                    ForEach(Array(summaryItems.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(item.value)
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                }
            }
        }
    }

    private var summaryColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 8, alignment: .leading),
            count: mode == .power ? 4 : 3
        )
    }

    private var summaryItems: [(label: String, value: String)] {
        if mode == .power {
            return [
                ("Energy", energyText),
                ("Average", PowerFormatter.wattsString(state.summary.averageSystemLoad)),
                ("Sampled peak", PowerFormatter.wattsString(state.summary.peakSystemLoad)),
                ("On adapter", percent(state.summary.externalPowerFraction)),
            ]
        }
        return [
            ("Health", state.summary.latestBatteryHealthPercent.map { String(format: "%.0f%%", $0) } ?? "--"),
            ("Full charge", state.summary.latestFullChargeMAh.map { String(format: "%.0f mAh", $0) } ?? "--"),
            ("Design", state.summary.latestDesignMAh.map { String(format: "%.0f mAh", $0) } ?? "--"),
            ("Cycles", state.summary.latestCycleCount.map(String.init) ?? "--"),
            (
                "Cycle change",
                state.summary.cycleCountResetDetected
                    ? "Reset detected"
                    : state.summary.cycleCountChange.map { "+\($0)" } ?? "--"
            ),
            ("Peak temp", state.summary.peakTemperatureC.map { String(format: "%.1f °C", $0) } ?? "--"),
        ]
    }

    private var energyText: String {
        if state.summary.observedEnergyWh >= 1_000 {
            return String(format: "%.2f kWh", state.summary.observedEnergyWh / 1_000)
        }
        return String(format: "%.1f Wh", state.summary.observedEnergyWh)
    }

    private var axisDateFormat: Date.FormatStyle {
        switch state.range {
        case .hour:
            return .dateTime.minute().second()
        case .day:
            return .dateTime.hour().minute()
        case .week:
            return .dateTime.weekday(.abbreviated).hour()
        case .month, .quarter:
            return .dateTime.month(.abbreviated).day()
        }
    }

    private func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    private var selectedPowerPoint: PowerReportPoint? {
        nearestPoint(to: selectedPowerDate, in: state.points, date: \.timestamp)
    }

    private var selectedBatteryPoint: BatteryPlotPoint? {
        nearestPoint(to: selectedBatteryDate, in: batteryPlotPoints, date: \.timestamp)
    }

    private func updatePowerSelection(
        _ phase: HoverPhase,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        selectedPowerDate = hoverDate(for: phase, proxy: proxy, geometry: geometry)
    }

    private func updateBatterySelection(
        _ phase: HoverPhase,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        selectedBatteryDate = hoverDate(for: phase, proxy: proxy, geometry: geometry)
    }

    private func hoverDate(
        for phase: HoverPhase,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> Date? {
        guard case let .active(location) = phase,
              let plotFrame = proxy.plotFrame else { return nil }
        let frame = geometry[plotFrame]
        guard frame.contains(location) else { return nil }
        return proxy.value(atX: location.x - frame.minX)
    }

    private func movePowerSelection(_ direction: AccessibilityAdjustmentDirection) {
        selectedPowerDate = adjustedDate(
            current: selectedPowerDate,
            dates: state.points.map(\.timestamp),
            direction: direction
        )
    }

    private func moveBatterySelection(_ direction: AccessibilityAdjustmentDirection) {
        selectedBatteryDate = adjustedDate(
            current: selectedBatteryDate,
            dates: batteryPlotPoints.map(\.timestamp),
            direction: direction
        )
    }

    private func adjustedDate(
        current: Date?,
        dates: [Date],
        direction: AccessibilityAdjustmentDirection
    ) -> Date? {
        guard !dates.isEmpty else { return nil }
        let currentIndex = current.flatMap { date in
            dates.indices.min { abs(dates[$0].timeIntervalSince(date)) < abs(dates[$1].timeIntervalSince(date)) }
        } ?? (direction == .decrement ? dates.count : -1)
        switch direction {
        case .increment:
            return dates[min(currentIndex + 1, dates.count - 1)]
        case .decrement:
            return dates[max(currentIndex - 1, 0)]
        @unknown default:
            return current
        }
    }

    private func nearestPoint<Value>(
        to date: Date?,
        in values: [Value],
        date datePath: KeyPath<Value, Date>
    ) -> Value? {
        guard let date else { return nil }
        return values.min {
            abs($0[keyPath: datePath].timeIntervalSince(date))
                < abs($1[keyPath: datePath].timeIntervalSince(date))
        }
    }

    private func powerSelectionCard(_ point: PowerReportPoint) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(point.timestamp, format: .dateTime.hour().minute())
            Text("System \(PowerFormatter.wattsString(point.systemLoad))")
            Text("Adapter \(PowerFormatter.wattsString(point.adapterInput))")
            Text("Battery \(PowerFormatter.wattsString(point.batteryPower))")
        }
        .font(.caption2.monospacedDigit())
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func batterySelectionCard(_ point: BatteryPlotPoint) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(point.timestamp, format: .dateTime.hour().minute())
            Text(batteryMetric.format(point.value))
        }
        .font(.caption2.monospacedDigit())
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var powerSelectionAccessibilityValue: String {
        guard let point = selectedPowerPoint else {
            return "Use VoiceOver increment or decrement to inspect recorded points."
        }
        return "\(point.timestamp.formatted()), system \(PowerFormatter.wattsString(point.systemLoad)), adapter \(PowerFormatter.wattsString(point.adapterInput)), battery \(PowerFormatter.wattsString(point.batteryPower))"
    }

    private var batterySelectionAccessibilityValue: String {
        guard let point = selectedBatteryPoint else {
            return "Use VoiceOver increment or decrement to inspect recorded points."
        }
        return "\(point.timestamp.formatted()), \(batteryMetric.format(point.value))"
    }

    private var rangeBinding: Binding<PowerReportRange> {
        Binding(
            get: { state.range },
            set: { range in onRangeChange(range) }
        )
    }
}

private struct BatteryPlotPoint: Identifiable {
    let timestamp: Date
    let value: Double
    let baseline: Double
    var id: Date { timestamp }
}

private struct WideDevicesDashboard: View {
    let state: PopoverConnectedDevicesState

    private let columns = [
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        if state.devices.isEmpty {
            ContentUnavailableView(
                "No Connected Devices",
                systemImage: "antenna.radiowaves.left.and.right",
                description: Text("Connected Bluetooth and HID battery levels will appear here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Connected power devices")
                        .font(.headline)
                    Spacer()
                    Text(state.summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(state.devices) { device in
                            WideDeviceCard(device: device)
                        }
                    }
                    .padding(.bottom, 2)
                }
                .scrollIndicators(.hidden)

                if state.hiddenDeviceCount > 0 {
                    Text("+\(state.hiddenDeviceCount) more devices")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct WideDeviceCard: View {
    let device: PopoverConnectedDeviceRowState

    var body: some View {
        DashboardSurface {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(device.detailText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Text(device.batteryText)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
        }
        .frame(height: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(device.name)
        .accessibilityValue("\(device.detailText), battery \(device.batteryText)")
    }

    private var icon: String {
        switch device.kind {
        case .headphones: return "airpodspro"
        case .mouse: return "computermouse"
        case .keyboard: return "keyboard"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .gameController: return "gamecontroller"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        }
    }

    private var tint: Color {
        switch device.kind {
        case .headphones: return Color(nsColor: .systemTeal)
        case .mouse: return Color(nsColor: .systemBlue)
        case .keyboard: return Color(nsColor: .systemIndigo)
        case .trackpad: return Color(nsColor: .systemPurple)
        case .gameController: return Color(nsColor: .systemPink)
        case .bluetooth: return Color(nsColor: .systemGray)
        }
    }
}
