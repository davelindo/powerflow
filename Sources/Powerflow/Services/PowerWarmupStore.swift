import Foundation

final class PowerWarmupStore {
    private let key = "powerflow.hasCompletedWarmup"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasCompletedWarmup: Bool {
        defaults.bool(forKey: key)
    }

    func markCompleted() {
        defaults.set(true, forKey: key)
    }
}
