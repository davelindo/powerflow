import Foundation
import IOKit

private let kSMCServiceName = "AppleSMC"
private let kSMCUserClient = UInt32(0)
private let kSMCIndex = UInt32(2)
private let kSMCCmdReadKeyInfo = UInt8(9)
private let kSMCCmdReadBytes = UInt8(5)
private let smcTypeTrimSet = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)

private typealias SMCBytes32 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private func makeBytes32() -> SMCBytes32 {
    (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private func bytesArray(from tuple: SMCBytes32) -> [UInt8] {
    withUnsafeBytes(of: tuple) { Array($0) }
}

private func keyToUInt32(_ key: String) -> UInt32 {
    var value: UInt32 = 0
    for byte in key.utf8.prefix(4) {
        value = (value << 8) | UInt32(byte)
    }
    return value
}

private func u32ToTypeString(_ value: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
    return String(bytes: bytes, encoding: .utf8)?
        .trimmingCharacters(in: smcTypeTrimSet)
        .lowercased() ?? ""
}

private struct SMCDataVers {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var reserved: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers: SMCDataVers = SMCDataVers()
    var pLimitData: SMCPLimitData = SMCPLimitData()
    var keyInfo: SMCKeyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var padding: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes32 = makeBytes32()
}

struct SMCValue {
    var key: String
    var dataSize: Int
    var dataType: String
    var bytes: [UInt8]

    func floatValue() -> Double? {
        switch dataType {
        case "flt":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
            return Double(Float32(bitPattern: raw))
        case "si8":
            guard let value = bytes.first else { return nil }
            return Double(Int8(bitPattern: value))
        case "ui8":
            guard let value = bytes.first else { return nil }
            return Double(value)
        case "si16":
            guard bytes.count >= 2 else { return nil }
            let raw = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
            return Double(Int16(bitPattern: raw))
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            let raw = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
            return Double(raw)
        case "si32":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
            return Double(Int32(bitPattern: raw))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
            return Double(raw)
        case "si64":
            guard bytes.count >= 8 else { return nil }
            var raw: UInt64 = 0
            for index in 0..<8 {
                raw |= UInt64(bytes[index]) << (UInt64(index) * 8)
            }
            return Double(Int64(bitPattern: raw))
        case "ui64":
            guard bytes.count >= 8 else { return nil }
            var raw: UInt64 = 0
            for index in 0..<8 {
                raw |= UInt64(bytes[index]) << (UInt64(index) * 8)
            }
            return Double(raw)
        case "flag":
            guard let value = bytes.first else { return nil }
            return value == 0 ? 0 : 1
        default:
            if dataType.hasPrefix("fp") || dataType.hasPrefix("sp") {
                return fixedPointValue(type: dataType)
            }
            return nil
        }
    }

    func stringValue() -> String? {
        guard dataType.hasPrefix("ch") else { return nil }
        let size = max(0, min(dataSize, bytes.count))
        guard size > 0 else { return nil }
        let slice = bytes.prefix(size)
        let trimmed = slice.prefix { $0 != 0 }
        guard !trimmed.isEmpty else { return nil }
        return String(bytes: trimmed, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fixedPointValue(type: String) -> Double? {
        guard bytes.count >= 2 else { return nil }
        let mapping: [String: (Double, Bool)] = [
            "fp1f": (32768.0, false),
            "fp2e": (16384.0, false),
            "fp3d": (8192.0, false),
            "fp4c": (4096.0, false),
            "fp5b": (2048.0, false),
            "fp6a": (1024.0, false),
            "fp79": (512.0, false),
            "fp88": (256.0, false),
            "fpa6": (64.0, false),
            "fpc4": (16.0, false),
            "fpe2": (4.0, false),
            "sp1e": (16384.0, true),
            "sp2d": (8192.0, true),
            "sp3c": (4096.0, true),
            "sp4b": (2048.0, true),
            "sp5a": (1024.0, true),
            "sp69": (512.0, true),
            "sp78": (256.0, true),
            "sp87": (128.0, true),
            "sp96": (64.0, true),
            "spa5": (32.0, true),
            "spb4": (16.0, true),
            "spf0": (1.0, true),
        ]

        guard let (divisor, signed) = mapping[type] else { return nil }
        let raw = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        if signed {
            let signedValue = Int16(bitPattern: raw)
            return Double(signedValue) / divisor
        }
        return Double(raw) / divisor
    }
}

final class SMCConnection {
    private let connection: io_connect_t
    private var keyInfoCache: [UInt32: SMCKeyInfo] = [:]
    private var dataTypeCache: [UInt32: String] = [:]

    init?() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(kSMCServiceName)
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, kSMCUserClient, &connect)
        guard result == KERN_SUCCESS else { return nil }
        connection = connect
    }

    deinit {
        IOServiceClose(connection)
    }

    func readKey(_ key: String) -> SMCValue? {
        let keyInt = keyToUInt32(key)
        guard let keyInfo = getKeyInfo(keyInt) else { return nil }

        var input = SMCKeyData()
        input.key = keyInt
        input.data8 = kSMCCmdReadBytes
        input.keyInfo = keyInfo

        guard let output = call(input: input) else { return nil }

        let bytes = bytesArray(from: output.bytes)
        let dataType = cachedDataType(for: keyInt, info: keyInfo)
        return SMCValue(
            key: key,
            dataSize: Int(keyInfo.dataSize),
            dataType: dataType,
            bytes: bytes
        )
    }

    private func getKeyInfo(_ key: UInt32) -> SMCKeyInfo? {
        if let cached = keyInfoCache[key] {
            return cached
        }

        var input = SMCKeyData()
        input.key = key
        input.data8 = kSMCCmdReadKeyInfo

        guard let output = call(input: input) else { return nil }
        let info = output.keyInfo
        keyInfoCache[key] = info
        return info
    }

    private func cachedDataType(for key: UInt32, info: SMCKeyInfo) -> String {
        if let cached = dataTypeCache[key] {
            return cached
        }
        let type = u32ToTypeString(info.dataType)
        dataTypeCache[key] = type
        return type
    }

    private func call(input: SMCKeyData) -> SMCKeyData? {
        var input = input
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.size

        let result = withUnsafePointer(to: &input) { inputPtr -> kern_return_t in
            withUnsafeMutablePointer(to: &output) { outputPtr -> kern_return_t in
                IOConnectCallStructMethod(
                    connection,
                    kSMCIndex,
                    inputPtr,
                    MemoryLayout<SMCKeyData>.size,
                    outputPtr,
                    &outputSize
                )
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        return output
    }
}
