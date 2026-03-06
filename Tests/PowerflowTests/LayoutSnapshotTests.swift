import AppKit
import SwiftUI
import XCTest
@testable import Powerflow

@MainActor
final class LayoutSnapshotTests: XCTestCase {
    func testDashboardPopoverLayout() throws {
        try requireSnapshotMode()
        let appState = LayoutSnapshotFixtures.makeAppState()
        try LayoutSnapshotHarness.assertSnapshot(
            named: "popover-dashboard-light",
            size: LayoutSnapshotHarness.popoverSize,
            view: StatusPopoverView(
                appState: appState,
                popoverStore: appState.popoverStore
            )
            .environmentObject(appState)
            .snapshotEnvironment()
        )
    }

    func testSettingsPopoverLayout() throws {
        try requireSnapshotMode()
        let appState = LayoutSnapshotFixtures.makeAppState()
        try LayoutSnapshotHarness.assertSnapshot(
            named: "popover-settings-light",
            size: LayoutSnapshotHarness.popoverSize,
            view: StatusPopoverView(
                appState: appState,
                popoverStore: appState.popoverStore,
                initialShowingSettings: true
            )
            .environmentObject(appState)
            .snapshotEnvironment()
        )
    }

    func testHistorySectionLayout() throws {
        try requireSnapshotMode()
        let appState = LayoutSnapshotFixtures.makeAppState()
        try LayoutSnapshotHarness.assertSnapshot(
            named: "history-section-light",
            size: LayoutSnapshotHarness.featureAssetSize,
            view: FeatureAssetShell {
                HistorySection(state: appState.popoverStore.state.history)
                    .snapshotEnvironment()
            }
        )
    }

    private func requireSnapshotMode() throws {
        guard LayoutSnapshotHarness.isRecording || LayoutSnapshotHarness.isVerificationEnabled else {
            throw XCTSkip(
                "Layout snapshots are opt-in. Use scripts/update_layout_snapshots.sh to record or scripts/verify_layout_snapshots.sh to verify."
            )
        }
    }
}

private enum LayoutSnapshotFixtures {
    static func makeAppState() -> AppState {
        var settings = PowerSettings.default
        settings.statusBarItem = .system
        settings.showChargingPower = false
        settings.statusBarFormat = "{power} | {battery} | {temp}"
        settings.statusBarIcon = .dynamicBattery

        let snapshot = makeSnapshot()
        let history = makeHistory()

        return AppState.snapshotTesting(
            settings: settings,
            snapshot: snapshot,
            history: history
        )
    }

