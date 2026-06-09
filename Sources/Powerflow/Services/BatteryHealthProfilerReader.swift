import Foundation

final class BatteryHealthProfilerReader {
    private let profilerPath: String
    private let timeout: TimeInterval

    init(profilerPath: String = "/usr/sbin/system_profiler", timeout: TimeInterval = 4) {
        self.profilerPath = profilerPath
        self.timeout = timeout
    }

    func readMaximumCapacityPercent() -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: profilerPath)
        process.arguments = ["SPPowerDataType", "-json"]

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
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return Self.maximumCapacityPercent(from: data)
    }

    static func maximumCapacityPercent(from profilerJSON: Data) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: profilerJSON) as? [String: Any],
              let powerItems = root["SPPowerDataType"] as? [[String: Any]] else {
            return nil
        }

        for item in powerItems {
            if let healthInfo = item["sppower_battery_health_info"] as? [String: Any],
               let percent = parsePercent(healthInfo["sppower_battery_health_maximum_capacity"]) {
                return percent
            }

            if let percent = parsePercent(item["sppower_battery_health_maximum_capacity"]) {
                return percent
            }
        }

        return nil
    }

    private static func parsePercent(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }

        guard let string = value as? String else { return nil }
        let normalized = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(normalized)
    }
}
