import Darwin
import Foundation
import IOKit

final class HIDTemperatureReader {
    private typealias IOHIDEventSystemClientRef = CFTypeRef
    private typealias IOHIDServiceClientRef = CFTypeRef
    private typealias IOHIDEventRef = CFTypeRef

    private typealias CreateFunc = @convention(c) (CFAllocator?) -> Unmanaged<IOHIDEventSystemClientRef>?
    private typealias SetMatchingFunc = @convention(c) (IOHIDEventSystemClientRef, CFDictionary?) -> Void
    private typealias CopyServicesFunc = @convention(c) (IOHIDEventSystemClientRef) -> Unmanaged<CFArray>?
    private typealias CopyEventFunc = @convention(c) (IOHIDServiceClientRef, Int64, Int32, Int64) -> Unmanaged<IOHIDEventRef>?
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

        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }

        let matching: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        setMatching(client, matching as CFDictionary)

        guard let services = copyServices(client)?.takeRetainedValue() else { return nil }

        var maxTemp: Double = 0
        let count = CFArrayGetCount(services)

        for index in 0..<count {
            let service = unsafeBitCast(
                CFArrayGetValueAtIndex(services, index),
                to: IOHIDServiceClientRef.self
            )

            if let event = copyEvent(service, eventTypeTemperature, 0, 0)?.takeRetainedValue() {
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

        guard let handle = dlopen(nil, RTLD_NOW) else { return }

        guard let createSymbol = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let setMatchingSymbol = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let copyServicesSymbol = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let copyEventSymbol = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let getFloatValueSymbol = dlsym(handle, "IOHIDEventGetFloatValue") else {
            return
        }

        create = unsafeBitCast(createSymbol, to: CreateFunc.self)
        setMatching = unsafeBitCast(setMatchingSymbol, to: SetMatchingFunc.self)
        copyServices = unsafeBitCast(copyServicesSymbol, to: CopyServicesFunc.self)
        copyEvent = unsafeBitCast(copyEventSymbol, to: CopyEventFunc.self)
        getFloatValue = unsafeBitCast(getFloatValueSymbol, to: GetFloatValueFunc.self)
        isInitialized = true
    }
}
