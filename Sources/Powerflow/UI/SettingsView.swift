import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    enum Layout {
        case window
        case popover
    }

    @EnvironmentObject private var appState: AppState
    @State private var draggedTemplateIndex: Int?
    @State private var selectedTemplateIndex: Int?
    @State private var dropTargetIndex: Int?
    @State private var templateTokenWidths: [Int: CGFloat] = [:]
    @State private var templateTokens: [FormatToken] = []
    @State private var templateTokensFormat = ""
    @State private var isTrashTargeted = false
    @State private var poofTrigger = 0
    @State private var showTemplateBuilder = false
    let layout: Layout

    init(layout: Layout = .window) {
        self.layout = layout
    }

    struct FormatToken: Identifiable, Hashable {
        let id: String
        let label: String
        let value: String
        let isSeparator: Bool
    }

    struct FormatPreset: Identifiable, Hashable {
        let id: String
        let name: String
        let format: String
    }

    struct BatteryMetric: Identifiable {
        let id: String
        let title: String
        let value: String
    }

    private let metricTokenStrings = [
        "{power}",
        "{battery}",
        "{temp}",
        "{state}",
        "{time}",
        "{health}",
        "{wh}",
        "{input}",
        "{load}",
        "{screen}",
        "{heatpipe}",
        "{smc}",
        "{thermal}",
    ]

    private let formatPresets: [FormatPreset] = [
        FormatPreset(id: "power-battery", name: "Power + Battery", format: "{power} | {battery}"),
        FormatPreset(id: "state-time", name: "State + Time", format: "{state} {time}"),
        FormatPreset(id: "input-load", name: "Input / Load", format: "{input} / {load}"),
        FormatPreset(id: "battery-health", name: "Battery Health", format: "{battery} {health} {wh}"),
    ]

    private var separatorTokens: [FormatToken] {
        [
            FormatToken(id: "sep:space", label: "sp", value: " ", isSeparator: true),
            FormatToken(id: "sep:(", label: "(", value: "(", isSeparator: true),
            FormatToken(id: "sep:)", label: ")", value: ")", isSeparator: true),
            FormatToken(id: "sep::", label: ":", value: ":", isSeparator: true),
            FormatToken(id: "sep:-", label: "-", value: "-", isSeparator: true),
            FormatToken(id: "sep:|", label: "|", value: "|", isSeparator: true),
            FormatToken(id: "sep:/", label: "/", value: "/", isSeparator: true),
        ]
    }

    private var metricTokens: [FormatToken] {
        metricTokenStrings.map {
            FormatToken(id: $0, label: $0, value: $0, isSeparator: false)
        }
    }

    private var currentPresetLabel: String {
        formatPresets.first(where: { $0.format == appState.settings.statusBarFormat })?.name ?? "Custom"
    }

    private var isCompact: Bool {
        layout == .popover
    }

    private var previewTitle: String {
        PowerFormatter.statusTitle(
            snapshot: appState.snapshot,
            settings: appState.settings
        )
    }

    var body: some View {
        ScrollView {
            settingsStack
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(isCompact ? 10 : 20)
        }
        .frame(width: layout == .window ? 460 : nil, height: layout == .window ? 560 : nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .controlSize(isCompact ? .mini : .regular)
        .background(
            Group {
                if layout == .window {
                    LinearGradient(
                        colors: [
                            Color(nsColor: .systemTeal).opacity(0.08),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                } else {
                    Color.clear
                }
            }
        )
        .onAppear {
            syncTemplateTokens(with: appState.settings.statusBarFormat)
        }
        .onChange(of: appState.settings.statusBarFormat) { _, newValue in
            syncTemplateTokens(with: newValue)
        }
        .alert(
            "Launch at Login Failed",
            isPresented: Binding(
                get: { appState.launchAtLoginError != nil },
                set: { if !$0 { appState.launchAtLoginError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.launchAtLoginError ?? "Unable to update launch settings.")
        }
    }

    private var windowTitle: some View {
        HStack {
            Text("Settings")
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 2)
    }

    private func sectionContainer<Content: View>(
        title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        CardContainer(
            padding: isCompact ? 12 : 14,
            tint: layout == .window ? tint : nil
        ) {
            VStack(alignment: .leading, spacing: isCompact ? 10 : 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(layout == .window ? tint : .secondary)

                    Text(title)
                        .font(
                            isCompact
                                ? .caption.weight(.semibold)
                                : .system(size: 15, weight: .semibold, design: .rounded)
                        )
                        .foregroundStyle(.primary)

                    Spacer(minLength: 0)
                }

                content()
            }
        }
    }

    @ViewBuilder
    private func controlSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(isCompact ? 8 : 10)
    }

    @ViewBuilder
    private func settingsRows<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 2)
    }

    private func settingsRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        LabeledContent {
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        } label: {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
    }

    private func settingsValueText(_ value: String) -> some View {
        Text(value)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .monospacedDigit()
    }

    @ViewBuilder
    private var settingsStack: some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 16) {
            if layout == .window {
                windowTitle
            }
            menubarSection
            powerSection
            batterySection
            updatesSection
            generalSection
        }
    }

    private var menubarSection: some View {
        let shouldMeasureWidths = draggedTemplateIndex != nil || dropTargetIndex != nil
        let tokenValues = PowerFormatter.tokenValues(
            snapshot: appState.snapshot,
            settings: appState.settings
        )

        return sectionContainer(
            title: "Menubar",
            systemImage: "menubar.rectangle",
            tint: Color(nsColor: .systemIndigo)
        ) {
            VStack(alignment: .leading, spacing: isCompact ? 10 : 14) {
                settingsRows {
                    settingsRow("Preview") {
                        MenuBarPreview(
                            title: previewTitle,
                            icon: appState.settings.statusBarIcon,
                            snapshot: appState.snapshot,
                            compact: isCompact
                        )
                    }

                    Divider()

                    settingsRow("Preset") {
                        Menu(currentPresetLabel) {
                            ForEach(formatPresets) { preset in
                                Button(preset.name) {
                                    appState.settings.statusBarFormat = preset.format
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                    }

                    Divider()

                    settingsRow("Icon") {
                        Picker("", selection: $appState.settings.statusBarIcon) {
                            ForEach(PowerSettings.StatusBarIcon.allCases) { icon in
                                Text(icon.label).tag(icon)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: isCompact ? 138 : 156)
                    }
                }

                DisclosureGroup(isExpanded: $showTemplateBuilder) {
                    templateEditor(shouldMeasureWidths: shouldMeasureWidths, tokenValues: tokenValues)
                } label: {
                    Label("Custom template", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func templateEditor(
        shouldMeasureWidths: Bool,
        tokenValues: [String: String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            controlSurface {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Template")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            if templateTokens.isEmpty {
                                TemplateEmptyDropTarget()
                                    .onDrop(
                                        of: [UTType.text],
                                        delegate: TemplateTokenDropDelegate(
                                            targetIndex: 0,
                                            tokens: templateTokens,
                                            tokenWidth: 0,
                                            draggedIndex: $draggedTemplateIndex,
                                            selectedIndex: $selectedTemplateIndex,
                                            dropTargetIndex: $dropTargetIndex,
                                            resolveToken: resolveToken(from:),
                                            updateTokens: updateTemplateTokens
                                        )
                                    )
                            } else {
                                ForEach(Array(templateTokens.enumerated()), id: \.offset) { index, token in
                                    if dropTargetIndex == index {
                                        TemplateInsertionMarker()
                                    }
                                    TokenPill(
                                        text: displayLabel(for: token, tokenValues: tokenValues),
                                        payload: token.id,
                                        compact: layout == .popover,
                                        isSelected: selectedTemplateIndex == index,
                                        isTemplate: true,
                                        dragAction: { draggedTemplateIndex = index }
                                    )
                                    .background(alignment: .center) {
                                        if shouldMeasureWidths {
                                            TokenWidthReader(index: index, widths: $templateTokenWidths)
                                        }
                                    }
                                    .onTapGesture {
                                        selectedTemplateIndex = index
                                    }
                                    .onDrop(
                                        of: [UTType.text],
                                        delegate: TemplateTokenDropDelegate(
                                            targetIndex: index,
                                            tokens: templateTokens,
                                            tokenWidth: templateTokenWidths[index] ?? 0,
                                            draggedIndex: $draggedTemplateIndex,
                                            selectedIndex: $selectedTemplateIndex,
                                            dropTargetIndex: $dropTargetIndex,
                                            resolveToken: resolveToken(from:),
                                            updateTokens: updateTemplateTokens
                                        )
                                    )
                                }
                                if dropTargetIndex == templateTokens.count {
                                    TemplateInsertionMarker()
                                }
                            }
                            if !templateTokens.isEmpty {
                                TemplateDropSpace(isActive: dropTargetIndex == templateTokens.count)
                                    .onDrop(
                                        of: [UTType.text],
                                        delegate: TemplateTokenDropDelegate(
                                            targetIndex: templateTokens.count,
                                            tokens: templateTokens,
                                            tokenWidth: 0,
                                            draggedIndex: $draggedTemplateIndex,
                                            selectedIndex: $selectedTemplateIndex,
                                            dropTargetIndex: $dropTargetIndex,
                                            resolveToken: resolveToken(from:),
                                            updateTokens: updateTemplateTokens
                                        )
                                    )
                            }
                        }
                        .padding(.vertical, 2)
                        .animation(.easeInOut(duration: 0.15), value: dropTargetIndex)
                    }
                    if draggedTemplateIndex != nil {
                        TemplateRemoveZone(
                            isTargeted: isTrashTargeted,
                            poofTrigger: poofTrigger
                        )
                        .padding(.top, 4)
                        .onDrop(
                            of: [UTType.text],
                            delegate: TemplateTrashDropDelegate(
                                tokens: templateTokens,
                                draggedIndex: $draggedTemplateIndex,
                                selectedIndex: $selectedTemplateIndex,
                                dropTargetIndex: $dropTargetIndex,
                                isTargeted: $isTrashTargeted,
                                poofTrigger: $poofTrigger,
                                updateTokens: updateTemplateTokens
                            )
                        )
                    }
                }
            }
            .onChange(of: draggedTemplateIndex) { _, newValue in
                if newValue == nil {
                    dropTargetIndex = nil
                }
            }

            controlSurface {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(availableTokens) { token in
                            TokenPill(
                                text: token.label,
                                payload: token.id,
                                compact: layout == .popover,
                                isSelected: selectedTokenIds.contains(token.id)
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var powerSection: some View {
        sectionContainer(
            title: "Power Display",
            systemImage: "gauge.with.dots.needle.67percent",
            tint: Color(nsColor: .systemOrange)
        ) {
            settingsRows {
                settingsRow("Item") {
                    Picker("", selection: $appState.settings.statusBarItem) {
                        ForEach(PowerSettings.StatusBarItem.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: isCompact ? 138 : 156)
                }

                Divider()

                Toggle("Prefer adapter input on power", isOn: $appState.settings.showChargingPower)
                    .toggleStyle(.switch)
                    .padding(.vertical, 10)
            }
        }
    }

    private var batterySection: some View {
        let snapshot = appState.snapshot

        return sectionContainer(
            title: "Battery",
            systemImage: "battery.100",
            tint: Color(nsColor: .systemGreen)
        ) {
            let metrics = batteryMetrics(snapshot: snapshot)

            settingsRows {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                    settingsRow(metric.title) {
                        settingsValueText(metric.value)
                    }

                    if index < metrics.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private var updatesSection: some View {
        sectionContainer(
            title: "Updates",
            systemImage: "arrow.clockwise",
            tint: Color(nsColor: .systemCyan)
        ) {
            settingsRows {
                settingsRow("Refresh") {
                    settingsValueText(String(format: "%.1fs", appState.settings.updateIntervalSeconds))
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    settingsRow("Rate") {
                        settingsValueText(String(format: "%.1fs", appState.settings.updateIntervalSeconds))
                    }

                    Slider(
                        value: $appState.settings.updateIntervalSeconds,
                        in: PowerSettings.minimumUpdateInterval...10.0,
                        step: 0.5
                    )
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var generalSection: some View {
        sectionContainer(
            title: "General",
            systemImage: "gearshape",
            tint: Color(nsColor: .systemGray)
        ) {
            settingsRows {
                Toggle("Launch at login", isOn: $appState.settings.launchAtLogin)
                    .toggleStyle(.switch)
                    .padding(.vertical, 10)
            }
        }
    }

    private func batteryMetrics(snapshot: PowerSnapshot) -> [BatteryMetric] {
        var metrics: [BatteryMetric] = [
            BatteryMetric(id: "level", title: "Battery Level", value: "\(snapshot.batteryLevel)%")
        ]

        if let health = snapshot.batteryHealthPercent {
            metrics.append(
                BatteryMetric(
                    id: "health",
                    title: "Battery Health",
                    value: String(format: "%.0f%%", health)
                )
            )
        }

        if let remainingWh = snapshot.batteryRemainingWh {
            metrics.append(
                BatteryMetric(
                    id: "remaining",
                    title: "Remaining Capacity",
                    value: String(format: "%.1f Wh", remainingWh)
                )
            )
        }

        if let batteryTemperatureC = snapshot.batteryTemperatureC, batteryTemperatureC > 0 {
            metrics.append(
                BatteryMetric(
                    id: "temperature",
                    title: "Battery Temp",
                    value: String(format: "%.1f C", batteryTemperatureC)
                )
            )
        }

        if let cycleCount = snapshot.batteryDetails?.cycleCount ?? snapshot.batteryCycleCountSMC {
            metrics.append(
                BatteryMetric(
                    id: "cycles",
                    title: "Cycle Count",
                    value: "\(cycleCount)"
                )
            )
        }

        return metrics
    }

    private var availableTokens: [FormatToken] {
        metricTokens + separatorTokens
    }

    private var selectedTokenIds: Set<String> {
        Set(templateTokens.map(\.id))
    }

    private func displayLabel(for token: FormatToken, tokenValues: [String: String]) -> String {
        if token.isSeparator {
            if token.id == "sep:space" {
                return "sp"
            }
            return token.value
        }
        if token.id.hasPrefix("lit:") {
            return token.value
        }
        let value = tokenValues[token.value] ?? ""
        return value.isEmpty ? "--" : value
    }

    private func updateTemplateTokens(_ tokens: [FormatToken]) {
        templateTokens = tokens
        let format = tokens.map(\.value).joined()
        templateTokensFormat = format
        if format != appState.settings.statusBarFormat {
            appState.settings.statusBarFormat = format
        }
    }

    private func syncTemplateTokens(with format: String) {
        guard format != templateTokensFormat else { return }
        templateTokensFormat = format
        templateTokens = tokenizeFormat(format)
        if let selectedIndex = selectedTemplateIndex,
           !templateTokens.indices.contains(selectedIndex) {
            selectedTemplateIndex = nil
        }
    }

    private func resolveToken(from payload: String) -> FormatToken? {
        availableTokens.first { $0.id == payload }
    }

    private func tokenizeFormat(_ format: String) -> [FormatToken] {
        let metricLookup = Set(metricTokenStrings)
        let separatorLookup = Dictionary(uniqueKeysWithValues: separatorTokens.map { ($0.value, $0) })
        let spaceToken = separatorTokens.first { $0.id == "sep:space" }

        var tokens: [FormatToken] = []
        var buffer = ""
        var index = format.startIndex

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            let id = "lit:\(buffer)"
            tokens.append(FormatToken(id: id, label: buffer, value: buffer, isSeparator: false))
            buffer = ""
        }

        while index < format.endIndex {
            let ch = format[index]
            if ch == "{", let close = format[index...].firstIndex(of: "}") {
                let tokenText = String(format[index...close])
                if metricLookup.contains(tokenText) {
                    flushBuffer()
                    tokens.append(FormatToken(id: tokenText, label: tokenText, value: tokenText, isSeparator: false))
                    index = format.index(after: close)
                    continue
                }
            }

            if ch == " " {
                flushBuffer()
                if let spaceToken, tokens.last?.id != spaceToken.id {
                    tokens.append(spaceToken)
                }
                index = format.index(after: index)
                continue
            }

            let chString = String(ch)
            if let separator = separatorLookup[chString] {
                flushBuffer()
                tokens.append(separator)
                index = format.index(after: index)
                continue
            }

            buffer.append(ch)
            index = format.index(after: index)
        }

        flushBuffer()
        return tokens
    }
}
