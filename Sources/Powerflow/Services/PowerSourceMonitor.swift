import Foundation
import IOKit.ps

final class PowerSourceMonitor {
    private var runLoopSource: CFRunLoopSource?
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func start() {
        guard runLoopSource == nil else { return }
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleChange()
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSCreateLimitedPowerNotification(callback, context)?.takeRetainedValue() else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        guard let source = runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = nil
    }

    private func handleChange() {
        handler()
    }

    deinit {
        stop()
    }
}
