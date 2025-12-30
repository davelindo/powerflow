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

    var body: some View {
        let isCompact = layout == .popover

        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 10 : 18) {
                header
                menubarSection
                powerSection
                updatesSection
                generalSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(isCompact ? 10 : 20)
        }
        .frame(width: layout == .window ? 460 : nil, height: layout == .window ? 560 : nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .controlSize(isCompact ? .mini : .regular)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: layout == .popover ? 2 : 4) {
            Text("Settings")
                .font(layout == .popover ? .headline : .title2.weight(.semibold))
            if layout == .window {
                Text("Customize the menubar readout and update cadence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func sectionContainer<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if layout == .popover {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                content()
            }
            .padding(.vertical, 4)
        } else {
            GroupBox {
                content()
            } label: {
                Label(title, systemImage: systemImage)
            }
        }
    }

    private var menubarSection: some View {
        let shouldMeasureWidths = draggedTemplateIndex != nil || dropTargetIndex != nil
        let tokenValues = PowerFormatter.tokenValues(
            snapshot: appState.snapshot,
            settings: appState.settings
        )

        return sectionContainer(title: "Menubar", systemImage: "menubar.rectangle") {
            VStack(alignment: .leading, spacing: layout == .popover ? 8 : 14) {
                HStack {
                    Text("Preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    MenuBarPreview(
                        title: PowerFormatter.statusTitle(
                            snapshot: appState.snapshot,
                            settings: appState.settings
                        ),
                        icon: appState.settings.statusBarIcon,
                        snapshot: appState.snapshot,
                        compact: layout == .popover
                    )
                }

                if layout == .window {
                    Divider()
                }

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
                .onChange(of: draggedTemplateIndex) { _, newValue in
                    if newValue == nil {
                        dropTargetIndex = nil
                    }
                }

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
                    if layout == .window {
                        Text("Drag tokens into the template.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Icon") {
                    Picker("", selection: $appState.settings.statusBarIcon) {
                        ForEach(PowerSettings.StatusBarIcon.allCases) { icon in
                            Label(icon.label, systemImage: icon.symbolName ?? "nosign")
                                .tag(icon)
                        }
                    }
                    .labelsHidden()
                }
            }
        }
    }

    private var powerSection: some View {
        sectionContainer(title: "Power Display", systemImage: "gauge.with.dots.needle.67percent") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Item", selection: $appState.settings.statusBarItem) {
                    ForEach(PowerSettings.StatusBarItem.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Show charging power", isOn: $appState.settings.showChargingPower)
            }
        }
    }

    private var updatesSection: some View {
        sectionContainer(title: "Updates", systemImage: "arrow.clockwise") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Refresh rate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(appState.settings.updateIntervalSeconds, specifier: "%.1f")s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $appState.settings.updateIntervalSeconds,
                    in: PowerSettings.minimumUpdateInterval...10.0,
                    step: 0.5
                )
                if layout == .window {
                    Text("\(PowerSettings.minimumUpdateInterval, specifier: "%.1f")s to 10s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var generalSection: some View {
        sectionContainer(title: "General", systemImage: "gearshape") {
            Toggle("Launch at login", isOn: $appState.settings.launchAtLogin)
        }
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

private struct TokenPill: View {
    let text: String
    let payload: String
    var compact: Bool = false
    var isSelected: Bool = false
    var isTemplate: Bool = false
    var dragAction: (() -> Void)? = nil

    var body: some View {
        let foreground: Color = isTemplate ? .primary : (isSelected ? .primary : .secondary)
        let baseBackground = isTemplate ? Color.secondary.opacity(0.18) : Color.secondary.opacity(0.12)
        let selectedBackground = Color.accentColor.opacity(isTemplate ? 0.28 : 0.18)

        Text(text)
            .font(.caption2.monospaced())
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 1 : 2)
            .background(
                isSelected ? selectedBackground : baseBackground,
                in: Capsule()
            )
            .onDrag {
                dragAction?()
                return NSItemProvider(object: payload as NSString)
            }
    }
}

private struct TemplateTokenDropDelegate: DropDelegate {
    let targetIndex: Int
    let tokens: [SettingsView.FormatToken]
    let tokenWidth: CGFloat
    @Binding var draggedIndex: Int?
    @Binding var selectedIndex: Int?
    @Binding var dropTargetIndex: Int?
    let resolveToken: (String) -> SettingsView.FormatToken?
    let updateTokens: ([SettingsView.FormatToken]) -> Void

    func dropEntered(info: DropInfo) {
        dropTargetIndex = resolvedTargetIndex(info)
    }

    func dropExited(info: DropInfo) {
        if dropTargetIndex == resolvedTargetIndex(info) {
            dropTargetIndex = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedIndex = nil
            dropTargetIndex = nil
        }

        let proposedIndex = resolvedTargetIndex(info)
        if let draggedIndex {
            guard tokens.indices.contains(draggedIndex) else { return false }
            var updated = tokens
            let token = updated.remove(at: draggedIndex)
            var insertIndex = proposedIndex
            if draggedIndex < insertIndex {
                insertIndex = max(0, insertIndex - 1)
            }
            insertIndex = min(insertIndex, updated.count)
            updated.insert(token, at: insertIndex)
            selectedIndex = insertIndex
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                updateTokens(updated)
            }
            return true
        }

        let providers = info.itemProviders(for: [UTType.text])
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String,
                  let token = resolveToken(payload) else { return }
            DispatchQueue.main.async {
                var updated = tokens
                let index = max(0, min(proposedIndex, updated.count))
                updated.insert(token, at: index)
                selectedIndex = index
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    updateTokens(updated)
                }
            }
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropTargetIndex = resolvedTargetIndex(info)
        return DropProposal(operation: draggedIndex == nil ? .copy : .move)
    }

    private func resolvedTargetIndex(_ info: DropInfo) -> Int {
        guard tokenWidth > 0 else { return targetIndex }
        let threshold = tokenWidth * 0.6
        return info.location.x >= threshold ? targetIndex + 1 : targetIndex
    }
}

