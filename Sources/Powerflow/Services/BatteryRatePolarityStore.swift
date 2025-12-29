import Foundation

enum BatteryRatePolarity: Int {
    case normal = 1
    case inverted = -1
}

struct BatteryRatePolarityStore {
    private let defaults = UserDefaults.standard
    private let keyPrefix = "Powerflow.PPBR.Polarity."

    func load(for model: String) -> BatteryRatePolarity? {
        let key = keyPrefix + model
        let raw = defaults.integer(forKey: key)
        guard raw == BatteryRatePolarity.normal.rawValue
            || raw == BatteryRatePolarity.inverted.rawValue else { return nil }
        return BatteryRatePolarity(rawValue: raw)
    }

    func save(_ polarity: BatteryRatePolarity, for model: String) {
        let key = keyPrefix + model
        defaults.set(polarity.rawValue, forKey: key)
    }
}