    private static func makeSnapshot() -> PowerSnapshot {
        var snapshot = PowerSnapshot.empty
        snapshot.timestamp = Date(timeIntervalSinceReferenceDate: 781_488_000)
        snapshot.isCharging = true
        snapshot.isExternalPowerConnected = true
        snapshot.batteryLevel = 82
        snapshot.batteryLevelPrecise = 81.7
        snapshot.timeRemainingMinutes = 154
        snapshot.systemIn = 61.8
        snapshot.systemLoad = 34.6
        snapshot.batteryPower = 5.3
        snapshot.adapterPower = 67.1
        snapshot.adapterInputVoltage = 20.3
        snapshot.adapterInputCurrent = 3.2
        snapshot.adapterInputPower = 65.0
        snapshot.efficiencyLoss = 2.7
        snapshot.screenPower = 7.8
        snapshot.screenPowerAvailable = true
        snapshot.heatpipePower = 15.4
        snapshot.heatpipeKey = "PHPC"
        snapshot.adapterWatts = 68
        snapshot.adapterVoltage = 20.2
        snapshot.adapterAmperage = 3.25
        snapshot.batteryDetails = BatteryDetails(
            name: "Built-in Battery",
            manufacturer: "Apple",
            model: "A2997",
            serialNumber: "SNAPSHOT",
            firmwareVersion: "1.0.0",
            hardwareRevision: "1",
            cycleCount: 173
        )
        snapshot.isAppleSilicon = true
        snapshot.socName = "Apple M4 Pro"
        snapshot.temperatureC = 36.8
        snapshot.temperatureSource = "HID"
        snapshot.batteryTemperatureC = 27.4
        snapshot.batteryHealthPercent = 89
        snapshot.batteryRemainingWh = 50.4
        snapshot.batteryCurrentMA = 2550
        snapshot.batteryCellVoltages = [4.12, 4.13, 4.12]
        snapshot.batteryCycleCountSMC = 173
        snapshot.batteryPercentSMC = 82
        snapshot.lidClosed = false
        snapshot.platformName = "MacBookPro"
        snapshot.processThermalState = .nominal
        snapshot.isLowPowerModeEnabled = false
        snapshot.thermalPressure = ThermalPressure(level: 0)
        snapshot.appEnergyOffenders = [
            AppEnergyOffender(
                groupID: "com.apple.Safari",
                primaryPID: 4102,
                name: "Safari",
                iconPath: "/System/Applications/Safari.app",
                processCount: 7,
                impactScore: 16.8,
                cpuPercent: 14.0,
                memoryBytes: 1_842_225_152,
                pageinsPerSecond: 0.4
            ),
            AppEnergyOffender(
                groupID: "com.apple.dt.Xcode",
                primaryPID: 5120,
                name: "Xcode",
                iconPath: "/Applications/Xcode.app",
                processCount: 1,
                impactScore: 8.6,
                cpuPercent: 6.3,
                memoryBytes: 1_120_034_816,
                pageinsPerSecond: 0.1
            ),
            AppEnergyOffender(
                groupID: "com.apple.ActivityMonitor",
                primaryPID: 6132,
                name: "Activity Monitor",
                iconPath: "/System/Applications/Utilities/Activity Monitor.app",
                processCount: 3,
                impactScore: 4.1,
                cpuPercent: 2.1,
                memoryBytes: 458_227_712,
                pageinsPerSecond: 0.0
            ),
        ]

        var smc = SMCPowerData.empty
        smc.systemTotal = 34.6
        smc.hasSystemTotal = true
        smc.heatpipe = 15.4
        smc.hasHeatpipe = true
        smc.temperature = 27.4
        smc.hasTemperature = true
        smc.chargingStatus = 1
        smc.hasChargingStatus = true
        smc.deliveryRate = 61.8
        smc.hasDeliveryRate = true
        smc.fanReadings = [
            SMCFanReading(
                index: 0,
                rpm: 1820,
                maxRpm: 7200,
                minRpm: 1200,
                targetRpm: nil,
                modeRaw: 0,
                percentMax: 25.3
            )
        ]
        snapshot.diagnostics = PowerDiagnostics(smc: smc, telemetry: nil)

        return snapshot
    }

    private static func makeHistory() -> [PowerHistoryPoint] {
        let base = Date(timeIntervalSinceReferenceDate: 781_488_000 - (11 * 15))
        let systemLoads: [Double] = [18, 22, 25, 21, 28, 31, 29, 33, 37, 35, 34, 34.6]
        let screenLoads: [Double] = [6.2, 6.5, 6.7, 6.8, 7.1, 7.5, 7.6, 7.8, 7.9, 7.8, 7.8, 7.8]
        let inputLoads: [Double] = [42, 45, 47, 46, 52, 54, 55, 58, 61, 60, 61.4, 61.8]
        let temperatures: [Double] = [31.8, 32.4, 33.1, 33.4, 34.0, 34.6, 35.1, 35.8, 36.2, 36.4, 36.7, 36.8]
        let fanPercents: [Double] = [14, 14, 15, 16, 18, 19, 20, 22, 23, 24, 25, 25.3]

        return systemLoads.indices.map { index in
            PowerHistoryPoint(
                timestamp: base.addingTimeInterval(Double(index) * 15),
                systemLoad: systemLoads[index],
                screenPower: screenLoads[index],
                inputPower: inputLoads[index],
                temperatureC: temperatures[index],
                fanPercentMax: fanPercents[index]
            )
        }
    }
}

