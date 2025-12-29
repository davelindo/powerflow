import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isFormatDropTarget = false

    private let formatTokens = [
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                menubarSection
                powerSection
                updatesSection
                generalSection
            }
            .padding(20)
        }
        .frame(width: 460, height: 560)
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.title2.weight(.semibold))
            Text("Customize the menubar readout and update cadence.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var menubarSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
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
                        snapshot: appState.snapshot
                    )
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Format")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "{power} | {battery}",
                        text: $appState.settings.statusBarFormat
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                isFormatDropTarget ? Color.accentColor.opacity(0.7) : Color.clear,
                                lineWidth: 1
                            )
                    }
                    .onDrop(of: [UTType.text], isTargeted: $isFormatDropTarget) { providers in
                        handleTokenDrop(providers)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 80), spacing: 6)],
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(formatTokens, id: \.self) { token in
                            TokenPill(text: token)
                        }
                    }
                    Text("Drag tokens into the format field.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
        } label: {
            Label("Menubar", systemImage: "menubar.rectangle")
        }
    }

    private var powerSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                let packageLabel = appState.snapshot.packagePowerLabel
                Picker("Item", selection: $appState.settings.statusBarItem) {
                    ForEach(PowerSettings.StatusBarItem.allCases) { item in
                        let label = item == .heatpipe ? "\(packageLabel) Power" : item.label
                        Text(label).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Show charging power", isOn: $appState.settings.showChargingPower)
            }
        } label: {
            Label("Power Display", systemImage: "gauge.with.dots.needle.67percent")
        }
    }

    private var updatesSection: some View {
        GroupBox {
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
                Text("\(PowerSettings.minimumUpdateInterval, specifier: "%.1f")s to 10s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label("Updates", systemImage: "arrow.clockwise")
        }
    }

    private var generalSection: some View {
        GroupBox {
            Toggle("Launch at login", isOn: $appState.settings.launchAtLogin)
        } label: {
            Label("General", systemImage: "gearshape")
        }
    }

    private func handleTokenDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let token = object as? String else { return }
                    DispatchQueue.main.async {
                        appendToken(token)
                    }
                }
                return true
            }
        }
        return false
    }

    private func appendToken(_ token: String) {
        var format = appState.settings.statusBarFormat
        if !format.isEmpty && !format.hasSuffix(" ") {
            format.append(" ")
        }
        format.append(token)
        appState.settings.statusBarFormat = format
    }
}

private struct TokenPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .onDrag {
                NSItemProvider(object: text as NSString)
            }
    }
}

private struct MenuBarPreview: View {
    let title: String
    let icon: PowerSettings.StatusBarIcon
    let snapshot: PowerSnapshot

    var body: some View {
        HStack(spacing: 6) {
            if let iconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
            } else if let iconName = icon.symbolName {
                Image(systemName: iconName)
                    .font(.caption)
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
    }

    private var iconImage: NSImage? {
        guard icon == .dynamicBattery else { return nil }
        return BatteryIconRenderer.dynamicBatteryImage(
            level: snapshot.batteryLevel,
            showsPower: snapshot.isChargingActive
        )
    }
}
