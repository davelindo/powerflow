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
        String(format: "%.1f W", value)
    }

    private static func formatStatusTitle(
        snapshot: PowerSnapshot,
        settings: PowerSettings,
        format: String
    ) -> String {
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

        let replacements: [String: String] = [
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
    private static var cache: [String: NSImage] = [:]

    static func dynamicBatteryImage(level: Int, showsPower: Bool) -> NSImage? {
        let clamped = min(max(level, 0), 100)
        let cacheKey = "\(clamped)-\(showsPower ? 1 : 0)"
        if let cached = cache[cacheKey] {
            return cached
        }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let bodyHeight: CGFloat = 9.5
        let bodyWidth: CGFloat = 13.5
        let capWidth: CGFloat = 2.5
        let capHeight: CGFloat = 4.5
        let capGap: CGFloat = 0.8
        let totalWidth = bodyWidth + capGap + capWidth
        let originX = (size.width - totalWidth) * 0.5
        let originY = (size.height - bodyHeight) * 0.5

        let bodyRect = NSRect(x: originX, y: originY, width: bodyWidth, height: bodyHeight)
        let capRect = NSRect(
            x: bodyRect.maxX + capGap,
            y: bodyRect.midY - capHeight * 0.5,
            width: capWidth,
            height: capHeight
        )

        let strokeColor = NSColor.black
        strokeColor.setStroke()

        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 2.2, yRadius: 2.2)
        bodyPath.lineWidth = 1.3
        bodyPath.stroke()

        let capPath = NSBezierPath(roundedRect: capRect, xRadius: 1.2, yRadius: 1.2)
        capPath.lineWidth = 1.3
        capPath.stroke()

        if clamped > 0 {
            let inset: CGFloat = 1.7
            let inner = bodyRect.insetBy(dx: inset, dy: inset)
            let fillWidth = max(inner.width * CGFloat(clamped) / 100.0, 1)
            let fillRect = NSRect(x: inner.minX, y: inner.minY, width: fillWidth, height: inner.height)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 0.8, yRadius: 0.8)
            strokeColor.setFill()
            fillPath.fill()
        }

        if showsPower, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
            let pointSize = min(bodyRect.width, bodyRect.height) * 0.9
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            let boltImage = bolt.withSymbolConfiguration(config) ?? bolt
            let maxWidth = bodyRect.width * 0.65
            let maxHeight = bodyRect.height * 0.85
            let baseSize = boltImage.size
            let scale = min(
                maxWidth / max(baseSize.width, 1),
                maxHeight / max(baseSize.height, 1),
                1
            )
            let boltSize = NSSize(width: baseSize.width * scale, height: baseSize.height * scale)
            let boltOrigin = NSPoint(
                x: bodyRect.midX - boltSize.width * 0.5,
                y: bodyRect.midY - boltSize.height * 0.5
            )
            boltImage.draw(in: NSRect(origin: boltOrigin, size: boltSize))
        }

        image.unlockFocus()
        image.isTemplate = true
        cache[cacheKey] = image
        return image
    }
}
