import XCTest
@testable import Powerflow

final class SMCValueTests: XCTestCase {
    func testSignedFixedPointDecodesBigEndianSMCTemperature() throws {
        let value = SMCValue(
            key: "TC0P",
            dataSize: 2,
            dataType: "sp78",
            bytes: [0x32, 0x00]
        )

        XCTAssertEqual(try XCTUnwrap(value.floatValue()), 50.0, accuracy: 0.001)
    }

    func testUnsignedFixedPointDecodesBigEndianFanRPM() throws {
        let value = SMCValue(
            key: "F0Ac",
            dataSize: 2,
            dataType: "fpe2",
            bytes: [0x38, 0x40]
        )

        XCTAssertEqual(try XCTUnwrap(value.floatValue()), 3600.0, accuracy: 0.001)
    }

    func testIntegerValuesDecodeBigEndianPayloads() throws {
        let value = SMCValue(
            key: "B0CT",
            dataSize: 2,
            dataType: "ui16",
            bytes: [0x01, 0x2C]
        )

        XCTAssertEqual(try XCTUnwrap(value.floatValue()), 300.0, accuracy: 0.001)
    }

    func testFloatValueDecodesBigEndianPayload() throws {
        let value = SMCValue(
            key: "PSTR",
            dataSize: 4,
            dataType: "flt",
            bytes: [0x42, 0x48, 0x00, 0x00]
        )

        XCTAssertEqual(try XCTUnwrap(value.floatValue()), 50.0, accuracy: 0.001)
    }

    func testSignedIntegersDecodeNegativeBigEndianPayloads() throws {
        let si16 = SMCValue(
            key: "TEST",
            dataSize: 2,
            dataType: "si16",
            bytes: [0xff, 0xd6]
        )
        let si32 = SMCValue(
            key: "TEST",
            dataSize: 4,
            dataType: "si32",
            bytes: [0xff, 0xff, 0xff, 0xd6]
        )

        XCTAssertEqual(try XCTUnwrap(si16.floatValue()), -42, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(si32.floatValue()), -42, accuracy: 0.001)
    }

    func testStringValueUsesDataSizeAndStopsAtNull() throws {
        let value = SMCValue(
            key: "TEST",
            dataSize: 6,
            dataType: "ch8*",
            bytes: Array("M4 Pro".utf8) + [0, 0xff]
        )

        XCTAssertEqual(value.stringValue(), "M4 Pro")
    }

    func testShortBuffersReturnNil() {
        let value = SMCValue(
            key: "TEST",
            dataSize: 4,
            dataType: "ui32",
            bytes: [0x01, 0x02]
        )

        XCTAssertNil(value.floatValue())
    }
}
