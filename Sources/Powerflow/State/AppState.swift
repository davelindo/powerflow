import Combine
import CoreGraphics
import Foundation

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var snapshot: PowerSnapshot
    @Published private(set) var statusSnapshot: PowerSnapshot
    @Published private(set) var statusBarTitle: String
    @Published var launchAtLoginError: String?
    @Published var isPopoverVisible: Bool = false {
        didSet {
            handlePopoverVisibilityChange()
        }
    }
    @Published var settings: PowerSettings {
        didSet {
            handleSettingsChange(from: oldValue)
        }
    }

    private let settingsStore = PowerSettingsStore()
    private let warmupStore = PowerWarmupStore()
    private let monitor: PowerMonitor
    private let powerSourceMonitor: PowerSourceMonitor
    let popoverStore: PopoverStateStore
    private var isApplyingSettingsChange = false
    private let historyCapacity = PowerflowConstants.historyCapacity
    private var latestSnapshot: PowerSnapshot
    private var historyBuffer: [PowerHistoryPoint]
    private var pendingSnapshot: PendingSnapshot?
    private var lastHistorySampleAt: Date?
    private var lastConsistencyRetryAt: Date?
    private var modelIdentifier: String? {
        SystemInfoReader.hardwareModel()
    }

    private struct PendingSnapshot {
        var bestSnapshot: PowerSnapshot
        var bestScore: Double
        var startedAt: Date
        var attempts: Int
    }

    private struct HistoryChartSecondarySeries {
        let values: [Double]
        let formatter: (Double) -> String
        let label: String
    }

    private struct SnapshotTestState {
        let settings: PowerSettings
        let snapshot: PowerSnapshot
        let history: [PowerHistoryPoint]
    }

    private static let overviewHourMinuteFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let overviewMinuteFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let offenderMemoryFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private init() {
        let storedSettings = settingsStore.load()
        let initialSnapshot = PowerSnapshot.empty
        settings = storedSettings
        snapshot = initialSnapshot
        statusSnapshot = initialSnapshot
        latestSnapshot = initialSnapshot
        historyBuffer = []
        popoverStore = PopoverStateStore()
        statusBarTitle = PowerFormatter.statusTitle(
            snapshot: initialSnapshot,
            settings: storedSettings
        )

        let monitor = PowerMonitor(provider: MacPowerDataProvider())
        self.monitor = monitor
        powerSourceMonitor = PowerSourceMonitor { [weak monitor] in
            monitor?.triggerImmediateUpdate()
        }
        popoverStore.update(
            makePopoverState(
                snapshot: initialSnapshot,
                settings: storedSettings
            )
        )
        monitor.onUpdate = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.apply(snapshot)
            }
        }
        monitor.onWarmupCompleted = { [weak self] in
            guard let self else { return }
            self.warmupStore.markCompleted(for: self.modelIdentifier)
        }

        syncLaunchAtLoginPreference()
        let modelIdentifier = self.modelIdentifier
        let shouldWarmup = warmupStore.shouldWarmup(for: modelIdentifier)
        if shouldWarmup {
            warmupStore.markWarmupAttempted(for: modelIdentifier)
        }
        monitor.start(with: storedSettings, isPopoverVisible: isPopoverVisible, warmup: shouldWarmup)
        powerSourceMonitor.start()
    }

    private init(snapshotTestState: SnapshotTestState) {
        let seededSettings = snapshotTestState.settings
        let seededSnapshot = snapshotTestState.snapshot
        let seededHistory = snapshotTestState.history

        settings = seededSettings
        snapshot = seededSnapshot
        statusSnapshot = seededSnapshot
        latestSnapshot = seededSnapshot
        historyBuffer = seededHistory
        lastHistorySampleAt = seededHistory.last?.timestamp
        popoverStore = PopoverStateStore()
        statusBarTitle = PowerFormatter.statusTitle(
            snapshot: seededSnapshot,
            settings: seededSettings
        )

        let monitor = PowerMonitor(provider: MacPowerDataProvider())
        self.monitor = monitor
        powerSourceMonitor = PowerSourceMonitor { [weak monitor] in
            monitor?.triggerImmediateUpdate()
        }
        popoverStore.update(
            makePopoverState(
                snapshot: seededSnapshot,
                settings: seededSettings
            )
        )
        monitor.onUpdate = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.apply(snapshot)
            }
        }
        monitor.onWarmupCompleted = { [weak self] in
            guard let self else { return }
            self.warmupStore.markCompleted(for: self.modelIdentifier)
        }
    }

    static func snapshotTesting(
        settings: PowerSettings,
        snapshot: PowerSnapshot,
        history: [PowerHistoryPoint]
    ) -> AppState {
        AppState(
            snapshotTestState: SnapshotTestState(
                settings: settings,
                snapshot: snapshot,
                history: history
            )
        )
    }

    private func apply(_ snapshot: PowerSnapshot) {
        guard let acceptedSnapshot = resolveSnapshot(snapshot) else { return }
        latestSnapshot = acceptedSnapshot
        let levelDelta = abs(statusSnapshot.batteryLevelPrecise - acceptedSnapshot.batteryLevelPrecise)
        if statusSnapshot.batteryLevel != acceptedSnapshot.batteryLevel
            || levelDelta >= 0.2
            || statusSnapshot.isChargingActive != acceptedSnapshot.isChargingActive
            || statusSnapshot.isExternalPowerConnected != acceptedSnapshot.isExternalPowerConnected {
            statusSnapshot = acceptedSnapshot
        }
        appendHistory(acceptedSnapshot)
        refreshStatusBarTitle(using: acceptedSnapshot)

        guard isPopoverVisible else { return }
        refreshPopoverState(using: acceptedSnapshot)
        if self.snapshot != acceptedSnapshot {
            self.snapshot = acceptedSnapshot
        }
    }

    private func refreshStatusBarTitle(using snapshot: PowerSnapshot) {
        let title = PowerFormatter.statusTitle(snapshot: snapshot, settings: settings)
        if title != statusBarTitle {
            statusBarTitle = title
        }
    }

    private func handleSettingsChange(from oldValue: PowerSettings) {
        guard !isApplyingSettingsChange else { return }
        guard Thread.isMainThread else {
            let newSettings = settings
            DispatchQueue.main.async { [weak self] in
                guard let self, self.settings != newSettings else { return }
                self.settings = newSettings
            }
            return
        }

        let resolvedSettings = settings.clamped()
        if resolvedSettings != settings {
            replaceSettings(resolvedSettings)
        }

        if resolvedSettings.launchAtLogin != oldValue.launchAtLogin {
            do {
                try LaunchAtLoginManager.setEnabled(resolvedSettings.launchAtLogin)
            } catch {
                launchAtLoginError = error.localizedDescription
                replaceSettings(oldValue)
                return
            }
        }

        persistSettings(resolvedSettings)
        monitor.applySettings(resolvedSettings, isPopoverVisible: isPopoverVisible)
        refreshStatusBarTitle(using: latestSnapshot)
        if isPopoverVisible {
            refreshPopoverState(using: latestSnapshot)
        }
    }

    private func syncLaunchAtLoginPreference() {
        let actual = LaunchAtLoginManager.isEnabled()
        if settings.launchAtLogin != actual {
            var syncedSettings = settings
            syncedSettings.launchAtLogin = actual
            replaceSettings(syncedSettings)
            persistSettings(syncedSettings)
        }
    }

    private func replaceSettings(_ newSettings: PowerSettings) {
        isApplyingSettingsChange = true
        settings = newSettings
        isApplyingSettingsChange = false
    }

    private func persistSettings(_ newSettings: PowerSettings) {
        settingsStore.save(newSettings)
    }

    private func appendHistory(_ snapshot: PowerSnapshot) {
        let now = snapshot.timestamp
        if let lastSample = lastHistorySampleAt,
           now.timeIntervalSince(lastSample) < historySampleInterval() {
            return
        }
        lastHistorySampleAt = now
        let fanPercentMax = snapshot.diagnostics.smc.fanReadings
            .compactMap { $0.percentMax }
            .max()
        let point = PowerHistoryPoint(
            timestamp: snapshot.timestamp,
            systemLoad: snapshot.systemLoad,
            screenPower: snapshot.screenPower,
            inputPower: snapshot.systemIn,
            temperatureC: snapshot.temperatureC,
            fanPercentMax: fanPercentMax
        )
        historyBuffer.append(point)
        if historyBuffer.count > historyCapacity {
            historyBuffer.removeFirst(historyBuffer.count - historyCapacity)
        }
    }

    private func resolveSnapshot(_ snapshot: PowerSnapshot) -> PowerSnapshot? {
        if snapshot.isPowerBalanceConsistent {
            pendingSnapshot = nil
            return snapshot
        }

        let now = Date()
        let score = snapshot.powerBalanceMismatch
        if var pending = pendingSnapshot {
            pending.attempts += 1
            if score < pending.bestScore {
                pending.bestScore = score
                pending.bestSnapshot = snapshot
            }
            pendingSnapshot = pending
            if shouldAcceptPending(now: now, pending: pending) {
                let best = pending.bestSnapshot
                pendingSnapshot = nil
                return best
            }
        } else {
            pendingSnapshot = PendingSnapshot(
                bestSnapshot: snapshot,
                bestScore: score,
                startedAt: now,
                attempts: 1
            )
        }

        requestConsistencyRetryIfNeeded(now: now)
        return nil
    }

    private func shouldAcceptPending(now: Date, pending: PendingSnapshot) -> Bool {
        let holdWindow = consistencyHoldWindow()
        if now.timeIntervalSince(pending.startedAt) >= holdWindow {
            return true
        }
        return pending.attempts >= PowerflowConstants.maxConsistencyAttempts
    }

    private func consistencyHoldWindow() -> TimeInterval {
        let base = max(settings.updateIntervalSeconds, PowerSettings.minimumUpdateInterval)
        return min(max(base * 0.75, 1.0), 2.5)
    }

    private func requestConsistencyRetryIfNeeded(now: Date) {
        guard isPopoverVisible else { return }
        if let lastRetry = lastConsistencyRetryAt,
           now.timeIntervalSince(lastRetry) < PowerflowConstants.consistencyRetryInterval {
            return
        }
        lastConsistencyRetryAt = now
        monitor.triggerImmediateUpdate(detailLevelOverride: .full, countWarmup: false)
    }

    private func historySampleInterval() -> TimeInterval {
        let base = max(settings.updateIntervalSeconds, PowerSettings.minimumUpdateInterval)
        if isPopoverVisible {
            return base
        }
        return max(base * 4.0, 10.0)
    }

    private func refreshPopoverState(using snapshot: PowerSnapshot) {
        popoverStore.update(
            makePopoverState(
                snapshot: snapshot,
                settings: settings
            )
        )
    }

    private func makePopoverState(snapshot: PowerSnapshot, settings: PowerSettings) -> PopoverViewState {
        let offenders = makeOffenderRows(from: snapshot.appEnergyOffenders)
        AppIconCache.shared.prefetch(paths: offenders.compactMap(\.iconPath))

        return PopoverViewState(
            overview: makeOverviewState(snapshot: snapshot, settings: settings),
            flow: makeFlowState(snapshot: snapshot),
            history: makeHistoryState(offenders: offenders)
        )
    }

    private func makeOverviewState(snapshot: PowerSnapshot, settings: PowerSettings) -> PopoverOverviewState {
        let displayPowerValue = PowerFormatter.displayPowerValue(snapshot: snapshot, settings: settings)
        let displayPowerText = displayPowerValue.map(PowerFormatter.wattsString) ?? "--"

        return PopoverOverviewState(
            powerLabel: overviewPowerLabel(snapshot: snapshot, settings: settings),
            displayPowerText: displayPowerText,
            batteryLevelText: "\(snapshot.batteryLevel)%",
            powerState: PowerStateKind(snapshot: snapshot),
            metrics: overviewMetrics(snapshot: snapshot)
        )
    }

    private func makeFlowState(snapshot: PowerSnapshot) -> PopoverFlowState {
        PopoverFlowState(
            snapshot: snapshot,
            diagram: FlowDiagramState(snapshot: snapshot),
            batteryLevelPrecise: snapshot.batteryLevelPrecise,
            batteryOverlay: batteryOverlay(for: snapshot)
        )
    }

    private func makeHistoryState(offenders: [PopoverOffenderRowState]) -> PopoverHistoryState {
        guard historyBuffer.count >= 2 else {
            return PopoverHistoryState(
                hasEnoughSamples: false,
                systemChart: nil,
                thermalChart: nil,
                adapterChart: nil,
                offenders: offenders
            )
        }

        let systemSeries = historyBuffer.map(\.systemLoad)
        let inputSeries = historyBuffer.map(\.inputPower)
        let temperatureSeries = historyBuffer.map(\.temperatureC)
        let fanSeries = historyBuffer.map { $0.fanPercentMax ?? 0 }
        let secondarySeries = fanSeries.contains { $0 > 0.1 }
            ? HistoryChartSecondarySeries(
                values: fanSeries,
                formatter: formatFan,
                label: "Fan %"
            )
            : nil
        let revision = historyBuffer.last?.timestamp.timeIntervalSinceReferenceDate ?? 0

        return PopoverHistoryState(
            hasEnoughSamples: true,
            systemChart: makeHistoryChartState(
                id: "system",
                title: "System Load",
                style: .system,
                values: systemSeries,
                formatter: PowerFormatter.wattsString,
                secondary: secondarySeries,
                height: 90,
                revision: revision
            ),
            thermalChart: makeHistoryChartState(
                id: "thermal",
                title: "Primary Temp",
                style: .thermal,
                values: temperatureSeries,
                formatter: formatTemperature,
                secondary: secondarySeries,
                height: 90,
                revision: revision
            ),
            adapterChart: makeHistoryChartState(
                id: "adapter",
                title: "Adapter In",
                style: .adapter,
                values: inputSeries,
                formatter: PowerFormatter.wattsString,
                secondary: nil,
                height: 90,
                revision: revision
            ),
            offenders: offenders
        )
    }

    private func makeHistoryChartState(
        id: String,
        title: String,
        style: HistoryChartStyle,
        values: [Double],
        formatter: (Double) -> String,
        secondary: HistoryChartSecondarySeries?,
        height: CGFloat,
        revision: TimeInterval
    ) -> PopoverHistoryChartState? {
        guard values.contains(where: { $0 > 0.05 }) else { return nil }

        let maxSamples = 240
        let primaryValues = values.count > maxSamples ? Array(values.suffix(maxSamples)) : values
        let trimmedSecondaryValues: [Double]?
        if let secondaryValues = secondary?.values {
            trimmedSecondaryValues = secondaryValues.count > maxSamples
                ? Array(secondaryValues.suffix(maxSamples))
                : secondaryValues
        } else {
            trimmedSecondaryValues = nil
        }
        let statsValues = filteredStatsValues(primaryValues, skipZeros: true)
        let latestVal = primaryValues.last ?? 0
        let minText = statsValues.min().map(formatter) ?? "--"
        let maxText = statsValues.max().map(formatter) ?? "--"
        let latestText = formatter(latestVal)

        let secondaryRangeText: String?
        if let trimmedSecondaryValues,
           let secondary {
            let filtered = trimmedSecondaryValues.filter { $0 > 0.1 }
            if let secondaryMin = filtered.min(), let secondaryMax = filtered.max() {
                secondaryRangeText = "\(secondary.formatter(secondaryMin))–\(secondary.formatter(secondaryMax))"
            } else {
                secondaryRangeText = nil
            }
        } else {
            secondaryRangeText = nil
        }

        return PopoverHistoryChartState(
            id: id,
            title: title,
            style: style,
            height: height,
            primaryValues: primaryValues,
            secondaryValues: trimmedSecondaryValues,
            latestValueText: latestText,
            minValueText: minText,
            maxValueText: maxText,
            secondaryRangeText: secondaryRangeText,
            secondaryLabel: secondary?.label,
            cacheKey: "\(id)-\(revision)"
        )
    }

    private func makeOffenderRows(from offenders: [AppEnergyOffender]) -> [PopoverOffenderRowState] {
        offenders.map { offender in
            let processText = offender.processCount > 1 ? "\(offender.processCount) procs · " : ""
            let memoryText = Self.offenderMemoryFormatter.string(fromByteCount: Int64(offender.memoryBytes))
            return PopoverOffenderRowState(
                id: offender.id,
                name: offender.name,
                detailText: "\(processText)\(String(format: "%.0f%%", offender.cpuPercent)) CPU · \(memoryText)",
                impactText: String(format: offender.impactScore >= 10 ? "%.0f" : "%.1f", offender.impactScore),
                iconPath: offender.iconPath
            )
        }
    }

    private func overviewPowerLabel(snapshot: PowerSnapshot, settings: PowerSettings) -> String {
        if snapshot.isOnExternalPower && settings.showChargingPower {
            return "Input"
        }

        switch settings.statusBarItem {
        case .system:
            return "System Load"
        case .screen:
            return "Screen"
        case .heatpipe:
            return snapshot.packagePowerLabel
        }
    }

    private func overviewMetrics(snapshot: PowerSnapshot) -> [PopoverOverviewMetric] {
        [timeMetric(snapshot: snapshot), healthMetric(snapshot: snapshot)].compactMap { $0 }
    }

    private func timeMetric(snapshot: PowerSnapshot) -> PopoverOverviewMetric? {
        let formattedTime = snapshot.timeRemainingMinutes.map(Self.formatMinutes)
        let formattedRemaining = snapshot.batteryRemainingWh.map { String(format: "%.1f", $0) }

        switch (formattedTime, formattedRemaining) {
        case let (.some(time), .some(remaining)):
            return PopoverOverviewMetric(id: "time", title: "Time (Wh)", value: "\(time) · \(remaining)")
        case let (.some(time), .none):
            return PopoverOverviewMetric(id: "time", title: "Time", value: time)
        case let (.none, .some(remaining)):
            return PopoverOverviewMetric(id: "remaining", title: "Wh", value: remaining)
        case (.none, .none):
            return nil
        }
    }

    private func healthMetric(snapshot: PowerSnapshot) -> PopoverOverviewMetric? {
        let formattedHealth = snapshot.batteryHealthPercent.map { String(format: "%.0f%%", $0) }
        let formattedTemperature = snapshot.batteryTemperatureC
            .flatMap { $0 > 0 ? String(format: "%.1f", $0) : nil }

        switch (formattedHealth, formattedTemperature) {
        case let (.some(health), .some(temperature)):
            return PopoverOverviewMetric(id: "health", title: "Health (C)", value: "\(health) · \(temperature)")
        case let (.some(health), .none):
            return PopoverOverviewMetric(id: "health", title: "Health", value: health)
        case let (.none, .some(temperature)):
            return PopoverOverviewMetric(id: "temperature", title: "Temp (C)", value: temperature)
        case (.none, .none):
            return nil
        }
    }

    private func batteryOverlay(for snapshot: PowerSnapshot) -> BatteryIconRenderer.Overlay {
        if snapshot.isChargingActive {
            return .charging
        }
        if snapshot.isExternalPowerConnected {
            return .pluggedIn
        }
        return .none
    }

    private static func formatMinutes(_ minutes: Int) -> String {
        let formatter = minutes >= 60 ? overviewHourMinuteFormatter : overviewMinuteFormatter
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
    }

    private func formatTemperature(_ value: Double) -> String {
        String(format: "%.1f C", value)
    }

    private func formatFan(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private func filteredStatsValues(_ values: [Double], skipZeros: Bool) -> [Double] {
        let filtered = skipZeros ? values.filter { $0 > 0.01 } : values
        return filtered.isEmpty ? values : filtered
    }

    private func handlePopoverVisibilityChange() {
        monitor.applySettings(settings, isPopoverVisible: isPopoverVisible)
        guard isPopoverVisible else { return }
        snapshot = latestSnapshot
        refreshPopoverState(using: latestSnapshot)
        monitor.triggerImmediateUpdate()
    }
}
