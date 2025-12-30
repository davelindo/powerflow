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

        let bodyHeight: CGFloat = 10.6
        let bodyWidth: CGFloat = 14.6
        let capWidth: CGFloat = 2.9
        let capHeight: CGFloat = 5.2
        let capGap: CGFloat = 0.6
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

        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 2.0, yRadius: 2.0)
        let capPath = NSBezierPath(roundedRect: capRect, xRadius: 1.4, yRadius: 1.4)

        let inset: CGFloat = 1.2
        let inner = bodyRect.insetBy(dx: inset, dy: inset)
        if showsPower {
            strokeColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: inner, xRadius: 1.2, yRadius: 1.2).fill()
        }
        if clamped > 0 {
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
            let maxWidth = bodyRect.width * 0.7
            let maxHeight = bodyRect.height * 0.9
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
            if let context = NSGraphicsContext.current {
                let previousOperation = context.compositingOperation
                context.compositingOperation = .destinationOut
                boltImage.draw(in: NSRect(origin: boltOrigin, size: boltSize))
                context.compositingOperation = previousOperation
            }
        }

        bodyPath.lineWidth = 1.1
        bodyPath.stroke()
        capPath.lineWidth = 1.1
        capPath.stroke()

        image.unlockFocus()
        image.isTemplate = true
        cache[cacheKey] = image
        return image
    }
}
