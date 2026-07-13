import Combine
import CoreGraphics
import Foundation

struct AppImpactSample: Sendable {
    let timestamp: Date
    let offenders: [AppEnergyOffender]
}

@MainActor
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
    private var historyRepository: PowerHistoryRepository?
    let popoverStore: PopoverStateStore
    private var isApplyingSettingsChange = false
    private let historyCapacity = PowerflowConstants.historyCapacity
    private var latestSnapshot: PowerSnapshot
    private var historyBuffer: [PowerHistoryPoint]
    private var appImpactHistory: [AppImpactSample]
    private var reportState: PowerReportState
    private var reportRange: PowerReportRange
    private var pendingSnapshot: PendingSnapshot?
    private var lastHistorySampleAt: Date?
    private var lastConsistencyRetryAt: Date?
    private var lastReportRefreshMinute: Int64?
    private var shouldPersistSettings = true
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
        let report: PowerReportState
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
        appImpactHistory = []
        reportRange = .day
        historyRepository = nil
        reportState = .empty(range: .day, isLoading: true)
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
            Task { @MainActor in
                self?.apply(snapshot)
            }
        }
        monitor.onWarmupCompleted = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.warmupStore.markCompleted(for: self.modelIdentifier)
            }
        }

        syncLaunchAtLoginPreference()
        let modelIdentifier = self.modelIdentifier
        let shouldWarmup = warmupStore.shouldWarmup(for: modelIdentifier)
        if shouldWarmup {
            warmupStore.markWarmupAttempted(for: modelIdentifier)
        }
        monitor.start(with: storedSettings, isPopoverVisible: isPopoverVisible, warmup: shouldWarmup)
        powerSourceMonitor.start()
        initializeHistoryRepository()
    }

    private init(snapshotTestState: SnapshotTestState) {
        shouldPersistSettings = false
        let seededSettings = snapshotTestState.settings
        let seededSnapshot = snapshotTestState.snapshot
        let seededHistory = snapshotTestState.history

        settings = seededSettings
        snapshot = seededSnapshot
        statusSnapshot = seededSnapshot
        latestSnapshot = seededSnapshot
        historyBuffer = seededHistory
        appImpactHistory = [
            AppImpactSample(
                timestamp: seededSnapshot.timestamp,
                offenders: seededSnapshot.appEnergyOffenders
            ),
        ]
        reportRange = .day
        historyRepository = nil
        reportState = snapshotTestState.report
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
            Task { @MainActor in
                self?.apply(snapshot)
            }
        }
        monitor.onWarmupCompleted = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.warmupStore.markCompleted(for: self.modelIdentifier)
            }
        }
    }

    static func snapshotTesting(
        settings: PowerSettings,
        snapshot: PowerSnapshot,
        history: [PowerHistoryPoint],
        report: PowerReportState = .empty(range: .day)
    ) -> AppState {
        AppState(
            snapshotTestState: SnapshotTestState(
                settings: settings,
                snapshot: snapshot,
                history: history,
                report: report
            )
        )
    }

    func stop() {
        monitor.stop()
        powerSourceMonitor.stop()
    }

    func selectReportRange(_ range: PowerReportRange) {
        guard range != reportRange || reportState.points.isEmpty else { return }
        reportRange = range
        reportState = .empty(range: range, isLoading: historyRepository != nil)
        if isPopoverVisible {
            refreshPopoverState(using: latestSnapshot)
        }
        refreshPersistentReport()
    }

    private func apply(_ snapshot: PowerSnapshot) {
        let freshAppImpact = captureFreshAppImpact(from: snapshot)
        guard let acceptedSnapshot = resolveSnapshot(snapshot) else {
            persistAppImpact(freshAppImpact)
            return
        }
        let acceptedAppImpact = freshAppImpact.flatMap { sample in
            acceptedSnapshot.timestamp == sample.timestamp ? sample : nil
        }
        if acceptedAppImpact == nil {
            persistAppImpact(freshAppImpact)
        }
        latestSnapshot = acceptedSnapshot
        let levelDelta = abs(statusSnapshot.batteryLevelPrecise - acceptedSnapshot.batteryLevelPrecise)
        if statusSnapshot.batteryLevel != acceptedSnapshot.batteryLevel
            || levelDelta >= 0.2
            || statusSnapshot.isChargingActive != acceptedSnapshot.isChargingActive
            || statusSnapshot.isExternalPowerConnected != acceptedSnapshot.isExternalPowerConnected {
            statusSnapshot = acceptedSnapshot
        }
        if self.snapshot != acceptedSnapshot {
            self.snapshot = acceptedSnapshot
        }
        appendHistory(acceptedSnapshot, appImpactToPersist: acceptedAppImpact)
        refreshStatusBarTitle(using: acceptedSnapshot)

        guard isPopoverVisible else { return }
        refreshPopoverState(using: acceptedSnapshot)
    }

    private func refreshStatusBarTitle(using snapshot: PowerSnapshot) {
        let title = PowerFormatter.statusTitle(snapshot: snapshot, settings: settings)
        if title != statusBarTitle {
            statusBarTitle = title
        }
    }

    private func handleSettingsChange(from oldValue: PowerSettings) {
        guard !isApplyingSettingsChange else { return }

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
        let clearedAppEnergyOffenders = oldValue.showAppEnergyOffenders
            && !resolvedSettings.showAppEnergyOffenders
        if clearedAppEnergyOffenders {
            clearAppEnergyOffenders()
        }
        refreshStatusBarTitle(using: latestSnapshot)
        if isPopoverVisible || clearedAppEnergyOffenders {
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
        guard shouldPersistSettings else { return }
        settingsStore.save(newSettings)
    }

    private func clearAppEnergyOffenders() {
        appImpactHistory.removeAll()
        if let historyRepository {
            Task {
                try? await historyRepository.clearAppImpact()
            }
        }
        latestSnapshot.appEnergyOffenders = []
        if !snapshot.appEnergyOffenders.isEmpty {
            snapshot.appEnergyOffenders = []
        }
        if !statusSnapshot.appEnergyOffenders.isEmpty {
            statusSnapshot.appEnergyOffenders = []
        }
        if var pendingSnapshot {
            pendingSnapshot.bestSnapshot.appEnergyOffenders = []
            self.pendingSnapshot = pendingSnapshot
        }
    }

    private func appendHistory(
        _ snapshot: PowerSnapshot,
        appImpactToPersist: AppImpactSample?
    ) {
        let now = snapshot.timestamp
        let hasFreshAppEnergy = snapshot.appEnergyOffenders.contains {
            $0.estimatedEnergyWh != nil
        }
        if let lastSample = lastHistorySampleAt,
           now.timeIntervalSince(lastSample)
            < max(historySampleInterval() - PowerflowConstants.timerIntervalTolerance, 0),
           !hasFreshAppEnergy {
            return
        }
        lastHistorySampleAt = now
        let fanPercentMax = snapshot.diagnostics.smc.fanReadings
            .compactMap { $0.percentMax }
            .filter { $0.isFinite && (0...100).contains($0) }
            .max()
        let prior = historyBuffer.last
        let point = PowerHistoryPoint(
            timestamp: snapshot.timestamp,
            systemLoad: MacPowerDataProvider.validatedPower(snapshot.systemLoad)
                ?? prior?.systemLoad
                ?? 0,
            screenPower: MacPowerDataProvider.validatedPower(snapshot.screenPower)
                ?? prior?.screenPower
                ?? 0,
            inputPower: MacPowerDataProvider.validatedPower(snapshot.systemIn)
                ?? prior?.inputPower
                ?? 0,
            temperatureC: snapshot.temperatureC.isFinite
                && (PowerflowConstants.minValidTemperature...PowerflowConstants.maxValidCpuTemperature)
                    .contains(snapshot.temperatureC)
                ? snapshot.temperatureC
                : (prior?.temperatureC ?? 0),
            fanPercentMax: fanPercentMax
        )
        historyBuffer.append(point)
        if settings.showAppEnergyOffenders {
            appendAppImpactSample(
                AppImpactSample(
                    timestamp: snapshot.timestamp,
                    offenders: snapshot.appEnergyOffenders
                )
            )
        }
        if historyBuffer.count > historyCapacity {
            historyBuffer.removeFirst(historyBuffer.count - historyCapacity)
        }
        persistHistory(snapshot, appImpact: appImpactToPersist)
    }

    private func captureFreshAppImpact(from snapshot: PowerSnapshot) -> AppImpactSample? {
        guard settings.showAppEnergyOffenders,
              snapshot.appEnergyOffenders.contains(where: { $0.estimatedEnergyWh != nil }) else {
            return nil
        }
        let sample = AppImpactSample(
            timestamp: snapshot.timestamp,
            offenders: snapshot.appEnergyOffenders
        )
        appendAppImpactSample(sample)
        return sample
    }

    private func persistAppImpact(_ sample: AppImpactSample?) {
        guard let sample, let historyRepository else { return }
        Task {
            try? await historyRepository.record(appImpact: sample)
        }
    }

    private func appendAppImpactSample(_ sample: AppImpactSample) {
        guard !appImpactHistory.contains(where: { $0.timestamp == sample.timestamp }) else { return }
        appImpactHistory.append(sample)
        appImpactHistory.sort { $0.timestamp < $1.timestamp }
        guard let newestTimestamp = appImpactHistory.last?.timestamp else { return }
        let cutoff = newestTimestamp.addingTimeInterval(-10 * 60)
        appImpactHistory.removeAll { $0.timestamp < cutoff }
    }

    private func persistHistory(
        _ snapshot: PowerSnapshot,
        appImpact: AppImpactSample?
    ) {
        guard let historyRepository else { return }
        let observation = PowerHistoryObservation(snapshot: snapshot)
        let minute = Int64(snapshot.timestamp.timeIntervalSince1970 / 60)
        let shouldRefreshReport = isPopoverVisible && lastReportRefreshMinute != minute
        if shouldRefreshReport {
            lastReportRefreshMinute = minute
        }

        Task { [weak self] in
            do {
                try await historyRepository.record(observation: observation, appImpact: appImpact)
                guard shouldRefreshReport, let self else { return }
                await self.loadPersistentReport(endingAt: snapshot.timestamp)
            } catch {
                guard shouldRefreshReport, let self else { return }
                self.applyReportFailure(error)
            }
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
        let offenders = settings.showAppEnergyOffenders
            ? makeOffenderRows(from: snapshot.appEnergyOffenders)
            : []
        let appImpact = settings.showAppEnergyOffenders
            ? Self.makeAppImpactRows(from: appImpactHistory)
            : []
        AppIconCache.shared.prefetch(
            paths: (offenders.compactMap(\.iconPath) + appImpact.compactMap(\.iconPath))
        )

        return PopoverViewState(
            overview: makeOverviewState(snapshot: snapshot, settings: settings),
            flow: makeFlowState(snapshot: snapshot),
            connectedDevices: makeConnectedDevicesState(snapshot: snapshot),
            history: makeHistoryState(
                offenders: offenders,
                appImpact: appImpact,
                isAppImpactEnabled: settings.showAppEnergyOffenders
            ),
            report: reportState
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
            breakdown: DetailedFlowState(snapshot: snapshot),
            batteryLevelPrecise: snapshot.batteryLevelPrecise,
            batteryOverlay: batteryOverlay(for: snapshot)
        )
    }

    private func makeHistoryState(
        offenders: [PopoverOffenderRowState],
        appImpact: [PopoverAppImpactRowState],
        isAppImpactEnabled: Bool
    ) -> PopoverHistoryState {
        guard historyBuffer.count >= 2 else {
            return PopoverHistoryState(
                hasEnoughSamples: false,
                isAppImpactEnabled: isAppImpactEnabled,
                systemChart: nil,
                thermalChart: nil,
                adapterChart: nil,
                offenders: offenders,
                appImpact: appImpact
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
            isAppImpactEnabled: isAppImpactEnabled,
            systemChart: makeHistoryChartState(
                id: "system",
                title: "System Load",
                style: .system,
                values: systemSeries,
                formatter: PowerFormatter.wattsString,
                secondary: secondarySeries,
                height: 72,
                revision: revision
            ),
            thermalChart: makeHistoryChartState(
                id: "thermal",
                title: "Primary Temp",
                style: .thermal,
                values: temperatureSeries,
                formatter: formatTemperature,
                secondary: secondarySeries,
                height: 72,
                revision: revision
            ),
            adapterChart: makeHistoryChartState(
                id: "adapter",
                title: "Adapter In",
                style: .adapter,
                values: inputSeries,
                formatter: PowerFormatter.wattsString,
                secondary: nil,
                height: 72,
                revision: revision
            ),
            offenders: offenders,
            appImpact: appImpact
        )
    }

    static func makeAppImpactRows(
        from samples: [AppImpactSample]
    ) -> [PopoverAppImpactRowState] {
        struct Accumulator {
            var name: String
            var iconPath: String?
            var totalImpact: Double = 0
            var totalEnergyWh = 0.0
            var peakEstimatedPower = 0.0
            var peakIntervalDuration = 0.0
            var hasIntegratedEnergy = false
            var peakCPU: Double = 0
            var activeSamples: Int = 0
        }

        guard !samples.isEmpty else { return [] }
        var accumulators: [String: Accumulator] = [:]
        var totalComputeEnergyWh = 0.0
        for sample in samples {
            if let sampleBudget = sample.offenders.lazy.compactMap({ offender -> Double? in
                guard let energy = offender.estimatedEnergyWh,
                      energy.isFinite,
                      energy >= 0,
                      let share = offender.activityShare,
                      share.isFinite,
                      share > 0,
                      share <= 1 else {
                    return nil
                }
                return energy / share
            }).first {
                totalComputeEnergyWh += sampleBudget
            }

            for offender in sample.offenders where offender.impactScore.isFinite && offender.impactScore > 0 {
                var value = accumulators[offender.id]
                    ?? Accumulator(name: offender.name, iconPath: offender.iconPath)
                value.name = offender.name
                value.iconPath = offender.iconPath ?? value.iconPath
                value.totalImpact += offender.impactScore
                if let estimatedEnergy = offender.estimatedEnergyWh,
                   estimatedEnergy.isFinite,
                   estimatedEnergy >= 0 {
                    value.totalEnergyWh += estimatedEnergy
                    value.hasIntegratedEnergy = true
                    if let estimatedPower = offender.estimatedPowerWatts,
                       estimatedPower.isFinite,
                       estimatedPower >= value.peakEstimatedPower {
                        value.peakEstimatedPower = estimatedPower
                        value.peakIntervalDuration = offender.sampleDurationSeconds ?? 0
                    }
                }
                value.peakCPU = max(value.peakCPU, offender.cpuPercent)
                value.activeSamples += 1
                accumulators[offender.id] = value
            }
        }

        let totalImpact = accumulators.values.reduce(0) { $0 + $1.totalImpact }
        guard totalImpact > 0 else { return [] }
        let sampleCount = max(samples.count, 1)
        let hasIntegratedEnergy = accumulators.values.contains { $0.hasIntegratedEnergy }

        return accumulators
            .filter { !hasIntegratedEnergy || $0.value.hasIntegratedEnergy }
            .map { id, value in
                let share = hasIntegratedEnergy && totalComputeEnergyWh > 0
                    ? (value.totalEnergyWh / totalComputeEnergyWh) * 100
                    : (value.totalImpact / totalImpact) * 100
                let activePercent = (Double(value.activeSamples) / Double(sampleCount)) * 100
                let energy = value.hasIntegratedEnergy
                    ? value.totalEnergyWh
                    : nil
                let peakPower = value.hasIntegratedEnergy ? value.peakEstimatedPower : nil
                let peakDuration = value.peakIntervalDuration
                let peakPowerText = peakPower.map { power in
                    guard peakDuration > 0 else { return "≈\(PowerFormatter.wattsString(power))" }
                    return "≈\(PowerFormatter.wattsString(power)) over \(String(format: "%.0f", peakDuration))s"
                } ?? "--"
                return PopoverAppImpactRowState(
                    id: id,
                    name: value.name,
                    sharePercent: share,
                    shareText: share > 0 && share < 1 ? "<1%" : String(format: "%.0f%%", share),
                    energyWattHours: energy,
                    energyText: energy.map(PowerFormatter.energyString) ?? "--",
                    peakPowerWatts: peakPower,
                    peakPowerText: peakPowerText,
                    detailText: String(
                        format: "Active %.0f%% · peak interval %.0f%% CPU",
                        activePercent,
                        value.peakCPU
                    ),
                    iconPath: value.iconPath
                )
            }
            .sorted { lhs, rhs in
                if lhs.sharePercent == rhs.sharePercent {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.sharePercent > rhs.sharePercent
            }
            .prefix(3)
            .map { $0 }
    }

    private func makeConnectedDevicesState(snapshot: PowerSnapshot) -> PopoverConnectedDevicesState {
        let visibleLimit = 8
        let devices = snapshot.connectedDevices
        let rows = devices.prefix(visibleLimit).map { device in
            PopoverConnectedDeviceRowState(
                id: device.id,
                name: device.name,
                detailText: connectedDeviceDetailText(for: device),
                batteryText: device.batteryPercent.map { "\($0)%" } ?? "--",
                batteryPercent: device.batteryPercent,
                kind: device.kind
            )
        }
        let hiddenCount = max(0, devices.count - rows.count)
        return PopoverConnectedDevicesState(
            devices: Array(rows),
            hiddenDeviceCount: hiddenCount,
            summaryText: connectedDevicesSummaryText(devices)
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
            let powerText = offender.estimatedPowerWatts.map {
                "≈\(PowerFormatter.wattsString($0)) est · "
            } ?? ""
            return PopoverOffenderRowState(
                id: offender.id,
                name: offender.name,
                detailText: "\(powerText)\(processText)\(String(format: "%.1f%%", offender.cpuPercent)) CPU · \(memoryText)",
                impactScore: offender.impactScore,
                impactText: String(format: offender.impactScore >= 10 ? "%.0f" : "%.1f", offender.impactScore),
                iconPath: offender.iconPath
            )
        }
    }

    private func connectedDeviceDetailText(for device: ConnectedPowerDevice) -> String {
        var parts = [device.transport ?? "Connected"]
        if let detail = device.detail {
            parts.append(detail)
        }
        return parts.joined(separator: " · ")
    }

    private func connectedDevicesSummaryText(_ devices: [ConnectedPowerDevice]) -> String {
        guard !devices.isEmpty else { return "No devices" }
        let countText = devices.count == 1 ? "1 device" : "\(devices.count) devices"
        guard let lowest = devices.compactMap(\.batteryPercent).min() else {
            return countText
        }
        return "\(countText) · low \(lowest)%"
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
        refreshPersistentReport()
        monitor.triggerImmediateUpdate()
    }

    private func hydratePersistedHistory() {
        guard let historyRepository else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                async let samples = historyRepository.recentAppImpactSamples()
                async let report = historyRepository.report(range: reportRange)
                let loadedSamples = try await samples
                let loadedReport = try await report
                for sample in loadedSamples {
                    appendAppImpactSample(sample)
                }
                reportState = loadedReport
                if isPopoverVisible {
                    refreshPopoverState(using: latestSnapshot)
                }
            } catch {
                applyReportFailure(error)
            }
        }
    }

    private func initializeHistoryRepository() {
        Task { [weak self] in
            let repository = await Task.detached(priority: .utility) {
                try? PowerHistoryRepository()
            }.value
            guard let self else { return }
            guard let repository else {
                reportState = .empty(range: reportRange)
                if isPopoverVisible {
                    refreshPopoverState(using: latestSnapshot)
                }
                return
            }
            historyRepository = repository
            hydratePersistedHistory()
        }
    }

    private func refreshPersistentReport() {
        guard historyRepository != nil else { return }
        reportState = PowerReportState(
            range: reportRange,
            points: reportState.range == reportRange ? reportState.points : [],
            summary: reportState.range == reportRange ? reportState.summary : .empty,
            isLoading: true,
            errorMessage: nil
        )
        Task { [weak self] in
            await self?.loadPersistentReport(endingAt: Date())
        }
    }

    private func loadPersistentReport(endingAt endDate: Date) async {
        guard let historyRepository else { return }
        let requestedRange = reportRange
        do {
            let report = try await historyRepository.report(range: requestedRange, endingAt: endDate)
            guard requestedRange == reportRange else { return }
            reportState = report
            if isPopoverVisible {
                refreshPopoverState(using: latestSnapshot)
            }
        } catch {
            applyReportFailure(error)
        }
    }

    private func applyReportFailure(_ error: Error) {
        reportState = PowerReportState(
            range: reportRange,
            points: reportState.points,
            summary: reportState.summary,
            isLoading: false,
            errorMessage: error.localizedDescription
        )
        if isPopoverVisible {
            refreshPopoverState(using: latestSnapshot)
        }
    }
}
