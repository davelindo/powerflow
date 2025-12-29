import Foundation
import IOKit

struct PowerTelemetry: Equatable {
    var adapterEfficiencyLoss: Int
    var batteryPower: Int
    var systemCurrentIn: Int
    var systemEnergyConsumed: Int
    var systemLoad: Int
    var systemPowerIn: Int
    var systemVoltageIn: Int

    static let empty = PowerTelemetry(
        adapterEfficiencyLoss: 0,
        batteryPower: 0,
        systemCurrentIn: 0,
        systemEnergyConsumed: 0,
        systemLoad: 0,
        systemPowerIn: 0,
        systemVoltageIn: 0
    )
}

enum BatteryCapacityUnits: String, Equatable {
    case percent
    case mah
}

struct BatteryInfo: Equatable {
    var currentCapacity: Int
    var maxCapacity: Int?
    var capacityUnits: BatteryCapacityUnits
    var batteryPercent: Int
    var isCharging: Bool
    var isExternalConnected: Bool
    var timeRemainingMinutes: Int?
    var batteryVoltage: Int?
    var instantAmperage: Int?
    var cellVoltages: [Int]?
    var adapterWatts: Double
    var adapterVoltage: Double
    var adapterAmperage: Double
    var adapterInfo: AdapterInfo?
    var batteryDetails: BatteryDetails?
    var powerTelemetry: PowerTelemetry?

    static let empty = BatteryInfo(
        currentCapacity: 0,
        maxCapacity: nil,
        capacityUnits: .percent,
        batteryPercent: 0,
        isCharging: false,
        isExternalConnected: false,
        timeRemainingMinutes: nil,
        batteryVoltage: nil,
        instantAmperage: nil,
        cellVoltages: nil,
        adapterWatts: 0,
        adapterVoltage: 0,
        adapterAmperage: 0,
        adapterInfo: nil,
        batteryDetails: nil,
        powerTelemetry: nil
    )
}

final class IORegistryReader {
    func readBatteryInfo() -> BatteryInfo {
        guard let dict = readSmartBattery() else { return .empty }

        let currentCapacity = intValue(dict, key: "CurrentCapacity") ?? 0
        let maxCapacity = intValue(dict, key: "MaxCapacity")
            ?? intValue(dict, key: "AppleRawMaxCapacity")
            ?? intValue(dict, key: "DesignCapacity")
        let isCharging = boolValue(dict, key: "IsCharging") ?? false
        let isExternalConnected = boolValue(dict, key: "ExternalConnected") ?? false
        let timeRemaining = intValue(dict, key: "TimeRemaining")
        let batteryVoltage = intValue(dict, key: "Voltage")
        let instantAmperage = intValue(dict, key: "InstantAmperage")
            ?? intValue(dict, key: "Amperage")
        let cellVoltages = intArray(dict, key: "CellVoltage")
            ?? intArray(dict, key: "CellVoltages")

        let adapterDetails = dict["AdapterDetails"] as? NSDictionary
        let adapterWatts = intValue(adapterDetails, key: "Watts").map(Double.init) ?? 0
        let adapterVoltage = intValue(adapterDetails, key: "AdapterVoltage").map { Double($0) / 1000.0 } ?? 0
        let adapterAmperage = intValue(adapterDetails, key: "Current").map { Double($0) / 1000.0 } ?? 0

        let capacityUnits = inferCapacityUnits(current: currentCapacity, maxCapacity: maxCapacity)
        let batteryPercent = percentFromCapacity(
            current: currentCapacity,
            maxCapacity: maxCapacity,
            units: capacityUnits
        )

        let adapterInfo = readAdapterInfo(from: adapterDetails)
        let batteryDetails = readBatteryDetails(from: dict)
        let telemetry = readPowerTelemetry(from: dict)

        return BatteryInfo(
            currentCapacity: currentCapacity,
            maxCapacity: maxCapacity,
            capacityUnits: capacityUnits,
            batteryPercent: batteryPercent,
            isCharging: isCharging,
            isExternalConnected: isExternalConnected,
            timeRemainingMinutes: timeRemaining,
            batteryVoltage: batteryVoltage,
            instantAmperage: instantAmperage,
            cellVoltages: cellVoltages,
            adapterWatts: adapterWatts,
            adapterVoltage: adapterVoltage,
            adapterAmperage: adapterAmperage,
            adapterInfo: adapterInfo,
            batteryDetails: batteryDetails,
            powerTelemetry: telemetry
        )
    }