private enum LayoutSnapshotHarness {
    private static let modeFileURL = URL(fileURLWithPath: "/tmp/powerflow-layout-snapshot-mode")
    private static let mode = SnapshotMode.current(
        environment: ProcessInfo.processInfo.environment,
        arguments: CommandLine.arguments,
        modeFileURL: modeFileURL
    )
    static let isRecording = mode == .record
    static let isVerificationEnabled = mode == .verify
    static let popoverSize = CGSize(width: 402, height: 590)
    static let featureAssetSize = CGSize(width: 370, height: 504)
    private static let meanDeltaTolerance = 0.003
    private static let changedPixelTolerance = 0.015

    static func assertSnapshot<V: View>(
        named name: String,
        size: CGSize,
        view: V,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let snapshotsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__", isDirectory: true)
        let referenceURL = snapshotsDirectory.appendingPathComponent("\(name).png")
        let image = renderImage(view: view, size: size)
        let pngData = try pngData(for: image)

        if isRecording {
            try FileManager.default.createDirectory(
                at: snapshotsDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try pngData.write(to: referenceURL, options: .atomic)
            return
        }

        guard FileManager.default.fileExists(atPath: referenceURL.path) else {
            XCTFail(
                "Missing reference snapshot at \(referenceURL.path). Run scripts/update_layout_snapshots.sh first.",
                file: file,
                line: line
            )
            return
        }

        let expectedData = try Data(contentsOf: referenceURL)
        let comparison = try compare(actual: pngData, expected: expectedData)
        guard comparison.meanDelta <= meanDeltaTolerance,
              comparison.changedPixelRatio <= changedPixelTolerance else {
            let actualAttachment = XCTAttachment(data: pngData, uniformTypeIdentifier: "public.png")
            actualAttachment.name = "\(name)-actual"
            actualAttachment.lifetime = .keepAlways

            let expectedAttachment = XCTAttachment(data: expectedData, uniformTypeIdentifier: "public.png")
            expectedAttachment.name = "\(name)-expected"
            expectedAttachment.lifetime = .keepAlways

            let diffAttachment = XCTAttachment(data: comparison.diffPNGData, uniformTypeIdentifier: "public.png")
            diffAttachment.name = "\(name)-diff"
            diffAttachment.lifetime = .keepAlways

            XCTContext.runActivity(named: "Snapshot mismatch: \(name)") { activity in
                activity.add(actualAttachment)
                activity.add(expectedAttachment)
                activity.add(diffAttachment)
            }

            XCTFail(
                "Snapshot \(name) changed. mean delta: \(String(format: "%.4f", comparison.meanDelta)), changed pixels: \(String(format: "%.2f%%", comparison.changedPixelRatio * 100))",
                file: file,
                line: line
            )
            return
        }
    }

    private static func renderImage<V: View>(view: V, size: CGSize) -> NSImage {
        let hostingView = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height)
        )
        hostingView.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hostingView

        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.displayIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            fatalError("Unable to create bitmap rep for layout snapshot")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        window.orderOut(nil)
        return image
    }

    private static func pngData(for image: NSImage) throws -> Data {
        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.encodingFailed
        }
        return pngData
    }

    private static func compare(actual: Data, expected: Data) throws -> SnapshotComparison {
        let actualBitmap = try normalizedBitmap(from: actual)
        let expectedBitmap = try normalizedBitmap(from: expected)

        guard actualBitmap.width == expectedBitmap.width,
              actualBitmap.height == expectedBitmap.height else {
            throw SnapshotError.sizeMismatch(
                actual: CGSize(width: actualBitmap.width, height: actualBitmap.height),
                expected: CGSize(width: expectedBitmap.width, height: expectedBitmap.height)
            )
        }

        var totalDelta = 0.0
        var changedPixels = 0
        var diffPixels = [UInt8](repeating: 0, count: actualBitmap.pixels.count)
        let pixelCount = actualBitmap.width * actualBitmap.height

        for pixelIndex in 0..<pixelCount {
            let offset = pixelIndex * 4
            let redDelta = abs(Int(actualBitmap.pixels[offset]) - Int(expectedBitmap.pixels[offset]))
            let greenDelta = abs(Int(actualBitmap.pixels[offset + 1]) - Int(expectedBitmap.pixels[offset + 1]))
            let blueDelta = abs(Int(actualBitmap.pixels[offset + 2]) - Int(expectedBitmap.pixels[offset + 2]))
            let alphaDelta = abs(Int(actualBitmap.pixels[offset + 3]) - Int(expectedBitmap.pixels[offset + 3]))

            let pixelDelta = Double(redDelta + greenDelta + blueDelta + alphaDelta) / (255.0 * 4.0)
            totalDelta += pixelDelta

            if pixelDelta > 0.02 {
                changedPixels += 1
                diffPixels[offset] = 255
                diffPixels[offset + 1] = 0
                diffPixels[offset + 2] = 255
                diffPixels[offset + 3] = 255
            } else {
                diffPixels[offset] = expectedBitmap.pixels[offset]
                diffPixels[offset + 1] = expectedBitmap.pixels[offset + 1]
                diffPixels[offset + 2] = expectedBitmap.pixels[offset + 2]
                diffPixels[offset + 3] = 255
            }
        }

        let meanDelta = totalDelta / Double(pixelCount)
        let changedPixelRatio = Double(changedPixels) / Double(pixelCount)
        let diffImage = try pngData(
            for: image(
                from: NormalizedBitmap(
                    width: actualBitmap.width,
                    height: actualBitmap.height,
                    pixels: diffPixels
                )
            )
        )

        return SnapshotComparison(
            meanDelta: meanDelta,
            changedPixelRatio: changedPixelRatio,
            diffPNGData: diffImage
        )
    }

    private static func normalizedBitmap(from pngData: Data) throws -> NormalizedBitmap {
        guard let image = NSImage(data: pngData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw SnapshotError.decodingFailed
        }

        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SnapshotError.decodingFailed
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return NormalizedBitmap(width: width, height: height, pixels: pixels)
    }

    private static func image(from bitmap: NormalizedBitmap) -> NSImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(data: Data(bitmap.pixels) as CFData)!
        let cgImage = CGImage(
            width: bitmap.width,
            height: bitmap.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bitmap.width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!

        let image = NSImage(size: NSSize(width: bitmap.width, height: bitmap.height))
        image.addRepresentation(NSBitmapImageRep(cgImage: cgImage))
        return image
    }
}

