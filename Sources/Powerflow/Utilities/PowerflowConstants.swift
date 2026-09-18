import Foundation

/// Centralized constants for the Powerflow application.
enum PowerflowConstants {

    // MARK: - Power Balance Thresholds

    /// Minimum power magnitude (watts) to consider for balance calculations.
    static let minimumPowerMagnitude: Double = 0.5

    /// Default allowed mismatch for power balance consistency checks.
    static let defaultPowerBalanceMismatch: Double = 1.0

    /// Percentage tolerance for power balance mismatch (0.25 = 25%).
    static let powerBalanceMismatchTolerance: Double = 0.25

    /// Upper bound for a physically plausible power reading on a Mac.
    static let maximumValidPowerWatts: Double = 500

    /// Upper bounds for USB-C adapter telemetry.
    static let maximumValidAdapterVoltage: Double = 100
    static let maximumValidAdapterCurrent: Double = 20

    /// Upper bound used to reject corrupt SMC fan samples.
    static let maximumValidFanRPM: Double = 20_000

    // MARK: - Battery Care Thresholds

    /// Resume charging margin below the target (percentage points).
    static let chargingResumeMargin: Double = 2.0

    // MARK: - Time Limits

    /// Maximum reasonable charging time (12 hours in minutes).
    static let maxChargeMinutes: Int = 12 * 60

    /// Maximum reasonable discharge time (48 hours in minutes).
    static let maxDischargeMinutes: Int = 48 * 60

    // MARK: - Temperature Limits

    /// Maximum valid CPU temperature reading in Celsius.
    static let maxValidCpuTemperature: Double = 150.0

    /// Minimum valid temperature reading in Celsius.
    static let minValidTemperature: Double = 0.0

    // MARK: - SMC Reading

    /// Minimum battery rate threshold to detect polarity.
    static let batteryRatePolarityThreshold: Double = 0.05

    /// Minimum current value to consider valid for scaling inference.
    static let minimumCurrentForScaling: Double = 0.01

    /// Voltage threshold to determine if value is in millivolts vs volts.
    static let voltageUnitThreshold: Double = 100.0

    // MARK: - Update Intervals

    /// Cooldown between CPU temperature scan attempts after failure.
    static let cpuTempScanCooldown: TimeInterval = 30

    /// Background update interval when popover is not visible.
    static let backgroundUpdateInterval: TimeInterval = 10.0

    /// Higher-fidelity cadence used only while background application-energy
    /// accounting is enabled. Summary reads avoid foreground-only enrichment.
    static let backgroundAppEnergyUpdateInterval: TimeInterval = 5.0

    /// Dispatch timers may arrive a few milliseconds before their nominal
    /// boundary. Treat those coalesced firings as on time instead of waiting
    /// for an entire additional interval.
    static let timerIntervalTolerance: TimeInterval = 0.25

    /// Refresh interval for background app offender sampling.
    static let appEnergySummaryRefreshInterval: TimeInterval = 5.0

    /// Refresh interval for popover/full-detail app offender sampling.
    static let appEnergyFullRefreshInterval: TimeInterval = 5.0

    /// Follow-up interval used only to turn the first cumulative process sample
    /// into a usable delta promptly.
    static let appEnergyBaselineRefreshInterval: TimeInterval = 2.0

    /// Do not interpolate power across sleep, long stalls, or clock anomalies.
    static let maxAppEnergyIntegrationInterval: TimeInterval = 60.0

    /// Number of recent app offenders to surface in the UI.
    static let appEnergyOffenderLimit: Int = 4

    /// Minimum per-process impact required to contribute to an app group.
    static let minimumAppEnergyContributorImpact: Double = 0.1

    /// Minimum impact score to surface an offender row.
    static let minimumAppEnergyImpact: Double = 0.5

    /// Summary CPU temperature refresh interval.
    static let summaryCpuTempRefreshInterval: TimeInterval = 30

    /// Full detail CPU temperature refresh interval.
    static let fullCpuTempRefreshInterval: TimeInterval = 5

    /// Maximum age for cached CPU temperature before refresh.
    static let maxCachedCpuTempAge: TimeInterval = 120

    /// Interval between persisting CPU temperature to disk.
    static let cpuTempPersistInterval: TimeInterval = 60

    // MARK: - Warmup

    /// Number of samples to collect during warmup.
    static let warmupSampleTarget: Int = 12

    /// Maximum duration for warmup phase.
    static let warmupMaxDuration: TimeInterval = 60

    // MARK: - History

    /// Maximum number of history points to retain.
    static let historyCapacity: Int = 600

    // MARK: - Consistency

    /// Retry interval for power balance consistency checks.
    static let consistencyRetryInterval: TimeInterval = 0.4

    /// Maximum attempts before accepting inconsistent snapshot.
    static let maxConsistencyAttempts: Int = 3

    // MARK: - XPC

    /// Timeout for XPC connection health checks.
    static let xpcHealthCheckTimeout: TimeInterval = 5.0

    /// Maximum age for XPC connection before refresh.
    static let xpcConnectionMaxAge: TimeInterval = 300.0
}
