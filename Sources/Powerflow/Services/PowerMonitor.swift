import Foundation

final class PowerMonitor {
    static let backgroundUpdateInterval: TimeInterval = 10.0
    private static let warmupSampleTarget = 12
    private static let warmupMaxDuration: TimeInterval = 60

    private let provider: PowerDataProvider
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval
    private var detailLevel: PowerSnapshotDetailLevel
    private var settings: PowerSettings
    private var isPopoverVisible: Bool
    private let updateQueue = DispatchQueue(label: "PowerMonitor.update", qos: .utility)
    private let updateQueueKey = DispatchSpecificKey<Void>()
    private var warmupState: WarmupState?

    var onUpdate: ((PowerSnapshot) -> Void)?
    var onWarmupCompleted: (() -> Void)?

    private struct WarmupState {
        var remainingSamples: Int
        let deadline: Date
    }

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
        updateQueue.setSpecific(key: updateQueueKey, value: ())
    }

    func start(with settings: PowerSettings, isPopoverVisible: Bool, warmup: Bool) {
        runOnUpdateQueue { [weak self] in
            guard let self else { return }
            self.settings = settings
            self.isPopoverVisible = isPopoverVisible
            if warmup {
                self.warmupState = WarmupState(
                    remainingSamples: Self.warmupSampleTarget,
                    deadline: Date().addingTimeInterval(Self.warmupMaxDuration)
                )
            } else {
                self.warmupState = nil
            }
            self.refreshSchedule(force: true)
            if warmup {
                self.requestUpdate(detailLevelOverride: .summary, countWarmup: false)
            } else {
                self.requestUpdate()
            }
        }
    }

    func applySettings(_ settings: PowerSettings, isPopoverVisible: Bool) {
        runOnUpdateQueue { [weak self] in
            guard let self else { return }
            self.settings = settings
            self.isPopoverVisible = isPopoverVisible
            self.refreshSchedule(force: false)
        }
    }

    private func scheduleTimer() {
        timer?.cancel()
        let qos: DispatchQoS.QoSClass = detailLevel == .full ? .userInitiated : .utility
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: qos))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.requestUpdate()
        }
        timer.resume()
        self.timer = timer
    }

    func triggerImmediateUpdate(
        detailLevelOverride: PowerSnapshotDetailLevel? = nil,
        countWarmup: Bool = true
    ) {
        requestUpdate(detailLevelOverride: detailLevelOverride, countWarmup: countWarmup)
    }

    private func requestUpdate(
        detailLevelOverride: PowerSnapshotDetailLevel? = nil,
        countWarmup: Bool = true
    ) {
        runOnUpdateQueue { [weak self] in
            self?.sendImmediate(detailLevelOverride: detailLevelOverride, countWarmup: countWarmup)
        }
    }

    private func sendImmediate(
        detailLevelOverride: PowerSnapshotDetailLevel? = nil,
        countWarmup: Bool = true
    ) {
        let level = detailLevelOverride ?? detailLevel
        let snapshot = provider.readSnapshot(detailLevel: level, settings: settings)
        if countWarmup {
            updateWarmupState()
        }
        onUpdate?(snapshot)
    }

    private func refreshSchedule(force: Bool) {
        let isWarmup = warmupState != nil
        let targetInterval = resolvedInterval(settings, isPopoverVisible: isPopoverVisible, isWarmup: isWarmup)
        let targetDetailLevel = resolvedDetailLevel(isPopoverVisible: isPopoverVisible, isWarmup: isWarmup)
        let intervalChanged = abs(targetInterval - interval) > 0.01
        let detailChanged = targetDetailLevel != detailLevel
        detailLevel = targetDetailLevel
        if force || intervalChanged || detailChanged {
            interval = targetInterval
            scheduleTimer()
        }
    }

    private func updateWarmupState() {
        guard var state = warmupState else { return }
        if Date() >= state.deadline {
            finishWarmup()
            return
        }
        state.remainingSamples -= 1
        if state.remainingSamples <= 0 {
            finishWarmup()
            return
        }
        warmupState = state
    }

    private func finishWarmup() {
        guard warmupState != nil else { return }
        warmupState = nil
        onWarmupCompleted?()
        refreshSchedule(force: true)
    }

    private func resolvedInterval(
        _ settings: PowerSettings,
        isPopoverVisible: Bool,
        isWarmup: Bool
    ) -> TimeInterval {
        let base = max(settings.updateIntervalSeconds, PowerSettings.minimumUpdateInterval)
        guard !isWarmup else { return base }
        guard !isPopoverVisible else { return base }
        return max(base, Self.backgroundUpdateInterval)
    }

    private func resolvedDetailLevel(
        isPopoverVisible: Bool,
        isWarmup: Bool
    ) -> PowerSnapshotDetailLevel {
        (isPopoverVisible || isWarmup) ? .full : .summary
    }

    private func runOnUpdateQueue(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: updateQueueKey) != nil {
            work()
        } else {
            updateQueue.async(execute: work)
        }
    }
}
