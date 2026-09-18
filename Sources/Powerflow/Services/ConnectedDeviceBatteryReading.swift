import Foundation

struct ConnectedDeviceBatteryReading: Equatable {
    let percent: Int
    let detail: String?
}

enum ConnectedDeviceKey {
    static func normalizedName(_ name: String) -> String {
        name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    static func normalizedAddress(_ address: String) -> String {
        let hex = address
            .lowercased()
            .filter { $0.isHexDigit }
        guard hex.count == 12 else { return normalizedName(address) }
        return stride(from: 0, to: hex.count, by: 2)
            .map { index in
                let start = hex.index(hex.startIndex, offsetBy: index)
                let end = hex.index(start, offsetBy: 2)
                return String(hex[start..<end])
            }
            .joined(separator: "-")
    }
}
