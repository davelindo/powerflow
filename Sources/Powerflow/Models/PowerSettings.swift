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
        var updated = self

        if updated.updateIntervalSeconds < Self.minimumUpdateInterval {
            updated.updateIntervalSeconds = Self.minimumUpdateInterval
        }
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
        updateIntervalSeconds = try container.decode(TimeInterval.self, forKey: .updateIntervalSeconds, default: defaults.updateIntervalSeconds)
        statusBarItem = try container.decode(StatusBarItem.self, forKey: .statusBarItem, default: defaults.statusBarItem)
        showChargingPower = try container.decode(Bool.self, forKey: .showChargingPower, default: defaults.showChargingPower)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin, default: defaults.launchAtLogin)
        statusBarFormat = try container.decode(String.self, forKey: .statusBarFormat, default: defaults.statusBarFormat)
        statusBarIcon = try container.decode(StatusBarIcon.self, forKey: .statusBarIcon, default: defaults.statusBarIcon)
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

private extension KeyedDecodingContainer {
    func decode<T: Decodable>(
        _ type: T.Type,
        forKey key: Key,
        default defaultValue: T
    ) throws -> T {
        try decodeIfPresent(type, forKey: key) ?? defaultValue
    }
}