private extension View {
    func snapshotEnvironment() -> some View {
        environment(\.powerflowSnapshotRendering, true)
            .environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
    }
}

private struct FeatureAssetShell<Content: View>: View {
    @ViewBuilder let content: () -> Content

    private let shellShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            content()
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(
            width: LayoutSnapshotHarness.featureAssetSize.width,
            height: LayoutSnapshotHarness.featureAssetSize.height,
            alignment: .topLeading
        )
        .background(
            Color(nsColor: NSColor(calibratedWhite: 0.96, alpha: 0.96)),
            in: shellShape
        )
        .overlay(
            shellShape.stroke(
                Color(nsColor: NSColor(calibratedWhite: 1.0, alpha: 0.72)),
                lineWidth: 1
            )
        )
        .clipShape(shellShape)
        .compositingGroup()
    }
}

private enum SnapshotMode: String {
    case record
    case verify

    static func current(
        environment: [String: String],
        arguments: [String],
        modeFileURL: URL
    ) -> SnapshotMode? {
        if environment["POWERFLOW_RECORD_SNAPSHOTS"] == "1" || arguments.contains("--powerflow-record-snapshots") {
            return .record
        }

        if environment["POWERFLOW_ENABLE_LAYOUT_SNAPSHOTS"] == "1" || arguments.contains("--powerflow-verify-snapshots") {
            return .verify
        }

        guard let modeValue = try? String(contentsOf: modeFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let mode = SnapshotMode(rawValue: modeValue) else {
            return nil
        }

        return mode
    }
}

private struct NormalizedBitmap {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

private struct SnapshotComparison {
    let meanDelta: Double
    let changedPixelRatio: Double
    let diffPNGData: Data
}

private enum SnapshotError: Error {
    case encodingFailed
    case decodingFailed
    case sizeMismatch(actual: CGSize, expected: CGSize)
}
