import Foundation
import IOKit

final class ConnectedDeviceReader {
    private static let refreshInterval: TimeInterval = 30

    private let profilerPath: String
    private let timeout: TimeInterval
    private let bluetoothBatteryReader: BluetoothBatteryReader
    private let ioBluetoothBatteryReader: IOBluetoothBatteryReader
    private let refreshQueue = DispatchQueue(label: "Powerflow.connectedDeviceReader.refresh", qos: .utility)
    private let cacheLock = NSLock()
    private var cachedDevices: [ConnectedPowerDevice] = []
    private var cachedAt: Date?
    private var isRefreshingDevices = false

    init(
        profilerPath: String = "/usr/sbin/system_profiler",
        timeout: TimeInterval = 4,
        bluetoothBatteryReader: BluetoothBatteryReader = BluetoothBatteryReader(),
        ioBluetoothBatteryReader: IOBluetoothBatteryReader = IOBluetoothBatteryReader()
    ) {
        self.profilerPath = profilerPath
        self.timeout = timeout
        self.bluetoothBatteryReader = bluetoothBatteryReader
        self.ioBluetoothBatteryReader = ioBluetoothBatteryReader
    }

    func readDevices(detailLevel: PowerSnapshotDetailLevel, now: Date = Date()) -> [ConnectedPowerDevice] {
        let batteryPercents = bluetoothBatteryReader.batteryPercents(now: now)
        let batteryReadings = ioBluetoothBatteryReader.batteryReadings()
        let cached = cachedDeviceSnapshot()
        guard detailLevel == .full else {
            return Self.devices(
                cached.devices,
                applyingBatteryPercentsByName: batteryPercents,
                applyingBatteryReadingsByKey: batteryReadings
            )
        }
        if let cachedAt = cached.cachedAt,
           now.timeIntervalSince(cachedAt) < Self.refreshInterval {
            return Self.devices(
                cached.devices,
                applyingBatteryPercentsByName: batteryPercents,
                applyingBatteryReadingsByKey: batteryReadings
            )
        }

        refreshDeviceCacheIfNeeded(now: now)
        let refreshed = cachedDeviceSnapshot()
        return Self.devices(
            refreshed.devices,
            applyingBatteryPercentsByName: batteryPercents,
            applyingBatteryReadingsByKey: batteryReadings
        )
    }

