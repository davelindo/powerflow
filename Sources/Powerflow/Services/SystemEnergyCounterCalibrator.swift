import Foundation

struct SystemEnergyCounterCalibrator {
    private struct CalibrationInterval {
        let rawDelta: UInt64
        let referenceWh: Double
        let scale: Double
    }

    private static let requiredIntervals = 12
    private static let maximumIntervals = 24
    private static let maximumScaleDispersion = 0.10
    private static let requiredAgreement = 0.80
    private static let maximumAgreementError = 0.25

    private var lastSample: (raw: UInt64, uptime: TimeInterval, watts: Double)?
    private var calibration: [CalibrationInterval] = []
    private var scaleWhPerUnit: Double?

    var isValidated: Bool { scaleWhPerUnit != nil }

    mutating func energyDeltaWh(
        rawCounter: UInt64?,
        systemLoadWatts: Double?,
        uptime: TimeInterval
    ) -> Double? {
        guard let rawCounter,
              let systemLoadWatts,
              uptime.isFinite,
              systemLoadWatts.isFinite,
              systemLoadWatts >= 0 else {
            reset()
            return nil
        }

        defer {
            lastSample = (rawCounter, uptime, systemLoadWatts)
        }
        guard let previous = lastSample else { return nil }
        let duration = uptime - previous.uptime
        guard duration > 0,
              duration <= PowerflowConstants.maxAppEnergyIntegrationInterval,
              rawCounter >= previous.raw else {
            reset(keeping: (rawCounter, uptime, systemLoadWatts))
            return nil
        }

        let rawDelta = rawCounter - previous.raw
        guard rawDelta > 0 else {
            // History integrates power when the counter cannot supply an
            // interval. Revalidate before accepting a later catch-up delta,
            // which can include energy already covered by that fallback.
            reset(keeping: (rawCounter, uptime, systemLoadWatts))
            return nil
        }

        let referenceWh = ((previous.watts + systemLoadWatts) * 0.5) * duration / 3_600
        guard referenceWh.isFinite, referenceWh > 0 else { return nil }

        if let scaleWhPerUnit {
            let energy = Double(rawDelta) * scaleWhPerUnit
            guard energy.isFinite, energy >= 0 else {
                reset(keeping: (rawCounter, uptime, systemLoadWatts))
                return nil
            }
            let ratio = energy / referenceWh
            guard (0.25...4).contains(ratio) else {
                reset(keeping: (rawCounter, uptime, systemLoadWatts))
                return nil
            }
            return energy
        }

        let candidate = referenceWh / Double(rawDelta)
        guard candidate.isFinite, candidate > 0 else { return nil }
        calibration.append(
            CalibrationInterval(rawDelta: rawDelta, referenceWh: referenceWh, scale: candidate)
        )
        if calibration.count > Self.maximumIntervals {
            calibration.removeFirst(calibration.count - Self.maximumIntervals)
        }
        validateIfReady()
        return scaleWhPerUnit.map { Double(rawDelta) * $0 }
    }

    mutating func reset() {
        reset(keeping: nil)
    }

    private mutating func reset(
        keeping sample: (raw: UInt64, uptime: TimeInterval, watts: Double)?
    ) {
        lastSample = sample
        calibration.removeAll(keepingCapacity: true)
        scaleWhPerUnit = nil
    }

    private mutating func validateIfReady() {
        guard calibration.count >= Self.requiredIntervals else { return }
        let scales = calibration.map(\.scale).sorted()
        let median = Self.median(scales)
        guard median.isFinite, median > 0 else { return }
        let deviations = scales.map { abs($0 - median) }.sorted()
        let relativeDispersion = Self.median(deviations) / median
        guard relativeDispersion <= Self.maximumScaleDispersion else { return }

        let agreeing = calibration.filter { interval in
            let reconstructed = Double(interval.rawDelta) * median
            let error = abs(reconstructed - interval.referenceWh) / interval.referenceWh
            return error <= Self.maximumAgreementError
        }.count
        guard Double(agreeing) / Double(calibration.count) >= Self.requiredAgreement else { return }
        scaleWhPerUnit = median
    }

    private static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) * 0.5
        }
        return sorted[middle]
    }
}
