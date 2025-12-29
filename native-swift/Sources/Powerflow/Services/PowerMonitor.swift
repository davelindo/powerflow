import Foundation

final class PowerMonitor {
    static let backgroundUpdateInterval: TimeInterval = 10.0

    private let provider: PowerDataProvider
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval
    private var detailLevel: PowerSnapshotDetailLevel
    private var settings: PowerSettings
    private var isPopoverVisible: Bool

    var onUpdate: ((PowerSnapshot) -> Void)?

    init(provider: PowerDataProvider) {
        self.provider = provider
        let defaultSettings = PowerSettings.default
        self.settings = defaultSettings
        self.interval = max(
            defaultSettings.updateIntervalSeconds,
            PowerSettings.minimumUpdateInterval
        )
        self.detailLevel = .summary
        self.isPopoverVisible = false
    }

    func start(with settings: PowerSettings, isPopoverVisible: Bool) {
        self.settings = settings
        self.isPopoverVisible = isPopoverVisible
        interval = resolvedInterval(settings, isPopoverVisible: isPopoverVisible)
        detailLevel = isPopoverVisible ? .full : .summary
        scheduleTimer()
        sendImmediate()
    }

    func applySettings(_ settings: PowerSettings, isPopoverVisible: Bool) {
        self.settings = settings
        self.isPopoverVisible = isPopoverVisible
        let targetInterval = resolvedInterval(settings, isPopoverVisible: isPopoverVisible)
        let targetDetailLevel: PowerSnapshotDetailLevel = isPopoverVisible ? .full : .summary
        let intervalChanged = abs(targetInterval - interval) > 0.01
        let detailChanged = targetDetailLevel != detailLevel
        detailLevel = targetDetailLevel
        if intervalChanged || detailChanged {
            interval = targetInterval
            scheduleTimer()
        }
    }

    private func scheduleTimer() {
        timer?.cancel()
        let qos: DispatchQoS.QoSClass = detailLevel == .full ? .userInitiated : .utility
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: qos))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.sendImmediate()
        }
        timer.resume()
        self.timer = timer
    }

    private func sendImmediate() {
        let snapshot = provider.readSnapshot(detailLevel: detailLevel, settings: settings)
        onUpdate?(snapshot)
    }

    private func resolvedInterval(_ settings: PowerSettings, isPopoverVisible: Bool) -> TimeInterval {
        let base = max(settings.updateIntervalSeconds, PowerSettings.minimumUpdateInterval)
        guard !isPopoverVisible else { return base }
        return max(base, Self.backgroundUpdateInterval)
    }
}
