import AppKit
import Foundation

enum PowerFormatter {
    static func statusTitle(snapshot: PowerSnapshot, settings: PowerSettings) -> String {
        let format = settings.statusBarFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFormat = format.isEmpty ? PowerSettings.default.statusBarFormat : format
        let title = formatStatusTitle(snapshot: snapshot, settings: settings, format: resolvedFormat)
        return title.isEmpty
            ? formatStatusTitle(snapshot: snapshot, settings: settings, format: PowerSettings.default.statusBarFormat)
            : title
    }

    static func displayPower(snapshot: PowerSnapshot, settings: PowerSettings) -> Double {
        displayPowerValue(snapshot: snapshot, settings: settings) ?? 0
    }

    static func displayPowerValue(snapshot: PowerSnapshot, settings: PowerSettings) -> Double? {
        if snapshot.isOnExternalPower && settings.showChargingPower {
            return snapshot.systemIn
        }
        switch settings.statusBarItem {
        case .system:
            return snapshot.systemLoad
        case .screen:
            return snapshot.screenPowerAvailable ? snapshot.screenPower : nil
        case .heatpipe:
            return snapshot.heatpipeKey != nil ? snapshot.heatpipePower : nil
        }
    }

    static func displayPowerString(snapshot: PowerSnapshot, settings: PowerSettings) -> String {
        guard let value = displayPowerValue(snapshot: snapshot, settings: settings) else {
            return "--"
        }
        return wattsString(value)
    }

    static func wattsString(_ value: Double) -> String {
        String(format: "%.0fW", value)
    }

    static func tokenValues(snapshot: PowerSnapshot, settings: PowerSettings) -> [String: String] {
        let powerValue = displayPowerString(snapshot: snapshot, settings: settings)
        let batteryValue = "\(snapshot.batteryLevel)%"
        let tempValue = snapshot.temperatureC > 0 ? String(format: "%.1f C", snapshot.temperatureC) : ""
        let stateValue = snapshot.powerStateLabel
        let timeValue = formattedTimeRemaining(snapshot.timeRemainingMinutes)
        let healthValue = snapshot.batteryHealthPercent.map { String(format: "%.0f%%", $0) } ?? ""
        let whValue = snapshot.batteryRemainingWh.map { String(format: "%.1f Wh", $0) } ?? ""
        let thermalValue = snapshot.thermalPressure?.label ?? ""
        let screenValue = snapshot.screenPowerAvailable ? wattsString(snapshot.screenPower) : ""
        let heatpipeValue = (snapshot.heatpipeKey != nil && snapshot.heatpipePower > 0)
            ? wattsString(snapshot.heatpipePower)
            : ""
        let smcValue = snapshot.diagnostics.smc.hasSystemTotal
            ? wattsString(snapshot.diagnostics.smc.systemTotal)
            : ""

        return [
            "{power}": powerValue,
            "{battery}": batteryValue,
            "{temp}": tempValue,
            "{state}": stateValue,
            "{time}": timeValue,
            "{health}": healthValue,
            "{wh}": whValue,
            "{input}": wattsString(snapshot.systemIn),
            "{load}": wattsString(snapshot.systemLoad),
            "{screen}": screenValue,
            "{heatpipe}": heatpipeValue,
            "{smc}": smcValue,
            "{thermal}": thermalValue,
        ]
    }

    private static func formatStatusTitle(
        snapshot: PowerSnapshot,
        settings: PowerSettings,
        format: String
    ) -> String {
        let replacements = tokenValues(snapshot: snapshot, settings: settings)
        var result = format
        for (token, value) in replacements {
            result = result.replacingOccurrences(of: token, with: value)
        }
        result = result.replacingOccurrences(of: "  ", with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formattedTimeRemaining(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "" }
        let hours = minutes / 60
        let remaining = minutes % 60
        if hours > 0 {
            return "\(hours)h \(remaining)m"
        }
        return "\(remaining)m"
    }
}

enum BatteryIconRenderer {
    enum Overlay: String {
        case none
        case charging
        case pluggedIn
    }

    private static var cache: [String: NSImage] = [:]

    static func dynamicBatteryImage(level: Int, overlay: Overlay) -> NSImage? {
        let clamped = min(max(level, 0), 100)
        let cacheKey = "\(clamped)-\(overlay.rawValue)"
        if let cached = cache[cacheKey] {
            return cached
        }

        let size = NSSize(width: 24, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            drawBatteryIcon(in: rect, level: clamped, overlay: overlay)
            return true
        }
        image.isTemplate = true
        cache[cacheKey] = image
        return image
    }

    private static func drawBatteryIcon(in rect: NSRect, level: Int, overlay: Overlay) {
        guard let context = NSGraphicsContext.current else { return }
        let pointSize = rect.height * 1.15
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let outlineSymbol = NSImage(
            systemSymbolName: "battery.0",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(config),
        let fillSymbol = NSImage(
            systemSymbolName: "battery.100",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(config) else { return }

        let baseSize = outlineSymbol.size
        let baseScale = min(rect.width / baseSize.width, rect.height / baseSize.height)
        let scale = baseScale * 1.12
        let symbolRect = NSRect(
            x: rect.midX - baseSize.width * scale * 0.5,
            y: rect.midY - baseSize.height * scale * 0.5,
            width: baseSize.width * scale,
            height: baseSize.height * scale
        )

        if let mask = fillSymbol.cgImage(forProposedRect: nil, context: context, hints: nil), level > 0 {
            context.cgContext.saveGState()
            context.cgContext.clip(to: symbolRect, mask: mask)
            let fillWidth = symbolRect.width * CGFloat(level) / 100.0
            let fillRect = NSRect(
                x: symbolRect.minX,
                y: symbolRect.minY,
                width: fillWidth,
                height: symbolRect.height
            )
            NSColor.black.setFill()
            context.cgContext.fill(fillRect)
            context.cgContext.restoreGState()
        }

        outlineSymbol.draw(in: symbolRect)
        drawOverlay(in: symbolRect, overlay: overlay)
    }

    private static func drawOverlay(in innerRect: NSRect, overlay: Overlay) {
        let symbolName: String?
        switch overlay {
        case .none:
            symbolName = nil
        case .charging:
            symbolName = "bolt.fill"
        case .pluggedIn:
            symbolName = "powerplug.fill"
        }

        guard let symbolName,
              let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return }

        let pointSize = min(innerRect.width, innerRect.height) * 0.6
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        let overlayImage = symbol.withSymbolConfiguration(config) ?? symbol
        let maxWidth = innerRect.width * 0.6
        let maxHeight = innerRect.height * 0.6
        let baseSize = overlayImage.size
        let scale = min(
            maxWidth / max(baseSize.width, 1),
            maxHeight / max(baseSize.height, 1),
            1
        )
        let overlaySize = NSSize(width: baseSize.width * scale, height: baseSize.height * scale)
        let overlayOrigin = NSPoint(
            x: innerRect.midX - overlaySize.width * 0.5,
            y: innerRect.midY - overlaySize.height * 0.5
        )

        overlayImage.draw(in: NSRect(origin: overlayOrigin, size: overlaySize))
    }
}
