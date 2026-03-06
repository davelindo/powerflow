import Foundation

final class PowerSettingsStore {
    private let key = "powerflow.settings"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PowerSettings {
        guard let data = defaults.data(forKey: key) else {
            return .default
        }
        let decoded = (try? JSONDecoder().decode(PowerSettings.self, from: data)) ?? .default
        let clamped = decoded.clamped()
        if clamped != decoded {
            save(clamped)
        }
        return clamped
    }

    func save(_ settings: PowerSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
