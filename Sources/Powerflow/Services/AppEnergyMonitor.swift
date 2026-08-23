import Darwin
import Foundation

struct AppActivitySample {
    let offenders: [AppEnergyOffender]
    let isFresh: Bool
    let interval: TimeInterval?
}

final class AppEnergyMonitor {
    private struct ProcessKey: Hashable {
        let pid: Int32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private struct ProcessIdentity {
        let groupID: String
        let displayName: String
        let iconPath: String?
    }

    private struct ProcessSample {
        let key: ProcessKey
        let totalCPUTimeTicks: UInt64
        let residentBytes: UInt64
        let pageins: Int32

        var pid: Int32 { key.pid }
    }

    private struct RankedProcess {
        let key: ProcessKey
        let impactScore: Double
        let cpuPercent: Double
        let memoryBytes: UInt64
        let pageinsPerSecond: Double

        var pid: Int32 { key.pid }
    }

    private struct GroupedProcess {
        let groupID: String
        let displayName: String
        let iconPath: String?
        var primaryPID: Int32
        var processCount: Int
        var impactScore: Double
        var cpuPercent: Double
        var memoryBytes: UInt64
        var pageinsPerSecond: Double
        var leadImpact: Double

        init(identity: ProcessIdentity, process: RankedProcess) {
            groupID = identity.groupID
            displayName = identity.displayName
            iconPath = identity.iconPath
            primaryPID = process.pid
            processCount = 1
            impactScore = process.impactScore
            cpuPercent = process.cpuPercent
            memoryBytes = process.memoryBytes
            pageinsPerSecond = process.pageinsPerSecond
            leadImpact = process.impactScore
        }

        mutating func absorb(_ process: RankedProcess) {
            processCount += 1
            impactScore += process.impactScore
            cpuPercent += process.cpuPercent
            memoryBytes += process.memoryBytes
            pageinsPerSecond += process.pageinsPerSecond
            if process.impactScore > leadImpact {
                primaryPID = process.pid
                leadImpact = process.impactScore
            }
        }
    }

    private var lastSamples: [ProcessKey: ProcessSample] = [:]
    private var lastRefreshAt: Date?
    private var lastSampleUptime: TimeInterval?
    private var hasComputedDelta = false
    private var cachedOffenders: [AppEnergyOffender] = []
    private var identityCache: [ProcessKey: ProcessIdentity] = [:]
    private let nanosecondsPerCPUTick: Double

    init() {
        var timebase = mach_timebase_info_data_t()
        if mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 {
            nanosecondsPerCPUTick = Double(timebase.numer) / Double(timebase.denom)
        } else {
            nanosecondsPerCPUTick = 1
        }
    }

