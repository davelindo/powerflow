import Foundation
import IOKit.ps

final class PowerSourceReader {
    func timeRemainingMinutes() -> Int? {
        let estimate = IOPSGetTimeRemainingEstimate()
        if estimate == kIOPSTimeRemainingUnknown || estimate == kIOPSTimeRemainingUnlimited {
            return nil
        }
        guard estimate >= 0 else { return nil }
        return Int(estimate.rounded())
    }
}
