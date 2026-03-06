#!/usr/bin/env swift

import AppKit
import CoreGraphics

private struct AssetRender {
    let inputName: String
    let outputName: String
    let wallpaperPath: String
    let canvasSize: CGSize
    let popoverTopGap: CGFloat
    let popoverTrailingInset: CGFloat
    let statusTitle: String
    let accentColor: NSColor
}

private let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let snapshotsURL = rootURL
    .appendingPathComponent("Tests")
    .appendingPathComponent("PowerflowTests")
    .appendingPathComponent("__Snapshots__", isDirectory: true)
private let assetsURL = rootURL.appendingPathComponent("assets", isDirectory: true)
private let wallpaperDirectory = ProcessInfo.processInfo.environment["POWERFLOW_README_WALLPAPER_DIR"]
    .map(URL.init(fileURLWithPath:))
    ?? rootURL

private let renders: [AssetRender] = [
    AssetRender(
        inputName: "popover-dashboard-light.png",
        outputName: "dashboard.png",
        wallpaperPath: wallpaperDirectory.appendingPathComponent("sonoma.png").path,
        canvasSize: CGSize(width: 760, height: 720),
        popoverTopGap: 18,
        popoverTrailingInset: 26,
        statusTitle: "35W | 82%",
        accentColor: NSColor(calibratedRed: 0.39, green: 0.63, blue: 0.96, alpha: 1.0)
    ),
    AssetRender(
        inputName: "history-section-light.png",
        outputName: "graphs.png",
        wallpaperPath: wallpaperDirectory.appendingPathComponent("sonoma.png").path,
        canvasSize: CGSize(width: 620, height: 596),
        popoverTopGap: 18,
        popoverTrailingInset: 24,
        statusTitle: "35W | 82%",
        accentColor: NSColor(calibratedRed: 0.38, green: 0.74, blue: 0.57, alpha: 1.0)
    ),
    AssetRender(
        inputName: "popover-settings-light.png",
        outputName: "settings.png",
        wallpaperPath: wallpaperDirectory.appendingPathComponent("sonoma.png").path,
        canvasSize: CGSize(width: 760, height: 720),
        popoverTopGap: 18,
        popoverTrailingInset: 26,
        statusTitle: "35W | 82%",
        accentColor: NSColor(calibratedRed: 0.46, green: 0.60, blue: 0.92, alpha: 1.0)
    )
]

for render in renders {
    let inputURL = snapshotsURL.appendingPathComponent(render.inputName)
    let outputURL = assetsURL.appendingPathComponent(render.outputName)

    guard let snapshot = NSImage(contentsOf: inputURL) else {
        fputs("Missing snapshot: \(inputURL.path)\n", stderr)
        exit(1)
    }

    let popoverImage = snapshot
    let image = makeAssetImage(render: render, popoverImage: popoverImage)
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Failed to encode asset: \(outputURL.lastPathComponent)\n", stderr)
        exit(1)
    }

    try pngData.write(to: outputURL, options: .atomic)
}

private func makeAssetImage(render: AssetRender, popoverImage: NSImage) -> NSImage {
    let image = NSImage(size: render.canvasSize)
    let itemSize = statusItemSize(title: render.statusTitle)
    let menuBarFrame = CGRect(x: 0, y: render.canvasSize.height - 32, width: render.canvasSize.width, height: 32)
    let statusClusterOrigin = CGPoint(x: render.canvasSize.width - 104, y: render.canvasSize.height - 22)
    let itemFrame = CGRect(
        x: statusClusterOrigin.x - itemSize.width - 10,
        y: render.canvasSize.height - 29,
        width: itemSize.width,
        height: itemSize.height
    )
    let preferredPopoverX = itemFrame.midX - (popoverImage.size.width * 0.62)
    let popoverFrame = CGRect(
        x: clamped(
            preferredPopoverX,
            min: 22,
            max: render.canvasSize.width - popoverImage.size.width - render.popoverTrailingInset
        ),
        y: render.canvasSize.height - menuBarFrame.height - render.popoverTopGap - popoverImage.size.height,
        width: popoverImage.size.width,
        height: popoverImage.size.height
    )

    image.lockFocus()
    let canvasRect = CGRect(origin: .zero, size: render.canvasSize)

    drawWallpaper(path: render.wallpaperPath, in: canvasRect)
    drawMenuBar(in: menuBarFrame)
    drawStatusCluster(
        origin: statusClusterOrigin,
        title: "Tue 9:41",
        accent: render.accentColor
    )
    drawStatusItem(in: itemFrame, title: render.statusTitle, accent: render.accentColor)
    drawPopoverArrow(
        tipX: itemFrame.midX,
        topY: popoverFrame.maxY - 1,
        fill: shellFillColor
    )
    drawPopover(popoverImage, in: popoverFrame)

    image.unlockFocus()
    return image
}

private let shellFillColor = NSColor(calibratedWhite: 0.96, alpha: 0.96)

