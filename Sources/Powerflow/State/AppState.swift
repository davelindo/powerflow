import Combine
import Foundation

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var snapshot: PowerSnapshot
    @Published private(set) var statusSnapshot: PowerSnapshot
    @Published private(set) var statusBarTitle: String
    @Published private(set) var history: [PowerHistoryPoint]
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

    private init() {
        let storedSettings = settingsStore.load()
        let initialSnapshot = PowerSnapshot.empty
        settings = storedSettings
        snapshot = initialSnapshot
        statusSnapshot = initialSnapshot
        latestSnapshot = initialSnapshot
        history = []
        historyBuffer = []
        statusBarTitle = PowerFormatter.statusTitle(
            snapshot: initialSnapshot,
            settings: storedSettings
        )

        let monitor = PowerMonitor(provider: MacPowerDataProvider())
        self.monitor = monitor
        powerSourceMonitor = PowerSourceMonitor { [weak monitor] in
            monitor?.triggerImmediateUpdate()
        }
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

        if isPopoverVisible, self.snapshot != acceptedSnapshot {
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
        // Only maintain single buffer - sync to published history when popover visible
        historyBuffer.append(point)
        if historyBuffer.count > historyCapacity {
            historyBuffer.removeFirst(historyBuffer.count - historyCapacity)
        }
        if isPopoverVisible && historyNeedsRefresh(for: point) {
            history = historyBuffer
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
            return max(base * 2.0, 4.0)
        }
        return max(base * 4.0, 10.0)
    }

    private func historyNeedsRefresh(for point: PowerHistoryPoint) -> Bool {
        history.count != historyBuffer.count || history.last?.timestamp != point.timestamp
    }

    private func handlePopoverVisibilityChange() {
        monitor.applySettings(settings, isPopoverVisible: isPopoverVisible)
        guard isPopoverVisible else { return }
        snapshot = latestSnapshot
        history = historyBuffer
        monitor.triggerImmediateUpdate()
    }
}