    func sample(
        detailLevel: PowerSnapshotDetailLevel,
        at now: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> AppActivitySample {
        let refreshInterval = detailLevel == .full
            ? PowerflowConstants.appEnergyFullRefreshInterval
            : PowerflowConstants.appEnergySummaryRefreshInterval
        let requiredInterval = hasComputedDelta
            ? refreshInterval
            : min(refreshInterval, PowerflowConstants.appEnergyBaselineRefreshInterval)

        if let lastRefreshAt,
           now.timeIntervalSince(lastRefreshAt)
            < max(requiredInterval - PowerflowConstants.timerIntervalTolerance, 0) {
            return AppActivitySample(offenders: cachedOffenders, isFresh: false, interval: nil)
        }

        let samples = currentProcessSamples()
        let sampleMap = Dictionary(uniqueKeysWithValues: samples.map { ($0.key, $0) })
        identityCache = identityCache.filter { sampleMap[$0.key] != nil }

        defer {
            lastSamples = sampleMap
            lastRefreshAt = now
            lastSampleUptime = uptime
        }

        guard let lastSampleUptime, uptime > lastSampleUptime else {
            return AppActivitySample(offenders: cachedOffenders, isFresh: false, interval: nil)
        }

        let elapsed = uptime - lastSampleUptime
        let ranked = rankedProcesses(from: samples, elapsed: elapsed)
        cachedOffenders = groupedOffenders(from: ranked)
        hasComputedDelta = true
        return AppActivitySample(offenders: cachedOffenders, isFresh: true, interval: elapsed)
    }

    func reset() {
        guard lastRefreshAt != nil || !lastSamples.isEmpty || !cachedOffenders.isEmpty else { return }
        lastSamples.removeAll(keepingCapacity: true)
        identityCache.removeAll(keepingCapacity: true)
        cachedOffenders = []
        lastRefreshAt = nil
        lastSampleUptime = nil
        hasComputedDelta = false
    }

    static func impactScore(
        cpuPercent: Double,
        pageinsPerSecond: Double
    ) -> Double {
        let pageinPenalty = min(pageinsPerSecond * 2.5, 12)
        return cpuPercent + pageinPenalty
    }

    static func cpuPercent(
        currentTicks: UInt64,
        previousTicks: UInt64,
        elapsed: TimeInterval,
        nanosecondsPerTick: Double
    ) -> Double? {
        guard currentTicks >= previousTicks,
              elapsed > 0,
              elapsed.isFinite,
              nanosecondsPerTick > 0,
              nanosecondsPerTick.isFinite else { return nil }
        let deltaNanoseconds = Double(currentTicks - previousTicks) * nanosecondsPerTick
        let value = (deltaNanoseconds / (elapsed * 1_000_000_000)) * 100
        return value.isFinite ? max(value, 0) : nil
    }

    private func rankedProcesses(
        from samples: [ProcessSample],
        elapsed: TimeInterval
    ) -> [RankedProcess] {
        samples.compactMap { current in
            guard let previous = lastSamples[current.key],
                  let cpuPercent = Self.cpuPercent(
                    currentTicks: current.totalCPUTimeTicks,
                    previousTicks: previous.totalCPUTimeTicks,
                    elapsed: elapsed,
                    nanosecondsPerTick: nanosecondsPerCPUTick
                  ) else {
                return nil
            }

            let pageinsDelta = max(current.pageins - previous.pageins, 0)
            let pageinsPerSecond = Double(pageinsDelta) / elapsed
            let impactScore = Self.impactScore(
                cpuPercent: cpuPercent,
                pageinsPerSecond: pageinsPerSecond
            )

            return RankedProcess(
                key: current.key,
                impactScore: impactScore,
                cpuPercent: cpuPercent,
                memoryBytes: current.residentBytes,
                pageinsPerSecond: pageinsPerSecond
            )
        }
        .sorted { lhs, rhs in
            if lhs.impactScore == rhs.impactScore {
                return lhs.cpuPercent > rhs.cpuPercent
            }
            return lhs.impactScore > rhs.impactScore
        }
    }

    private func currentProcessSamples() -> [ProcessSample] {
        let pidCount = max(proc_listallpids(nil, 0), 0)
        var pids = [Int32](repeating: 0, count: Int(pidCount) + 32)
        let actualCount = proc_listallpids(
            &pids,
            Int32(MemoryLayout<Int32>.stride * pids.count)
        )
        guard actualCount > 0 else { return [] }

        return pids
            .prefix(Int(actualCount))
            .filter { $0 > 0 }
            .compactMap(processSample(for:))
    }

    private func processSample(for pid: Int32) -> ProcessSample? {
        var allInfo = proc_taskallinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskallinfo>.stride)
        let result = withUnsafeMutablePointer(to: &allInfo) {
            proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, $0, expectedSize)
        }
        guard result == expectedSize else { return nil }

        return ProcessSample(
            key: ProcessKey(
                pid: pid,
                startSeconds: allInfo.pbsd.pbi_start_tvsec,
                startMicroseconds: allInfo.pbsd.pbi_start_tvusec
            ),
            totalCPUTimeTicks: allInfo.ptinfo.pti_total_user + allInfo.ptinfo.pti_total_system,
            residentBytes: allInfo.ptinfo.pti_resident_size,
            pageins: allInfo.ptinfo.pti_pageins
        )
    }