private func drawWallpaper(path: String, in rect: CGRect) {
    guard let wallpaper = NSImage(contentsOfFile: path) else {
        NSColor(calibratedRed: 0.87, green: 0.91, blue: 0.96, alpha: 1.0).setFill()
        NSBezierPath(rect: rect).fill()
        return
    }

    let imageSize = wallpaper.size
    let fillScale = max(rect.width / imageSize.width, rect.height / imageSize.height)
    let drawSize = CGSize(width: imageSize.width * fillScale, height: imageSize.height * fillScale)
    let drawRect = CGRect(
        x: rect.midX - (drawSize.width / 2),
        y: rect.midY - (drawSize.height / 2),
        width: drawSize.width,
        height: drawSize.height
    )

    wallpaper.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)

    let overlay = NSGradient(colors: [
        NSColor(calibratedWhite: 1.0, alpha: 0.12),
        NSColor(calibratedWhite: 1.0, alpha: 0.05),
        NSColor(calibratedWhite: 1.0, alpha: 0.16)
    ])!
    overlay.draw(in: rect, angle: -90)
}

private func drawMenuBar(in rect: CGRect) {
    NSColor(calibratedWhite: 1.0, alpha: 0.14).setFill()
    rect.fill()

    NSColor(calibratedWhite: 1.0, alpha: 0.16).setStroke()
    let divider = NSBezierPath()
    divider.move(to: CGPoint(x: rect.minX, y: rect.minY))
    divider.line(to: CGPoint(x: rect.maxX, y: rect.minY))
    divider.lineWidth = 1
    divider.stroke()
}

private func drawStatusItem(in rect: CGRect, title: String, accent: NSColor) {
    let pillPath = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
    NSColor(calibratedWhite: 1.0, alpha: 0.26).setFill()
    pillPath.fill()
    NSColor(calibratedWhite: 1.0, alpha: 0.14).setStroke()
    pillPath.lineWidth = 1
    pillPath.stroke()

    let iconRect = CGRect(x: rect.minX + 10, y: rect.minY + 4.5, width: 22, height: 14)
    drawMenuBattery(in: iconRect, tint: accent)

    let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 0.88)
    ]

    NSString(string: title).draw(
        at: CGPoint(x: rect.minX + 39, y: rect.minY + 4),
        withAttributes: titleAttributes
    )
}

private func statusItemSize(title: String) -> CGSize {
    let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
    ]
    let titleWidth = ceil(NSString(string: title).size(withAttributes: titleAttributes).width)
    return CGSize(width: max(94, titleWidth + 50), height: 22)
}

private func drawStatusCluster(origin: CGPoint, title: String, accent: NSColor) {
    let clusterAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.08, alpha: 0.82)
    ]

    if let wifi = symbolImage(named: "wifi", pointSize: 12) {
        wifi.draw(in: CGRect(x: origin.x, y: origin.y - 1, width: 13, height: 13))
    }

    NSString(string: title).draw(
        at: CGPoint(x: origin.x + 23, y: origin.y - 2),
        withAttributes: clusterAttributes
    )

    if let battery = symbolImage(named: "battery.100", pointSize: 12) {
        battery.draw(in: CGRect(x: origin.x + 88, y: origin.y - 1, width: 22, height: 13))
    }
}

private func drawMenuBattery(in rect: CGRect, tint: NSColor) {
    let bodyRect = CGRect(x: rect.minX, y: rect.minY + 1, width: rect.width - 4, height: rect.height - 2)
    let capRect = CGRect(x: bodyRect.maxX + 1, y: bodyRect.midY - 2.5, width: 3, height: 5)

    let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 3, yRadius: 3)
    NSColor(calibratedWhite: 1.0, alpha: 0.72).setFill()
    bodyPath.fill()

    let chargeRect = bodyRect.insetBy(dx: 2.5, dy: 2.5)
    let fillRect = CGRect(x: chargeRect.minX, y: chargeRect.minY, width: chargeRect.width * 0.78, height: chargeRect.height)
    tint.setFill()
    NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2).fill()
    NSBezierPath(roundedRect: capRect, xRadius: 1.5, yRadius: 1.5).fill()
}

private func drawPopoverArrow(tipX: CGFloat, topY: CGFloat, fill: NSColor) {
    let arrowSize = CGSize(width: 22, height: 12)
    let arrowRect = CGRect(x: tipX - (arrowSize.width / 2), y: topY, width: arrowSize.width, height: arrowSize.height)
    let path = NSBezierPath()
    path.move(to: CGPoint(x: arrowRect.midX, y: arrowRect.maxY))
    path.line(to: CGPoint(x: arrowRect.maxX, y: arrowRect.minY))
    path.line(to: CGPoint(x: arrowRect.minX, y: arrowRect.minY))
    path.close()

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 14
    shadow.shadowOffset = CGSize(width: 0, height: -3)
    shadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.18)
    shadow.set()
    fill.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
}

private func drawPopover(_ popoverImage: NSImage, in rect: CGRect) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = CGSize(width: 0, height: -5)
    shadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.18)
    shadow.set()
    popoverImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
}

private func clamped(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
    Swift.max(min, Swift.min(value, max))
}

private func symbolImage(named name: String, pointSize: CGFloat) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        return nil
    }
    image.isTemplate = true
    return image
}
