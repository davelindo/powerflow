import Foundation

final class PowerWarmupStore {
    private let legacyKey = "powerflow.hasCompletedWarmup"
    private let defaults: UserDefaults
    private static let warmupRetryInterval: TimeInterval = 24 * 60 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func shouldWarmup(for modelIdentifier: String?) -> Bool {
        guard let modelIdentifier = normalizedModelIdentifier(modelIdentifier) else {
            return !defaults.bool(forKey: legacyKey)
        }
        let warmupKey = key(for: modelIdentifier)
        let warmupCompleted = defaults.bool(forKey: warmupKey) || defaults.bool(forKey: legacyKey)
        guard warmupCompleted else { return true }
        let cpuKeys = defaults.stringArray(forKey: cpuTempKeysKey(for: modelIdentifier)) ?? []
        guard cpuKeys.isEmpty else { return false }
        if let lastAttempt = defaults.object(forKey: warmupAttemptKey(for: modelIdentifier)) as? Date {
            return Date().timeIntervalSince(lastAttempt) >= Self.warmupRetryInterval
        }
        return true
    }

    func markWarmupAttempted(for modelIdentifier: String?) {
        guard let modelIdentifier = normalizedModelIdentifier(modelIdentifier) else { return }
        defaults.set(Date(), forKey: warmupAttemptKey(for: modelIdentifier))
    }

    func markCompleted(for modelIdentifier: String?) {
        guard let modelIdentifier = normalizedModelIdentifier(modelIdentifier) else {
            defaults.set(true, forKey: legacyKey)
            return
        }
        defaults.set(true, forKey: key(for: modelIdentifier))
    }

    private func key(for modelIdentifier: String) -> String {
        "powerflow.hasCompletedWarmup.\(modelIdentifier)"
    }

    private func cpuTempKeysKey(for modelIdentifier: String) -> String {
        "powerflow.cachedCpuTempKeys.\(modelIdentifier)"
    }

    private func warmupAttemptKey(for modelIdentifier: String) -> String {
        "powerflow.lastWarmupAttempt.\(modelIdentifier)"
    }

    private func normalizedModelIdentifier(_ modelIdentifier: String?) -> String? {
        guard let modelIdentifier else { return nil }
        let trimmed = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "unknown" else { return nil }
        return trimmed
    }

}
