import CoreBluetooth
import Foundation
import IOBluetooth

struct ConnectedDeviceBatteryReading: Equatable {
    let percent: Int
    let detail: String?
}

final class BluetoothBatteryReader: NSObject {
    // 0x180F is the Battery Service; 0x2A19 is the Battery Level characteristic.
    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")
    private let queue = DispatchQueue(label: "Powerflow.bluetoothBatteryReader", qos: .utility)
    private let refreshInterval: TimeInterval
    private var central: CBCentralManager?
    private var retainedPeripherals: [UUID: CBPeripheral] = [:]
    private var batteryPercentsByName: [String: Int] = [:]
    private var lastRefreshAt: Date?

    init(refreshInterval: TimeInterval = 20) {
        self.refreshInterval = refreshInterval
        super.init()
        queue.async { [weak self] in
            guard let self else { return }
            self.central = CBCentralManager(
                delegate: self,
                queue: self.queue,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        }
    }

    func batteryPercents(now: Date = Date()) -> [String: Int] {
        queue.sync {
            refreshIfNeeded(now: now)
            return batteryPercentsByName
        }
    }

    private func refreshIfNeeded(now: Date) {
        if let lastRefreshAt,
           now.timeIntervalSince(lastRefreshAt) < refreshInterval {
            return
        }
        lastRefreshAt = now
        refreshConnectedPeripherals()
    }

    private func refreshConnectedPeripherals() {
        guard central?.state == .poweredOn else { return }
        let peripherals = central?.retrieveConnectedPeripherals(withServices: [batteryServiceUUID]) ?? []
        for peripheral in peripherals {
            retainedPeripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            if peripheral.state == .connected {
                peripheral.discoverServices([batteryServiceUUID])
            } else {
                central?.connect(peripheral, options: nil)
            }
        }
    }

    private func updateBatteryPercent(_ percent: Int, for peripheral: CBPeripheral) {
        guard let name = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return }
        batteryPercentsByName[Self.normalizedNameKey(name)] = percent
    }

    private func releasePeripheral(_ peripheral: CBPeripheral) {
        if peripheral.state == .connected || peripheral.state == .connecting {
            central?.cancelPeripheralConnection(peripheral)
        }
        retainedPeripherals[peripheral.identifier] = nil
    }

    static func normalizedNameKey(_ name: String) -> String {
        name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    static func normalizedAddressKey(_ address: String) -> String {
        let hex = address
            .lowercased()
            .filter { $0.isHexDigit }
        guard hex.count == 12 else { return normalizedNameKey(address) }
        return stride(from: 0, to: hex.count, by: 2)
            .map { index in
                let start = hex.index(hex.startIndex, offsetBy: index)
                let end = hex.index(start, offsetBy: 2)
                return String(hex[start..<end])
            }
            .joined(separator: "-")
    }
}

extension BluetoothBatteryReader: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        lastRefreshAt = nil
        refreshConnectedPeripherals()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([batteryServiceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        retainedPeripherals[peripheral.identifier] = nil
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        retainedPeripherals[peripheral.identifier] = nil
    }
}

final class IOBluetoothBatteryReader {
    func batteryReadings() -> [String: ConnectedDeviceBatteryReading] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [:] }

        var readings: [String: ConnectedDeviceBatteryReading] = [:]
        for device in devices where device.isConnected() {
            guard let reading = Self.batteryReading(from: device) else { continue }
            if let address = device.addressString, !address.isEmpty {
                readings[BluetoothBatteryReader.normalizedAddressKey(address)] = reading
            }
            if let name = device.nameOrAddress, !name.isEmpty {
                readings[BluetoothBatteryReader.normalizedNameKey(name)] = reading
                if name.localizedCaseInsensitiveContains("airpods") {
                    readings["airpods"] = reading
                }
            }
        }
        return readings
    }

    private static func batteryReading(from device: IOBluetoothDevice) -> ConnectedDeviceBatteryReading? {
        // These private selectors are SPI-style accessors, not KVC-compliant keys.
        let readings = [
            reading(label: nil, key: "batteryPercentSingle", from: device),
            reading(label: nil, key: "batteryPercentCombined", from: device),
            reading(label: "L", key: "batteryPercentLeft", from: device),
            reading(label: "R", key: "batteryPercentRight", from: device),
            reading(label: "Case", key: "batteryPercentCase", from: device),
        ].compactMap { $0 }

        guard !readings.isEmpty else { return nil }

        let nonCaseReadings = readings.filter { $0.label != "Case" }
        let preferredReadings = nonCaseReadings.isEmpty ? readings : nonCaseReadings
        let percent = preferredReadings.map(\.percent).min()
        guard let percent else { return nil }

        let labeled = readings.compactMap { reading -> String? in
            guard let label = reading.label else { return nil }
            return "\(label) \(reading.percent)%"
        }
        let detail = labeled.count >= 2 ? labeled.joined(separator: " · ") : nil
        return ConnectedDeviceBatteryReading(percent: percent, detail: detail)
    }

    private static func reading(
        label: String?,
        key: String,
        from device: IOBluetoothDevice
    ) -> (label: String?, percent: Int)? {
        let selector = Selector(key)
        guard device.responds(to: selector),
              let unmanaged = device.perform(selector),
              let number = unmanaged.takeUnretainedValue() as? NSNumber else { return nil }
        let percent = number.intValue
        guard percent > 0, percent <= 100 else { return nil }
        return (label, percent)
    }
}

extension BluetoothBatteryReader: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            releasePeripheral(peripheral)
            return
        }
        guard let batteryService = peripheral.services?.first(where: { $0.uuid == batteryServiceUUID }) else {
            releasePeripheral(peripheral)
            return
        }
        peripheral.discoverCharacteristics([batteryLevelUUID], for: batteryService)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else {
            releasePeripheral(peripheral)
            return
        }
        guard service.uuid == batteryServiceUUID,
              let batteryCharacteristic = service.characteristics?.first(where: { $0.uuid == batteryLevelUUID }) else {
            releasePeripheral(peripheral)
            return
        }
        peripheral.readValue(for: batteryCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil else {
            releasePeripheral(peripheral)
            return
        }
        guard characteristic.uuid == batteryLevelUUID,
              let byte = characteristic.value?.first else {
            releasePeripheral(peripheral)
            return
        }
        let percent = min(100, max(0, Int(byte)))
        updateBatteryPercent(percent, for: peripheral)
        releasePeripheral(peripheral)
    }
}