    private func groupedOffenders(from rankedProcesses: [RankedProcess]) -> [AppEnergyOffender] {
        let totalImpact = rankedProcesses.reduce(0) { $0 + max($1.impactScore, 0) }
        guard totalImpact > 0 else { return [] }
        var groups: [String: GroupedProcess] = [:]

        for rankedProcess in rankedProcesses where rankedProcess.pid != getpid()
            && rankedProcess.impactScore >= PowerflowConstants.minimumAppEnergyContributorImpact {
            let identity = processIdentity(for: rankedProcess.key)

            if var existing = groups[identity.groupID] {
                existing.absorb(rankedProcess)
                groups[identity.groupID] = existing
            } else {
                groups[identity.groupID] = GroupedProcess(identity: identity, process: rankedProcess)
            }
        }

        return groups.values
            .filter { $0.impactScore >= PowerflowConstants.minimumAppEnergyImpact }
            .sorted { lhs, rhs in
                if lhs.impactScore == rhs.impactScore {
                    return lhs.cpuPercent > rhs.cpuPercent
                }
                return lhs.impactScore > rhs.impactScore
            }
            .prefix(PowerflowConstants.appEnergyOffenderLimit)
            .map { group in
                AppEnergyOffender(
                    groupID: group.groupID,
                    primaryPID: group.primaryPID,
                    name: group.displayName,
                    iconPath: group.iconPath,
                    processCount: group.processCount,
                    impactScore: group.impactScore,
                    cpuPercent: group.cpuPercent,
                    memoryBytes: group.memoryBytes,
                    pageinsPerSecond: group.pageinsPerSecond,
                    activityShare: group.impactScore / totalImpact
                )
            }
    }

    private func processIdentity(for key: ProcessKey) -> ProcessIdentity {
        if let cached = identityCache[key] {
            return cached
        }
        let pid = key.pid

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if pathLength > 0 {
            let executableURL = URL(fileURLWithPath: Self.decodedCString(pathBuffer))
            if let appInfo = rootApplicationInfo(for: executableURL) {
                let normalizedName = normalizeProcessName(appInfo.name)
                let identity = ProcessIdentity(
                    groupID: appInfo.bundleIdentifier ?? "app:\(normalizedName.lowercased())",
                    displayName: normalizedName,
                    iconPath: appInfo.bundlePath
                )
                identityCache[key] = identity
                return identity
            }

            let executableName = normalizeProcessName(executableURL.deletingPathExtension().lastPathComponent)
            let identity = ProcessIdentity(
                groupID: "process:\(executableName.lowercased())",
                displayName: executableName,
                iconPath: executableURL.path
            )
            identityCache[key] = identity
            return identity
        }

        var nameBuffer = [CChar](repeating: 0, count: 64)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        if nameLength > 0 {
            let processName = normalizeProcessName(Self.decodedCString(nameBuffer))
            let identity = ProcessIdentity(
                groupID: "process:\(processName.lowercased())",
                displayName: processName,
                iconPath: nil
            )
            identityCache[key] = identity
            return identity
        }

        let fallbackName = "Process \(pid)"
        let identity = ProcessIdentity(
            groupID: "process:unknown",
            displayName: fallbackName,
            iconPath: nil
        )
        identityCache[key] = identity
        return identity
    }

    private func rootApplicationInfo(
        for executableURL: URL
    ) -> (name: String, bundlePath: String, bundleIdentifier: String?)? {
        let pathComponents = executableURL.pathComponents
        guard let appIndex = pathComponents.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let bundlePath = NSString.path(withComponents: Array(pathComponents.prefix(appIndex + 1)))
        let bundleURL = URL(fileURLWithPath: bundlePath)
        let appName = bundleURL.deletingPathExtension().lastPathComponent
        guard !appName.isEmpty else { return nil }
        return (
            name: appName,
            bundlePath: bundleURL.path,
            bundleIdentifier: Bundle(url: bundleURL)?.bundleIdentifier
        )
    }

    private static func decodedCString(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func normalizeProcessName(_ name: String) -> String {
        let patterns = [
            " Helper \\(.+\\)$",
            " Helper$",
            " Renderer$",
            " GPU$",
            " Plugin$",
        ]

        for pattern in patterns {
            if let range = name.range(of: pattern, options: .regularExpression) {
                return String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
