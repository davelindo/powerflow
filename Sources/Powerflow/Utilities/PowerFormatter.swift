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

    static func dynamicBatteryImage(level: Double, overlay: Overlay) -> NSImage? {
        let clamped = min(max(level, 0), 100)
        let normalized = (clamped * 10).rounded() / 10
        let cacheKey = String(format: "%.1f-%@", normalized, overlay.rawValue)
        if let cached = cache[cacheKey] {
            return cached
        }

        let size = NSSize(width: 24, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            drawBatteryIcon(in: rect, level: normalized, overlay: overlay)
            return true
        }
        image.isTemplate = true
        cache[cacheKey] = image
        return image
    }

    private static func drawBatteryIcon(in rect: NSRect, level: Double, overlay: Overlay) {
        let bodyHeight = rect.height * 0.78
        let bodyWidth = rect.width * 0.72
        let capWidth = rect.width * 0.08
        let capGap = rect.width * 0.03
        let capHeight = bodyHeight * 0.55
        let totalWidth = bodyWidth + capGap + capWidth
        let originX = rect.midX - totalWidth * 0.5
        let originY = rect.midY - bodyHeight * 0.5

        let bodyRect = NSRect(x: originX, y: originY, width: bodyWidth, height: bodyHeight)
        let capRect = NSRect(
            x: bodyRect.maxX + capGap,
            y: bodyRect.midY - capHeight * 0.5,
            width: capWidth,
            height: capHeight
        )

        let strokeColor = NSColor.black
        let bodyRadius = bodyHeight * 0.2
        let capRadius = capHeight * 0.3
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: bodyRadius, yRadius: bodyRadius)
        let capPath = NSBezierPath(roundedRect: capRect, xRadius: capRadius, yRadius: capRadius)

        let inset = max(1, bodyHeight * 0.12)
        let inner = bodyRect.insetBy(dx: inset, dy: inset)
        if level > 0, inner.width > 0 {
            let rawWidth = inner.width * CGFloat(level) / 100.0
            let fillWidth = max(rawWidth, 1)
            let fillRect = NSRect(x: inner.minX, y: inner.minY, width: fillWidth, height: inner.height)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: inner.height * 0.2, yRadius: inner.height * 0.2)
            let fillAlpha: CGFloat = overlay == .none ? 1.0 : 0.6
            strokeColor.withAlphaComponent(fillAlpha).setFill()
            fillPath.fill()
        }

        drawOverlay(in: inner, overlay: overlay)

        strokeColor.setStroke()
        bodyPath.lineWidth = 1.0
        bodyPath.stroke()
        capPath.lineWidth = 1.0
        capPath.stroke()
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

        let pointSize = min(innerRect.width, innerRect.height) * 0.8
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        let overlayImage = symbol.withSymbolConfiguration(config) ?? symbol
        let maxWidth = innerRect.width * 0.78
        let maxHeight = innerRect.height * 0.82
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
