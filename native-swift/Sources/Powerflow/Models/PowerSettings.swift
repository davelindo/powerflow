import Foundation

struct PowerSettings: Codable, Equatable {
    static let minimumUpdateInterval: TimeInterval = 1.5

    enum StatusBarItem: String, CaseIterable, Codable, Identifiable {
        case system
        case screen
        case heatpipe

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "System Power"
            case .screen: return "Screen Power"
            case .heatpipe: return "Package Power"
            }
        }
    }

    enum StatusBarIcon: String, CaseIterable, Codable, Identifiable {
        case none
        case bolt
        case battery
        case dynamicBattery
        case plug
        case waveform

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "None"
            case .bolt: return "Bolt"
            case .battery: return "Battery (Static)"
            case .dynamicBattery: return "Battery (Dynamic)"
            case .plug: return "Adapter"
            case .waveform: return "Wave"
            }
        }

        var symbolName: String? {
            switch self {
            case .none: return nil
            case .bolt: return "bolt.fill"
            case .battery: return "battery.100"
            case .dynamicBattery: return "battery.100.bolt"
            case .plug: return "powerplug.fill"
            case .waveform: return "waveform.path.ecg"
            }
        }
    }

    var updateIntervalSeconds: TimeInterval
    var statusBarItem: StatusBarItem
    var showChargingPower: Bool
    var launchAtLogin: Bool
    var statusBarFormat: String
    var statusBarIcon: StatusBarIcon

    static let `default` = PowerSettings(
        updateIntervalSeconds: 2.0,
        statusBarItem: .system,
        showChargingPower: true,
        launchAtLogin: false,
        statusBarFormat: "{power} | {battery}",
        statusBarIcon: .bolt
    )

    func clamped() -> PowerSettings {
        guard updateIntervalSeconds < Self.minimumUpdateInterval else { return self }
        var updated = self
        updated.updateIntervalSeconds = Self.minimumUpdateInterval
        return updated
    }

    private enum CodingKeys: String, CodingKey {
        case updateIntervalSeconds
        case statusBarItem
        case showChargingPower
        case launchAtLogin
        case statusBarFormat
        case statusBarIcon
    }

    init(
        updateIntervalSeconds: TimeInterval,
        statusBarItem: StatusBarItem,
        showChargingPower: Bool,
        launchAtLogin: Bool,
        statusBarFormat: String,
        statusBarIcon: StatusBarIcon
    ) {
        self.updateIntervalSeconds = updateIntervalSeconds
        self.statusBarItem = statusBarItem
        self.showChargingPower = showChargingPower
        self.launchAtLogin = launchAtLogin
        self.statusBarFormat = statusBarFormat
        self.statusBarIcon = statusBarIcon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PowerSettings.default
        updateIntervalSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .updateIntervalSeconds)
            ?? defaults.updateIntervalSeconds
        statusBarItem = try container.decodeIfPresent(StatusBarItem.self, forKey: .statusBarItem)
            ?? defaults.statusBarItem
        showChargingPower = try container.decodeIfPresent(Bool.self, forKey: .showChargingPower)
            ?? defaults.showChargingPower
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
            ?? defaults.launchAtLogin
        statusBarFormat = try container.decodeIfPresent(String.self, forKey: .statusBarFormat)
            ?? defaults.statusBarFormat
        statusBarIcon = try container.decodeIfPresent(StatusBarIcon.self, forKey: .statusBarIcon)
            ?? defaults.statusBarIcon
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(updateIntervalSeconds, forKey: .updateIntervalSeconds)
        try container.encode(statusBarItem, forKey: .statusBarItem)
        try container.encode(showChargingPower, forKey: .showChargingPower)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(statusBarFormat, forKey: .statusBarFormat)
        try container.encode(statusBarIcon, forKey: .statusBarIcon)
    }
}
