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
            let clamped = settings.clamped()
            if clamped != settings {
                settings = clamped
                return
            }
            settingsStore.save(settings)
            monitor.applySettings(settings, isPopoverVisible: isPopoverVisible)
            if settings.launchAtLogin != oldValue.launchAtLogin {
                handleLaunchAtLoginChange(from: oldValue.launchAtLogin, to: settings.launchAtLogin)
            }
            refreshStatusBarTitle(using: latestSnapshot)
        }
    }

    private let settingsStore = PowerSettingsStore()
    private let monitor: PowerMonitor
    private let powerSourceMonitor: PowerSourceMonitor
    private var isApplyingLaunchSetting = false
    private let historyCapacity = 600
    private var latestSnapshot: PowerSnapshot
    private var historyBuffer: [PowerHistoryPoint]

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

        syncLaunchAtLoginPreference()
        monitor.start(with: storedSettings, isPopoverVisible: isPopoverVisible)
        powerSourceMonitor.start()
    }

    private func apply(_ snapshot: PowerSnapshot) {
        latestSnapshot = snapshot
        let levelDelta = abs(statusSnapshot.batteryLevelPrecise - snapshot.batteryLevelPrecise)
        if statusSnapshot.batteryLevel != snapshot.batteryLevel
            || levelDelta >= 0.2
            || statusSnapshot.isChargingActive != snapshot.isChargingActive
            || statusSnapshot.isExternalPowerConnected != snapshot.isExternalPowerConnected {
            statusSnapshot = snapshot
        }
        appendHistory(snapshot)
        refreshStatusBarTitle(using: snapshot)

        if isPopoverVisible, self.snapshot != snapshot {
            self.snapshot = snapshot
        }
    }

    private func refreshStatusBarTitle(using snapshot: PowerSnapshot) {
        let title = PowerFormatter.statusTitle(snapshot: snapshot, settings: settings)
        if title != statusBarTitle {
            statusBarTitle = title
        }
    }

    private func handleLaunchAtLoginChange(from oldValue: Bool, to newValue: Bool) {
        guard !isApplyingLaunchSetting else { return }
        isApplyingLaunchSetting = true
        do {
            try LaunchAtLoginManager.setEnabled(newValue)
        } catch {
            launchAtLoginError = error.localizedDescription
            settings.launchAtLogin = oldValue
        }
        isApplyingLaunchSetting = false
    }

    private func syncLaunchAtLoginPreference() {
        let actual = LaunchAtLoginManager.isEnabled()
        if settings.launchAtLogin != actual {
            isApplyingLaunchSetting = true
            settings.launchAtLogin = actual
            isApplyingLaunchSetting = false
        }
    }

    private func appendHistory(_ snapshot: PowerSnapshot) {
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
        if isPopoverVisible {
            history.append(point)
            if history.count > historyCapacity {
                history.removeFirst(history.count - historyCapacity)
            }
        }
    }

    private func handlePopoverVisibilityChange() {
        monitor.applySettings(settings, isPopoverVisible: isPopoverVisible)
        guard isPopoverVisible else { return }
        snapshot = latestSnapshot
        history = historyBuffer
    }
}
