import Foundation
import Darwin

enum SystemInfoReader {
    static func socName() -> String? {
        guard let brand = sysctlString("machdep.cpu.brand_string") else { return nil }
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func hardwareModel() -> String? {
        sysctlString("hw.model")?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        if sysctlbyname(name, nil, &size, nil, 0) != 0 || size == 0 {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: Int(size))
        if sysctlbyname(name, &buffer, &size, nil, 0) != 0 {
            return nil
        }

        return String(cString: buffer)
    }
}