    private func readSmartBattery() -> NSDictionary? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(
            service,
            &properties,
            kCFAllocatorDefault,
            0
        )
        guard result == KERN_SUCCESS, let dict = properties?.takeRetainedValue() as NSDictionary? else {
            return nil
        }
        return dict
    }

    private func intValue(_ dict: NSDictionary?, key: String) -> Int? {
        dict?[key] as? Int
    }

    private func boolValue(_ dict: NSDictionary?, key: String) -> Bool? {
        guard let value = dict?[key] else { return nil }
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["yes", "true", "1"].contains(normalized) {
                return true
            }
            if ["no", "false", "0"].contains(normalized) {
                return false
            }
        }
        return nil
    }

    private func intArray(_ dict: NSDictionary?, key: String) -> [Int]? {
        guard let values = dict?[key] as? [Any] else { return nil }
        let ints = values.compactMap { item -> Int? in
            if let int = item as? Int { return int }
            if let number = item as? NSNumber { return number.intValue }
            if let double = item as? Double { return Int(double.rounded()) }
            if let string = item as? String, let value = Int(string) { return value }
            return nil
        }
        return ints.isEmpty ? nil : ints
    }

    private func readAdapterInfo(from dict: NSDictionary?) -> AdapterInfo? {
        guard let dict else { return nil }

        let name = stringValue(dict, keys: ["Name", "AdapterName", "Description"])
        let manufacturer = stringValue(dict, keys: ["Manufacturer", "VendorName"])
        let model = stringValue(dict, keys: ["Model", "ModelID", "ProductName"])
        let serialNumber = stringValue(dict, keys: ["SerialNumber", "Serial"])
        let familyCode = stringValue(dict, keys: ["FamilyCode"])
        let adapterID = stringValue(dict, keys: ["AdapterID", "AdapterId"])
        let vendorID = stringValue(dict, keys: ["VendorID", "VendorId"])
        let productID = stringValue(dict, keys: ["ProductID", "ProductId"])

        if name == nil,
           manufacturer == nil,
           model == nil,
           serialNumber == nil,
           familyCode == nil,
           adapterID == nil,
           vendorID == nil,
           productID == nil {
            return nil
        }

        return AdapterInfo(
            name: name,
            manufacturer: manufacturer,
            model: model,
            serialNumber: serialNumber,
            familyCode: familyCode,
            adapterID: adapterID,
            vendorID: vendorID,
            productID: productID
        )
    }

    private func stringValue(_ dict: NSDictionary, keys: [String]) -> String? {
        for key in keys {
            guard let value = dict[key] else { continue }
            if let string = value as? String, !string.isEmpty {
                return string
            }
            if let number = value as? NSNumber {
                return String(describing: number)
            }
        }
        return nil
    }

    private func stringValue(from dict: NSDictionary?, keys: [String], fallback: NSDictionary? = nil) -> String? {
        if let dict, let value = stringValue(dict, keys: keys) {
            return value
        }
        if let fallback, let value = stringValue(fallback, keys: keys) {
            return value
        }
        return nil
    }

    private func intValue(from dict: NSDictionary?, key: String, fallback: NSDictionary? = nil) -> Int? {
        if let value = intValue(dict, key: key) {
            return value
        }
        return intValue(fallback, key: key)
    }

    private func readBatteryDetails(from dict: NSDictionary) -> BatteryDetails? {
        let batteryData = dict["BatteryData"] as? NSDictionary

        let name = stringValue(from: dict, keys: ["DeviceName", "ProductName", "BatteryType"], fallback: batteryData)
        let manufacturer = stringValue(from: dict, keys: ["Manufacturer", "ManufacturerName"], fallback: batteryData)
        let model = stringValue(from: dict, keys: ["ModelNumber", "Model", "BatteryModel"], fallback: batteryData)
        let serial = stringValue(from: dict, keys: ["Serial", "SerialNumber", "BatterySerialNumber"], fallback: batteryData)
        let firmware = stringValue(from: dict, keys: ["FirmwareVersion", "FirmwareRevision"], fallback: batteryData)
        let hardware = stringValue(from: dict, keys: ["HardwareRevision", "HardwareVersion"], fallback: batteryData)
        let cycleCount = intValue(from: dict, key: "CycleCount", fallback: batteryData)

        if name == nil,
           manufacturer == nil,
           model == nil,
           serial == nil,
           firmware == nil,
           hardware == nil,
           cycleCount == nil {
            return nil
        }

        return BatteryDetails(
            name: name,
            manufacturer: manufacturer,
            model: model,
            serialNumber: serial,
            firmwareVersion: firmware,
            hardwareRevision: hardware,
            cycleCount: cycleCount
        )
    }

    private func readPowerTelemetry(from dict: NSDictionary) -> PowerTelemetry? {
        guard let telemetry = dict["PowerTelemetryData"] as? NSDictionary else {
            return nil
        }
        let adapterEfficiencyLoss = intValue(telemetry, key: "AdapterEfficiencyLoss") ?? 0
        let batteryPower = intValue(telemetry, key: "BatteryPower") ?? 0
        let systemCurrentIn = intValue(telemetry, key: "SystemCurrentIn") ?? 0
        let systemEnergyConsumed = intValue(telemetry, key: "SystemEnergyConsumed") ?? 0
        let systemLoad = intValue(telemetry, key: "SystemLoad") ?? 0
        let systemPowerIn = intValue(telemetry, key: "SystemPowerIn") ?? 0
        let systemVoltageIn = intValue(telemetry, key: "SystemVoltageIn") ?? 0

        return PowerTelemetry(
            adapterEfficiencyLoss: adapterEfficiencyLoss,
            batteryPower: batteryPower,
            systemCurrentIn: systemCurrentIn,
            systemEnergyConsumed: systemEnergyConsumed,
            systemLoad: systemLoad,
            systemPowerIn: systemPowerIn,
            systemVoltageIn: systemVoltageIn
        )
    }

    private func inferCapacityUnits(current: Int, maxCapacity: Int?) -> BatteryCapacityUnits {
        if current <= 100, (maxCapacity == nil || (maxCapacity ?? 0) <= 100) {
            return .percent
        }
        if let maxCapacity, maxCapacity > 200 {
            return .mah
        }
        if current > 100 {
            return .mah
        }
        return .percent
    }

    private func percentFromCapacity(current: Int, maxCapacity: Int?, units: BatteryCapacityUnits) -> Int {
        switch units {
        case .percent:
            return min(100, max(0, current))
        case .mah:
            guard let maxCapacity, maxCapacity > 0 else { return 0 }
            let percent = (Double(current) / Double(maxCapacity)) * 100.0
            return min(100, max(0, Int(percent.rounded())))
        }
    }
}
