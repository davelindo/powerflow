import XCTest
@testable import Powerflow

final class ConnectedDeviceReaderTests: XCTestCase {
    func testParsesConnectedBluetoothDeviceBatteries() {
        let object: [String: Any] = [
            "SPBluetoothDataType": [
                [
                    "_items": [
                        [
                            "_name": "Sample AirPods Pro",
                            "device_address": "AA-BB-CC-DD-EE-FF",
                            "device_connected": "attrib_Yes",
                            "device_minorType": "Headphones",
                            "device_batteryLevelLeft": "82%",
                            "device_batteryLevelRight": "79%",
                            "device_batteryLevelCase": "64%",
                        ],
                        [
                            "_name": "Magic Mouse",
                            "device_address": "11-22-33-44-55-66",
                            "device_connected": true,
                            "device_minorType": "Mouse",
                            "device_batteryLevel": 52,
                        ],
                    ],
                ],
            ],
        ]

        let devices = ConnectedDeviceReader.devices(fromJSONObject: object)

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.map(\.name), ["Sample AirPods Pro", "Magic Mouse"])
        XCTAssertEqual(devices[0].kind, .headphones)
        XCTAssertEqual(devices[0].batteryPercent, 79)
        XCTAssertEqual(devices[0].detail, "L 82% · R 79% · Case 64%")
        XCTAssertEqual(devices[1].kind, .mouse)
        XCTAssertEqual(devices[1].batteryPercent, 52)
    }

    func testDeviceNamePreservesAttribPrefix() {
        let object: [String: Any] = [
            "SPBluetoothDataType": [
                [
                    "_name": "attrib_Buds",
                    "device_connected": "attrib_Yes",
                    "device_minorType": "Headphones",
                    "device_batteryLevel": 58,
                ],
            ],
        ]

        let devices = ConnectedDeviceReader.devices(fromJSONObject: object)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].name, "attrib_Buds")
        XCTAssertEqual(devices[0].batteryPercent, 58)
    }

    func testSkipsDisconnectedAndBatterylessEntries() {
        let object: [String: Any] = [
            "SPBluetoothDataType": [
                [
                    "_name": "Bluetooth Controller",
                    "_items": [
                        [
                            "_name": "Magic Keyboard",
                            "device_connected": "attrib_No",
                            "device_minorType": "Keyboard",
                            "device_batteryLevel": "91%",
                        ],
                        [
                            "_name": "Paired Speaker",
                            "device_connected": "attrib_Yes",
                            "device_minorType": "Audio",
                        ],
                    ],
                ],
            ],
        ]

        let devices = ConnectedDeviceReader.devices(fromJSONObject: object)

        XCTAssertTrue(devices.isEmpty)
    }

    func testParsesFractionalBatteryValues() {
        let object: [String: Any] = [
            "SPBluetoothDataType": [
                [
                    "_name": "Magic Trackpad",
                    "device_connected": true,
                    "device_minorType": "Trackpad",
                    "device_batteryLevel": 0.87,
                ],
            ],
        ]

        let devices = ConnectedDeviceReader.devices(fromJSONObject: object)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].kind, .trackpad)
        XCTAssertEqual(devices[0].batteryPercent, 87)
    }

    func testAirPodsCaseBatteryDoesNotDrivePrimaryPercent() {
        let object: [String: Any] = [
            "SPBluetoothDataType": [
                [
                    "_name": "AirPods",
                    "device_connected": true,
                    "device_minorType": "Headphones",
                    "device_batteryLevelLeft": "74%",
                    "device_batteryLevelRight": "71%",
                    "device_batteryLevelCase": "12%",
                ],
            ],
        ]

        let devices = ConnectedDeviceReader.devices(fromJSONObject: object)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].batteryPercent, 71)
        XCTAssertEqual(devices[0].detail, "L 74% · R 71% · Case 12%")
    }

    func testIgnoresBatteryStatusBooleansWhenParsingHIDPercent() {
        let dictionaries: [NSDictionary] = [
            [
                "Product": "Magic Mouse",
                "Transport": "Bluetooth",
                "BatteryPowered": true,
                "BatteryLow": false,
                "BatteryPercent": 41,
            ],
        ]

        let devices = ConnectedDeviceReader.devices(fromIORegistryDictionaries: dictionaries)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].batteryPercent, 41)
    }

    func testAppliesBluetoothBatteryServiceReadingByDeviceName() {
        let devices = [
            ConnectedPowerDevice(
                id: "keyboard-keychron-b6-pro",
                name: "Keychron B6 Pro",
                kind: .keyboard,
                transport: "Bluetooth Low Energy",
                batteryPercent: nil,
                isConnected: true,
                detail: nil
            ),
        ]

        let resolved = ConnectedDeviceReader.devices(
            devices,
            applyingBatteryPercentsByName: ["keychron-b6-pro": 73]
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].batteryPercent, 73)
    }

    func testAppliesIOBluetoothReadingByDeviceAddress() {
        let devices = [
            ConnectedPowerDevice(
                id: "aa-bb-cc-dd-ee-ff",
                name: "AirPods",
                kind: .headphones,
                transport: "BT-AACP",
                batteryPercent: nil,
                isConnected: true,
                detail: nil
            ),
        ]

        let resolved = ConnectedDeviceReader.devices(
            devices,
            applyingBatteryPercentsByName: [:],
            applyingBatteryReadingsByKey: [
                "aa-bb-cc-dd-ee-ff": ConnectedDeviceBatteryReading(
                    percent: 47,
                    detail: "L 52% · R 47%"
                ),
            ]
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].batteryPercent, 47)
        XCTAssertEqual(resolved[0].detail, "L 52% · R 47%")
    }

    func testAppliesIOBluetoothAirPodsAliasWhenHIDAddressIsUnavailable() {
        let devices = [
            ConnectedPowerDevice(
                id: "1452-8231-bt-aacp",
                name: "AirPods",
                kind: .headphones,
                transport: "BT-AACP",
                batteryPercent: nil,
                isConnected: true,
                detail: nil
            ),
        ]

        let resolved = ConnectedDeviceReader.devices(
            devices,
            applyingBatteryPercentsByName: [:],
            applyingBatteryReadingsByKey: [
                "airpods": ConnectedDeviceBatteryReading(
                    percent: 47,
                    detail: "L 52% · R 47%"
                ),
            ]
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].batteryPercent, 47)
        XCTAssertEqual(resolved[0].detail, "L 52% · R 47%")
    }

    func testParsesBluetoothHIDDeviceWithoutBatteryPercent() {
        let dictionaries: [NSDictionary] = [
            [
                "Product": "Keychron B6 Pro",
                "Transport": "Bluetooth Low Energy",
                "VendorID": 13364,
                "ProductID": 1889,
            ],
            [
                "Product": "Apple Internal Keyboard / Trackpad",
                "Transport": "FIFO",
                "Built-In": true,
            ],
        ]

        let devices = ConnectedDeviceReader.devices(fromIORegistryDictionaries: dictionaries)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].name, "Keychron B6 Pro")
        XCTAssertEqual(devices[0].kind, .keyboard)
        XCTAssertEqual(devices[0].transport, "Bluetooth Low Energy")
        XCTAssertNil(devices[0].batteryPercent)
    }

    func testParsesBluetoothHIDDeviceBatteryPercent() {
        let dictionaries: [NSDictionary] = [
            [
                "Product": "Magic Mouse",
                "Transport": "Bluetooth",
                "BatteryPercent": 41,
            ],
        ]

        let devices = ConnectedDeviceReader.devices(fromIORegistryDictionaries: dictionaries)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].kind, .mouse)
        XCTAssertEqual(devices[0].batteryPercent, 41)
    }

    func testInfersAirPodsFromAppleAACPDeviceWithoutPublishedName() {
        let dictionaries: [NSDictionary] = [
            [
                "Transport": "BT-AACP",
                "VendorID": 1452,
                "ProductID": 8231,
                "BT_ADDR": Data([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]),
            ],
        ]

        let devices = ConnectedDeviceReader.devices(fromIORegistryDictionaries: dictionaries)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].name, "AirPods")
        XCTAssertEqual(devices[0].kind, .headphones)
        XCTAssertEqual(devices[0].transport, "BT-AACP")
        XCTAssertEqual(devices[0].id, "aa-bb-cc-dd-ee-ff")
        XCTAssertNil(devices[0].batteryPercent)
    }

    func testDeduplicatesCompositeBluetoothKeyboardServices() {
        let dictionaries: [NSDictionary] = [
            [
                "Product": "Keychron B6 Pro",
                "Transport": "Bluetooth Low Energy",
                "VendorID": 13364,
                "ProductID": 1889,
                "HIDPointerAccelerationType": "HIDMouseAcceleration",
            ],
            [
                "Product": "Keychron B6 Pro",
                "Transport": "Bluetooth Low Energy",
                "VendorID": 13364,
                "ProductID": 1889,
                "PrimaryUsage": 6,
            ],
        ]

        let devices = ConnectedDeviceReader.devices(fromIORegistryDictionaries: dictionaries)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].name, "Keychron B6 Pro")
        XCTAssertEqual(devices[0].kind, .keyboard)
    }
}