    private func cachedDeviceSnapshot() -> (devices: [ConnectedPowerDevice], cachedAt: Date?) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return (cachedDevices, cachedAt)
    }

    private func refreshDeviceCacheIfNeeded(now: Date) {
        cacheLock.lock()
        if isRefreshingDevices {
            cacheLock.unlock()
            return
        }
        isRefreshingDevices = true
        cacheLock.unlock()

        refreshQueue.async { [weak self] in
            guard let self else { return }
            let profilerData = self.runBluetoothProfiler()
            let hidDevices = self.readHIDDevices()
            let profilerDevices = profilerData.map(Self.devices(fromProfilerJSON:)) ?? []
            let shouldUpdateCache = profilerData != nil || !hidDevices.isEmpty
            let mergedDevices = Self.mergedDevices(profilerDevices + hidDevices)

            self.cacheLock.lock()
            if shouldUpdateCache {
                self.cachedDevices = mergedDevices
                self.cachedAt = now
            }
            self.isRefreshingDevices = false
            self.cacheLock.unlock()
        }
    }

    static func devices(fromProfilerJSON data: Data) -> [ConnectedPowerDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return devices(fromJSONObject: root)
    }

    static func devices(fromJSONObject object: Any) -> [ConnectedPowerDevice] {
        let root: Any
        if let dictionary = object as? [String: Any],
           let bluetooth = dictionary["SPBluetoothDataType"] {
            root = bluetooth
        } else {
            root = object
        }

        var devices: [ConnectedPowerDevice] = []
        collectDevices(from: root, into: &devices)
        return mergedDevices(devices)
    }

    static func devices(fromIORegistryDictionaries dictionaries: [NSDictionary]) -> [ConnectedPowerDevice] {
        mergedDevices(dictionaries.compactMap(deviceFromHIDProperties))
    }

    static func devices(
        _ devices: [ConnectedPowerDevice],
        applyingBatteryPercentsByName batteryPercentsByName: [String: Int],
        applyingBatteryReadingsByKey batteryReadingsByKey: [String: ConnectedDeviceBatteryReading] = [:]
    ) -> [ConnectedPowerDevice] {
        return devices.map { device in
            if let reading = batteryReading(for: device, in: batteryReadingsByKey) {
                return ConnectedPowerDevice(
                    id: device.id,
                    name: device.name,
                    kind: device.kind,
                    transport: device.transport,
                    batteryPercent: reading.percent,
                    isConnected: device.isConnected,
                    detail: reading.detail ?? device.detail
                )
            }

            guard let percent = batteryPercentsByName[BluetoothBatteryReader.normalizedNameKey(device.name)] else {
                return device
            }
            return ConnectedPowerDevice(
                id: device.id,
                name: device.name,
                kind: device.kind,
                transport: device.transport,
                batteryPercent: percent,
                isConnected: device.isConnected,
                detail: device.detail
            )
        }
    }

    private static func batteryReading(
        for device: ConnectedPowerDevice,
        in batteryReadingsByKey: [String: ConnectedDeviceBatteryReading]
    ) -> ConnectedDeviceBatteryReading? {
        guard !batteryReadingsByKey.isEmpty else { return nil }
        for key in batteryMatchingKeys(for: device) {
            if let reading = batteryReadingsByKey[key] {
                return reading
            }
        }
        return nil
    }

    private static func batteryMatchingKeys(for device: ConnectedPowerDevice) -> [String] {
        var keys = [
            BluetoothBatteryReader.normalizedAddressKey(device.id),
            BluetoothBatteryReader.normalizedNameKey(device.name),
        ]
        if let detail = device.detail {
            keys.append(BluetoothBatteryReader.normalizedAddressKey(detail))
        }
        return Array(Set(keys))
    }

    private func runBluetoothProfiler() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: profilerPath)
        process.arguments = ["SPBluetoothDataType", "-json"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        return output.fileHandleForReading.readDataToEndOfFile()
    }

    private func readHIDDevices() -> [ConnectedPowerDevice] {
        let classNames = [
            "IOHIDEventService",
            "AppleUserHIDEventService",
            "AppleDeviceManagementHIDEventService",
            "AppleHIDTransportHIDDevice",
            "AppleHIDTransportDevice",
            "AppleUserHIDDevice",
            "IOHIDUserDevice",
        ]
        let dictionaries = classNames.flatMap(readIORegistryDictionaries(className:))
        return Self.devices(fromIORegistryDictionaries: dictionaries)
    }

    private func readIORegistryDictionaries(className: String) -> [NSDictionary] {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(className),
            &iterator
        )
        guard result == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var dictionaries: [NSDictionary] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            let result = IORegistryEntryCreateCFProperties(
                service,
                &properties,
                kCFAllocatorDefault,
                0
            )
            guard result == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as NSDictionary? else { continue }
            dictionaries.append(dictionary)
        }
        return dictionaries
    }

    private static func collectDevices(from object: Any, into devices: inout [ConnectedPowerDevice]) {
        if let dictionary = object as? [String: Any] {
            if let device = device(from: dictionary) {
                devices.append(device)
            }

            for value in dictionary.values {
                collectDevices(from: value, into: &devices)
            }
        } else if let array = object as? [Any] {
            for value in array {
                collectDevices(from: value, into: &devices)
            }
        }
    }

    private static func device(from dictionary: [String: Any]) -> ConnectedPowerDevice? {
        guard let name = firstString(
            in: dictionary,
            keys: ["device_name", "_name", "name", "local_name", "display_name", "Product"]
        ) else { return nil }

        let batteryReadings = batteryReadings(in: dictionary)
        guard !batteryReadings.isEmpty else { return nil }

        let isConnected = connectedValue(in: dictionary) ?? true
        guard isConnected else { return nil }

        let kind = deviceKind(name: name, dictionary: dictionary)
        let percent = primaryBatteryPercent(from: batteryReadings)
        let address = firstString(
            in: dictionary,
            keys: ["device_address", "address", "device_addr", "MAC Address", "mac_address"]
        )
        let id = stableID(address: address, name: name, kind: kind)
        let detail = detailText(from: batteryReadings)

        return ConnectedPowerDevice(
            id: id,
            name: name,
            kind: kind,
            transport: "Bluetooth",
            batteryPercent: percent,
            isConnected: true,
            detail: detail
        )
    }

    private static func deviceFromHIDProperties(_ dictionary: NSDictionary) -> ConnectedPowerDevice? {
        guard let name = firstString(
            in: dictionary,
            keys: ["Product", "ProductName", "Name", "DeviceName", "device_name", "_name"]
        ) ?? inferredHIDDeviceName(dictionary) else { return nil }

        let transport = firstString(
            in: dictionary,
            keys: ["Transport", "TransportTypeDescription", "TransportDescription"]
        )
        guard isExternalConnectedDevice(name: name, transport: transport, dictionary: dictionary) else {
            return nil
        }

        let batteryReadings = batteryReadings(in: dictionary)
        let kind = deviceKind(name: name, dictionary: dictionary)
        let percent = primaryBatteryPercent(from: batteryReadings)
        let detail = detailText(from: batteryReadings)
        let address = firstString(
            in: dictionary,
            keys: ["DeviceAddress", "BluetoothAddress", "BD_ADDR", "BT_ADDR"]
        )
        let stableFields = [
            firstString(in: dictionary, keys: ["SerialNumber", "Serial Number"]),
            firstString(in: dictionary, keys: ["VendorID", "Vendor ID"]),
            firstString(in: dictionary, keys: ["ProductID", "Product ID"]),
            transport,
        ]
            .compactMap { $0 }
            .joined(separator: "-")
        let id = stableID(
            address: address ?? (stableFields.isEmpty ? nil : stableFields),
            name: name,
            kind: kind
        )

        return ConnectedPowerDevice(
            id: id,
            name: name,
            kind: kind,
            transport: transport ?? "Connected",
            batteryPercent: percent,
            isConnected: true,
            detail: detail
        )
    }

    private static func inferredHIDDeviceName(_ dictionary: NSDictionary) -> String? {
        let transport = firstString(
            in: dictionary,
            keys: ["Transport", "TransportTypeDescription", "TransportDescription"]
        )?.lowercased()
        // Apple's Bluetooth audio HID service often exposes only vendor/product IDs.
        guard transport == "bt-aacp",
              firstString(in: dictionary, keys: ["VendorID", "Vendor ID"]) == "1452" else {
            return nil
        }

        // VendorID 1452 is Apple; ProductID 8231 is the common AirPods AACP endpoint.
        if firstString(in: dictionary, keys: ["ProductID", "Product ID"]) == "8231" {
            return "AirPods"
        }

        return "Apple Audio Device"
    }

    private static func isExternalConnectedDevice(
        name: String,
        transport: String?,
        dictionary: NSDictionary
    ) -> Bool {
        if let builtInValue = dictionary["Built-In"] ?? dictionary["BuiltIn"],
           let builtIn = parseBool(builtInValue),
           builtIn {
            return false
        }

        let normalizedName = name.lowercased()
        let genericNames = [
            "keyboard backlight",
            "apple internal keyboard / trackpad",
            "btm",
        ]
        if genericNames.contains(normalizedName) {
            return false
        }

        guard let transport else { return false }
        let normalizedTransport = transport.lowercased()
        return normalizedTransport.contains("bluetooth")
            || normalizedTransport.contains("bt-")
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dictionary[key] else { continue }
            if let string = normalizedString(value), !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private static func firstString(in dictionary: NSDictionary, keys: [String]) -> String? {
        for key in keys {
            guard let value = dictionary[key] else { continue }
            if let string = normalizedString(value), !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private static func normalizedString(_ value: Any) -> String? {
        if let string = value as? String {
            let normalized = string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }

        if let data = value as? Data {
            return data
                .map { String(format: "%02x", $0) }
                .joined(separator: "-")
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        return nil
    }

    private static func connectedValue(in dictionary: [String: Any]) -> Bool? {
        let keys = [
            "device_connected",
            "device_isconnected",
            "connected",
            "isConnected",
            "Connected",
        ]

        for key in keys {
            guard let value = dictionary[key],
                  let connected = parseBool(value) else { continue }
            return connected
        }

        return nil
    }

    private static func parseBool(_ value: Any) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }

        if let number = value as? NSNumber {
            return number.intValue != 0
        }

        guard let string = value as? String else { return nil }
        let normalized = string
            .replacingOccurrences(of: "attrib_", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if ["yes", "true", "connected", "1"].contains(normalized) {
            return true
        }
        if ["no", "false", "disconnected", "not connected", "0"].contains(normalized) {
            return false
        }
        return nil
    }

    private static func batteryReadings(in dictionary: [String: Any]) -> [(label: String?, percent: Int)] {
        batteryReadings(from: dictionary.map { ($0.key, $0.value) })
    }

    private static func batteryReadings(in dictionary: NSDictionary) -> [(label: String?, percent: Int)] {
        let pairs = dictionary.compactMap { key, value -> (String, Any)? in
            guard let key = key as? String else { return nil }
            return (key, value)
        }
        return batteryReadings(from: pairs)
    }

    private static func batteryReadings(from pairs: [(String, Any)]) -> [(label: String?, percent: Int)] {
        pairs.compactMap { key, value in
            let normalizedKey = key.lowercased()
            guard isBatteryPercentKey(normalizedKey),
                  let percent = parsePercent(value) else {
                return nil
            }
            return (batteryLabel(for: normalizedKey), percent)
        }
        .sorted { lhs, rhs in
            batteryLabelRank(lhs.label) < batteryLabelRank(rhs.label)
        }
    }

    private static func isBatteryPercentKey(_ key: String) -> Bool {
        guard key.contains("battery") else { return false }
        let excludedFragments = [
            "type",
            "state",
            "status",
            "low",
            "warning",
            "powered",
            "power",
            "charging",
            "chargeable",
        ]
        guard !excludedFragments.contains(where: key.contains) else { return false }

        return key.contains("level")
            || key.contains("percent")
            || key.contains("percentage")
    }

    private static func parsePercent(_ value: Any) -> Int? {
        let raw: Double?
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            raw = number.doubleValue
        } else if let string = value as? String {
            raw = firstNumber(in: string)
        } else {
            raw = nil
        }

        guard let raw else { return nil }
        let normalized = (raw > 0 && raw <= 1) ? raw * 100 : raw
        guard normalized >= 0, normalized <= 100 else { return nil }
        return Int(normalized.rounded())
    }

    private static func firstNumber(in string: String) -> Double? {
        let allowed = CharacterSet(charactersIn: "0123456789.")
        let scalars = string.unicodeScalars
        var current = String.UnicodeScalarView()

        for scalar in scalars {
            if allowed.contains(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                break
            }
        }

        guard !current.isEmpty else { return nil }
        return Double(String(current))
    }

    private static func batteryLabel(for key: String) -> String? {
        if key.contains("left") {
            return "L"
        }
        if key.contains("right") {
            return "R"
        }
        if key.contains("case") {
            return "Case"
        }
        return nil
    }

    private static func batteryLabelRank(_ label: String?) -> Int {
        switch label {
        case "L":
            return 0
        case "R":
            return 1
        case "Case":
            return 2
        default:
            return 3
        }
    }

    private static func primaryBatteryPercent(from readings: [(label: String?, percent: Int)]) -> Int? {
        let nonCaseReadings = readings.filter { $0.label != "Case" }
        let preferredReadings = nonCaseReadings.isEmpty ? readings : nonCaseReadings
        return preferredReadings.map(\.percent).min()
    }

    private static func detailText(from readings: [(label: String?, percent: Int)]) -> String? {
        let labeled = readings.compactMap { reading -> String? in
            guard let label = reading.label else { return nil }
            return "\(label) \(reading.percent)%"
        }
        guard labeled.count >= 2 else { return nil }
        return labeled.joined(separator: " · ")
    }

    private static func deviceKind(name: String, dictionary: [String: Any]) -> ConnectedDeviceKind {
        let typeText = dictionary
            .filter { key, _ in
                isDeviceKindHintKey(key)
            }
            .compactMap { normalizedString($0.value) }
            .joined(separator: " ")
        let text = "\(name) \(typeText)".lowercased()

        if text.contains("airpods")
            || text.contains("headphone")
            || text.contains("headset")
            || text.contains("earbud")
            || text.contains("beats") {
            return .headphones
        }
        if text.contains("keyboard")
            || text.contains("keychron")
            || text.contains("mx keys") {
            return .keyboard
        }
        if text.contains("mouse") {
            return .mouse
        }
        if text.contains("trackpad") {
            return .trackpad
        }
        if text.contains("controller") || text.contains("gamepad") {
            return .gameController
        }
        return .bluetooth
    }

    private static func isDeviceKindHintKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized.contains("type")
            || normalized.contains("class")
            || normalized.contains("product")
    }

    private static func deviceKind(name: String, dictionary: NSDictionary) -> ConnectedDeviceKind {
        var bridge: [String: Any] = [:]
        for (key, value) in dictionary {
            guard let key = key as? String else { continue }
            bridge[key] = value
        }
        return deviceKind(name: name, dictionary: bridge)
    }

    private static func stableID(address: String?, name: String, kind: ConnectedDeviceKind) -> String {
        if let address {
            return address
                .lowercased()
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: " ", with: "-")
        }

        let normalizedName = name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "\(kind.rawValue)-\(normalizedName)"
    }

    private static func mergedDevices(_ devices: [ConnectedPowerDevice]) -> [ConnectedPowerDevice] {
        deduplicated(devices).sorted(by: deviceSort)
    }

    private static func deduplicated(_ devices: [ConnectedPowerDevice]) -> [ConnectedPowerDevice] {
        var seen = Set<String>()
        var result: [ConnectedPowerDevice] = []

        for device in devices {
            let key = dedupeKey(for: device)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(device)
        }

        return result
    }

    private static func dedupeKey(for device: ConnectedPowerDevice) -> String {
        let name = device.name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let transport = device.transport?.lowercased() ?? ""
        return "\(name)-\(transport)"
    }

    private static func deviceSort(_ lhs: ConnectedPowerDevice, _ rhs: ConnectedPowerDevice) -> Bool {
        let lhsRank = sortRank(lhs.kind)
        let rhsRank = sortRank(rhs.kind)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func sortRank(_ kind: ConnectedDeviceKind) -> Int {
        switch kind {
        case .headphones:
            return 0
        case .mouse:
            return 1
        case .keyboard:
            return 2
        case .trackpad:
            return 3
        case .gameController:
            return 4
        case .bluetooth:
            return 5
        }
    }
}
