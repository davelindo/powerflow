import Foundation

final class ThermalPressureReader {
    private var token: Int32 = 0
    private var isRegistered = false

    init() {
        register()
    }

    deinit {
        if isRegistered {
            _ = notify_cancel(token)
        }
    }

    func readPressure() -> ThermalPressure? {
        guard isRegistered else { return nil }

        var state: UInt64 = 0
        let result = notify_get_state(token, &state)
        guard result == notifyStatusOK else { return nil }

        let level = Int(state)
        return ThermalPressure(level: level)
    }

    private func register() {
        let result = notify_register_check("com.apple.system.thermalpressurelevel", &token)
        isRegistered = (result == notifyStatusOK)
    }
}

@_silgen_name("notify_register_check")
private func notify_register_check(
    _ name: UnsafePointer<CChar>,
    _ token: UnsafeMutablePointer<Int32>
) -> UInt32

@_silgen_name("notify_get_state")
private func notify_get_state(
    _ token: Int32,
    _ state: UnsafeMutablePointer<UInt64>
) -> UInt32

@_silgen_name("notify_cancel")
private func notify_cancel(_ token: Int32) -> UInt32

private let notifyStatusOK: UInt32 = 0
