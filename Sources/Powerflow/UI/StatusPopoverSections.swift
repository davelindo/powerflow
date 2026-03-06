import AppKit
import SwiftUI

struct PowerStateAppearance {
    let label: String
    let systemImage: String
    let tint: Color

    init(kind: PowerStateKind) {
        switch kind {
        case .charging:
            label = "Charging"
            systemImage = "bolt.fill"
            tint = Color(nsColor: .systemGreen)
        case .externalPower:
            label = "External Power"
            systemImage = "powerplug.fill"
            tint = Color(nsColor: .systemBlue)
        case .onBattery:
            label = "On Battery"
            systemImage = "battery.25"
            tint = Color(nsColor: .systemOrange)
        }
    }
}

struct FlowSection: View {
    let state: PopoverFlowState
    @State private var showBreakdown = false

    var body: some View {
        CardContainer(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                CardSectionHeader(
                    title: "Power Flow",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )

                PopoverInfoGroup {
                    PowerFlowView(state: state)
                        .frame(height: 158)
                        .padding(.vertical, 8)

                    Divider()

                    DisclosureGroup(isExpanded: $showBreakdown) {
                        ConsumptionCard(snapshot: state.snapshot)
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
    let state: PopoverHistoryState
    @Environment(\.colorScheme) private var colorScheme
    @State private var focus: HistoryFocus = .system

    private enum HistoryFocus: String, CaseIterable, Identifiable {
        case system = "System Load"
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
                        .frame(width: 140)
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
        if !state.hasEnoughSamples {
            emptyState("Collecting samples…")
        } else if let chart = selectedChart {
            VStack(alignment: .leading, spacing: 12) {
                HistoryChartCard(model: chart, palette: palette)

                if focus == .system {
                    Divider()
                    AppEnergyOffendersView(offenders: state.offenders)
                }
            }
        } else {
            emptyState(emptyMessage)
        }
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

    private var selectedChart: PopoverHistoryChartState? {
        switch focus {
        case .system:
            return state.systemChart
        case .thermal:
            return state.thermalChart
        case .adapter:
            return state.adapterChart
        }
    }

    private var emptyMessage: String {
        switch focus {
        case .system:
            return "No power data yet."
        case .thermal:
            return "No thermal data yet."
        case .adapter:
            return "No adapter data yet."
        }
    }
}

struct AppEnergyOffendersView: View {
    let offenders: [PopoverOffenderRowState]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Offenders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Impact")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }

            if offenders.isEmpty {
                Text("No standout app activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(offenders.enumerated()), id: \.element.id) { index, offender in
                    AppEnergyOffenderRow(offender: offender)

                    if index < offenders.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }
}

private struct AppEnergyOffenderRow: View {
    let offender: PopoverOffenderRowState

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AppEnergyOffenderIconView(offender: offender)

            VStack(alignment: .leading, spacing: 3) {
                Text(offender.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(offender.detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(offender.impactText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}

private struct AppEnergyOffenderIconView: View {
    let offender: PopoverOffenderRowState

    var body: some View {
        Group {
            if let iconImage = AppIconCache.shared.cachedImage(for: offender.iconPath) {
                Image(nsImage: iconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
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
    let model: PopoverHistoryChartState
    let palette: PowerflowPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.latestValueText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(primaryColor)
            }

            PowerSparkline(
                values: model.primaryValues,
                tint: primaryColor,
                secondaryValues: model.secondaryValues,
                secondaryTint: palette.fan,
                cacheKey: model.cacheKey
            )
            .frame(height: model.height)
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )

            HStack(spacing: 12) {
                chartStat(label: "Min", value: model.minValueText)
                chartStat(label: "Max", value: model.maxValueText)
                chartStat(label: "Now", value: model.latestValueText)
            }

            if let secondaryRangeText = model.secondaryRangeText,
               let secondaryLabel = model.secondaryLabel {
                chartStat(label: secondaryLabel, value: secondaryRangeText)
            }
        }
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

    private var primaryColor: Color {
        switch model.style {
        case .system:
            return palette.system
        case .thermal:
            return palette.temperature
        case .adapter:
            return palette.adapter
        }
    }
}

struct PowerSparkline: View {
    let values: [Double]
    let tint: Color
    var secondaryValues: [Double]? = nil
    var secondaryTint: Color = .secondary
    let cacheKey: String

    var body: some View {
        GeometryReader { proxy in
            let w = max(proxy.size.width, 1)
            let h = max(proxy.size.height, 1)
            let cachedPoints = SparklinePointCache.shared.points(
                values: values,
                secondaryValues: secondaryValues,
                cacheKey: cacheKey,
                width: w
            )
            let points = cachedPoints.primary
            let maxVal = max(cachedPoints.primaryMax ?? 1.0, 1.0) * 1.1
            let minVal = 0.0
            let range = max(maxVal - minVal, 0.001)
            let secondaryPoints = cachedPoints.secondary
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
}

private final class SparklinePointCache {
    static let shared = SparklinePointCache()

    struct CachedPoints {
        let primary: [Double]
        let primaryMax: Double?
        let secondary: [Double]?
    }

    private var entries: [String: CachedPoints] = [:]

    func points(
        values: [Double],
        secondaryValues: [Double]?,
        cacheKey: String,
        width: CGFloat
    ) -> CachedPoints {
        let maxSamples = 240
        let widthBucket = max(Int((width / 8).rounded(.down)) * 8, 8)
        let cacheID = "\(cacheKey)-\(widthBucket)"
        if let cached = entries[cacheID] {
            return cached
        }

        let target = max(2, min(widthBucket, maxSamples))
        let primary = downsample(values: values, target: target)
        let secondary = secondaryValues.map { downsample(values: $0, target: target) }
        let cached = CachedPoints(primary: primary, primaryMax: primary.max(), secondary: secondary)
        entries[cacheID] = cached
        return cached
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
    @Environment(\.powerflowSnapshotRendering) private var snapshotRendering
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

        if snapshotRendering {
            fallbackBody(cardShape: cardShape)
        } else {
        #if compiler(>=6.2)
            if #available(macOS 26, *) {
                content
                    .padding(padding)
                    .glassEffect(in: cardShape)
            } else {
                fallbackBody(cardShape: cardShape)
            }
        #else
            fallbackBody(cardShape: cardShape)
        #endif
        }
    }

    private func fallbackBody(cardShape: RoundedRectangle) -> some View {
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
    @Environment(\.powerflowSnapshotRendering) private var snapshotRendering
    let title: String
    let systemImage: String
    var isProminent: Bool = false
    let action: () -> Void

    var body: some View {
        if snapshotRendering {
            fallbackButton
        } else {
        #if compiler(>=6.2)
            if #available(macOS 26, *) {
                if isProminent {
                    Button(action: action) { label }
                        .buttonStyle(GlassProminentButtonStyle())
                } else {
                    Button(action: action) { label }
                        .buttonStyle(GlassButtonStyle())
                }
            } else {
                fallbackButton
            }
        #else
            fallbackButton
        #endif
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

    private var fallbackButton: some View {
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

struct PowerFlowView: View {
    let state: PopoverFlowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private let animationTick: TimeInterval = 1.0 / 6.0
    private let animationDuration: Double = 10.0

    var body: some View {
        let flow = state.diagram
        let shouldAnimate = flow.hasActiveFlow && !reduceMotion
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
                level: state.batteryLevelPrecise,
                overlay: state.batteryOverlay
            )

            Group {
                if shouldAnimate {
                    TimelineView(.periodic(from: .now, by: animationTick)) { context in
                        flowDiagram(
                            size: size,
                            flow: flow,
                            palette: palette,
                            adapterPoint: adapterPoint,
                            junctionPoint: junctionPoint,
                            systemPoint: systemPoint,
                            batteryPoint: batteryPoint,
                            batteryFrom: batteryFrom,
                            batteryTo: batteryTo,
                            batteryFlowValue: batteryFlowValue,
                            batteryFlowActive: batteryFlowActive,
                            batteryFlowColor: batteryFlowColor,
                            batteryEndpointValue: batteryEndpointValue,
                            systemEndpointValue: systemEndpointValue,
                            batteryIconImage: batteryIconImage,
                            animationPhase: dashPhase(for: context.date)
                        )
                    }
                } else {
                    flowDiagram(
                        size: size,
                        flow: flow,
                        palette: palette,
                        adapterPoint: adapterPoint,
                        junctionPoint: junctionPoint,
                        systemPoint: systemPoint,
                        batteryPoint: batteryPoint,
                        batteryFrom: batteryFrom,
                        batteryTo: batteryTo,
                        batteryFlowValue: batteryFlowValue,
                        batteryFlowActive: batteryFlowActive,
                        batteryFlowColor: batteryFlowColor,
                        batteryEndpointValue: batteryEndpointValue,
                        systemEndpointValue: systemEndpointValue,
                        batteryIconImage: batteryIconImage,
                        animationPhase: nil
                    )
                }
            }
        }
        .frame(height: 166)
        .padding(.horizontal, 12)
    }

    private func flowDiagram(
        size: CGSize,
        flow: FlowDiagramState,
        palette: PowerflowPalette,
        adapterPoint: CGPoint,
        junctionPoint: CGPoint,
        systemPoint: CGPoint,
        batteryPoint: CGPoint,
        batteryFrom: CGPoint,
        batteryTo: CGPoint,
        batteryFlowValue: Double,
        batteryFlowActive: Bool,
        batteryFlowColor: Color,
        batteryEndpointValue: Double?,
        systemEndpointValue: Double?,
        batteryIconImage: NSImage?,
        animationPhase: CGFloat?
    ) -> some View {
        ZStack {
            FlowConnection(
                from: adapterPoint,
                to: junctionPoint,
                value: flow.adapterToJunction,
                color: palette.adapter,
                isActive: flow.showAdapterToJunction,
                animationPhase: animationPhase,
                canvasSize: size
            )

            FlowConnection(
                from: junctionPoint,
                to: systemPoint,
                value: flow.junctionToSystem,
                color: palette.system,
                isActive: flow.showJunctionToSystem,
                animationPhase: animationPhase,
                canvasSize: size
            )

            FlowConnection(
                from: batteryFrom,
                to: batteryTo,
                value: batteryFlowValue,
                color: batteryFlowColor,
                isActive: batteryFlowActive,
                animationPhase: animationPhase,
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

    private func dashPhase(for date: Date) -> CGFloat {
        let dashCycle = CGFloat(17)
        let progress = date.timeIntervalSinceReferenceDate / animationDuration
        let phase = progress.truncatingRemainder(dividingBy: 1) * Double(dashCycle)
        return -CGFloat(phase)
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
    let animationPhase: CGFloat?
    let canvasSize: CGSize
    private let dashPattern: [CGFloat] = [3, 14]

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
                if let animationPhase {
                    path
                        .stroke(
                            color.opacity(0.4),
                            style: StrokeStyle(
                                lineWidth: 2,
                                lineCap: .round,
                                dash: dashPattern,
                                dashPhase: animationPhase
                            )
                        )
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
            .padding()
            .background(Color.blue)
    }
}
