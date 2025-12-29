import Darwin
import Foundation
import IOKit

final class HIDTemperatureReader {
    private typealias IOHIDEventSystemClientRef = OpaquePointer
    private typealias IOHIDServiceClientRef = OpaquePointer
    private typealias IOHIDEventRef = OpaquePointer

    private typealias CreateFunc = @convention(c) (CFAllocator?) -> IOHIDEventSystemClientRef?
    private typealias SetMatchingFunc = @convention(c) (IOHIDEventSystemClientRef, CFDictionary?) -> Void
    private typealias CopyServicesFunc = @convention(c) (IOHIDEventSystemClientRef) -> CFArray?
    private typealias CopyEventFunc = @convention(c) (IOHIDServiceClientRef, Int64, Int32, Int64) -> IOHIDEventRef?
    private typealias GetFloatValueFunc = @convention(c) (IOHIDEventRef, UInt32) -> Double

    private var create: CreateFunc?
    private var setMatching: SetMatchingFunc?
    private var copyServices: CopyServicesFunc?
    private var copyEvent: CopyEventFunc?
    private var getFloatValue: GetFloatValueFunc?
    private var isInitialized = false

    private let eventTypeTemperature: Int64 = 15
    private let temperatureLevelField: UInt32 = 0xf0000

    func readCPUTemperature() -> Double? {
        ensureInitialized()

        guard let create,
              let setMatching,
              let copyServices,
              let copyEvent,
              let getFloatValue else { return nil }

        guard let client = create(kCFAllocatorDefault) else { return nil }

        let matching: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        setMatching(client, matching as CFDictionary)

        guard let services = copyServices(client) else { return nil }

        var maxTemp: Double = 0
        let count = CFArrayGetCount(services)

        for index in 0..<count {
            let service = unsafeBitCast(
                CFArrayGetValueAtIndex(services, index),
                to: IOHIDServiceClientRef.self
            )

            if let event = copyEvent(service, eventTypeTemperature, 0, 0) {
                let temp = getFloatValue(event, temperatureLevelField)
                if temp > maxTemp && temp < 150 {
                    maxTemp = temp
                }
            }
        }

        return maxTemp > 0 ? maxTemp : nil
    }

    private func ensureInitialized() {
        guard !isInitialized else { return }
        isInitialized = true

        guard let handle = dlopen(nil, RTLD_NOW) else { return }

        create = unsafeBitCast(
            dlsym(handle, "IOHIDEventSystemClientCreate"),
            to: CreateFunc?.self
        )
        setMatching = unsafeBitCast(
            dlsym(handle, "IOHIDEventSystemClientSetMatching"),
            to: SetMatchingFunc?.self
        )
        copyServices = unsafeBitCast(
            dlsym(handle, "IOHIDEventSystemClientCopyServices"),
            to: CopyServicesFunc?.self
        )
        copyEvent = unsafeBitCast(
            dlsym(handle, "IOHIDServiceClientCopyEvent"),
            to: CopyEventFunc?.self
        )
        getFloatValue = unsafeBitCast(
            dlsym(handle, "IOHIDEventGetFloatValue"),
            to: GetFloatValueFunc?.self
        )
    }
}
