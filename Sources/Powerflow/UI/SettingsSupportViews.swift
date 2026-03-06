import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TokenPill: View {
    let text: String
    let payload: String
    var compact: Bool = false
    var isSelected: Bool = false
    var isTemplate: Bool = false
    var dragAction: (() -> Void)? = nil

    var body: some View {
        let foreground: Color = isTemplate ? .primary : (isSelected ? .primary : .secondary)
        let baseBackground = isTemplate ? Color.white.opacity(0.10) : Color.white.opacity(0.06)
        let selectedBackground = Color.accentColor.opacity(isTemplate ? 0.26 : 0.16)
        let strokeColor = isSelected ? Color.accentColor.opacity(0.34) : Color.white.opacity(0.08)

        Text(text)
            .font(.caption2.monospaced())
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 1 : 2)
            .background(
                isSelected ? selectedBackground : baseBackground,
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(strokeColor)
            )
            .onDrag {
                dragAction?()
                return NSItemProvider(object: payload as NSString)
            }
    }
}

struct TemplateTokenDropDelegate: DropDelegate {
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

struct TemplateInsertionMarker: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 2, height: 16)
            .padding(.horizontal, 2)
    }
}

struct TemplateDropSpace: View {
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

struct TemplateEmptyDropTarget: View {
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

struct TokenWidthReader: View {
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

struct TemplateTrashDropDelegate: DropDelegate {
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

struct TemplateRemoveZone: View {
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

struct FlowLayout: Layout {
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

struct PoofBurst: View {
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

struct MenuBarPreview: View {
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
        .background(
            Capsule()
                .fill(Color.white.opacity(0.10))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.10))
        )
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

struct SettingsChoiceChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.06))
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.accentColor.opacity(0.34) : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }
}

struct SettingsIconChoiceButton: View {
    let icon: PowerSettings.StatusBarIcon
    let snapshot: PowerSnapshot
    let isSelected: Bool
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: compact ? 8 : 10) {
                Group {
                    if let iconImage {
                        Image(nsImage: iconImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: compact ? 24 : 28, height: compact ? 14 : 16)
                    } else if let symbolName = icon.symbolName {
                        Image(systemName: symbolName)
                            .font(.system(size: compact ? 15 : 17, weight: .semibold))
                    } else {
                        Image(systemName: "nosign")
                            .font(.system(size: compact ? 15 : 17, weight: .semibold))
                    }
                }
                .foregroundStyle(isSelected ? Color.accentColor : .primary)

                Text(icon.label)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 72 : 82)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 8 : 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.30) : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
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

struct SettingsMetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08))
        )
    }
}