private struct TemplateInsertionMarker: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 2, height: 16)
            .padding(.horizontal, 2)
    }
}

private struct TemplateDropSpace: View {
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus")
            Text("End")
        }
        .font(.caption2)
        .foregroundStyle(isActive ? Color.accentColor : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isActive ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
        )
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}

private struct TemplateEmptyDropTarget: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.doc")
            Text("Drop tokens here")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }
}

private struct TokenWidthReader: View {
    let index: Int
    @Binding var widths: [Int: CGFloat]

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { updateWidth(proxy.size.width) }
                .onChange(of: proxy.size.width) { _, newValue in
                    updateWidth(newValue)
                }
        }
    }

    private func updateWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        if widths[index] != width {
            widths[index] = width
        }
    }
}

private struct TemplateTrashDropDelegate: DropDelegate {
    let tokens: [SettingsView.FormatToken]
    @Binding var draggedIndex: Int?
    @Binding var selectedIndex: Int?
    @Binding var dropTargetIndex: Int?
    @Binding var isTargeted: Bool
    @Binding var poofTrigger: Int
    let updateTokens: ([SettingsView.FormatToken]) -> Void

    func dropEntered(info: DropInfo) {
        isTargeted = true
        dropTargetIndex = nil
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedIndex = nil
            dropTargetIndex = nil
            isTargeted = false
        }
        guard let draggedIndex, tokens.indices.contains(draggedIndex) else { return false }
        var updated = tokens
        updated.remove(at: draggedIndex)
        if let currentSelected = selectedIndex {
            if currentSelected == draggedIndex {
                selectedIndex = nil
            } else if currentSelected > draggedIndex {
                selectedIndex = currentSelected - 1
            }
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            updateTokens(updated)
        }
        poofTrigger += 1
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct TemplateRemoveZone: View {
    let isTargeted: Bool
    let poofTrigger: Int
    @State private var showPoof = false

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                Text("Drop to remove")
            }
            .font(.caption2)
            .foregroundStyle(isTargeted ? .red : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isTargeted ? Color.red.opacity(0.15) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isTargeted ? Color.red.opacity(0.4) : Color.secondary.opacity(0.2))
            )

            if showPoof {
                PoofBurst()
            }
        }
        .onChange(of: poofTrigger) { _, _ in
            showPoof = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                showPoof = false
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth + size.width > maxWidth, lineWidth > 0 {
                maxLineWidth = max(maxLineWidth, lineWidth)
                totalHeight += lineHeight + spacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                if lineWidth > 0 {
                    lineWidth += spacing
                }
                lineWidth += size.width
                lineHeight = max(lineHeight, size.height)
            }
        }

        maxLineWidth = max(maxLineWidth, lineWidth)
        totalHeight += lineHeight

        let finalWidth = proposal.width ?? maxLineWidth
        return CGSize(width: finalWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct PoofBurst: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.6), lineWidth: 1)
            Circle()
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                .scaleEffect(0.6)
        }
        .frame(width: 18, height: 18)
        .scaleEffect(animate ? 1.6 : 0.6)
        .opacity(animate ? 0 : 1)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) {
                animate = true
            }
        }
    }
}

private struct MenuBarPreview: View {
    let title: String
    let icon: PowerSettings.StatusBarIcon
    let snapshot: PowerSnapshot
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if let iconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: compact ? 10 : 12, height: compact ? 10 : 12)
            } else if let iconName = icon.symbolName {
                Image(systemName: iconName)
                    .font(compact ? .caption2 : .caption)
            }
            Text(title)
                .font(.system(size: compact ? 11 : 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 4 : 6)
        .background(.quaternary, in: Capsule())
    }

    private var iconImage: NSImage? {
        guard icon == .dynamicBattery else { return nil }
        let overlay: BatteryIconRenderer.Overlay
        if snapshot.isChargingActive {
            overlay = .charging
        } else if snapshot.isExternalPowerConnected {
            overlay = .pluggedIn
        } else {
            overlay = .none
        }
        return BatteryIconRenderer.dynamicBatteryImage(
            level: snapshot.batteryLevelPrecise,
            overlay: overlay
        )
    }
}
