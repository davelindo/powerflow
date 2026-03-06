import Darwin
import Foundation

final class AppEnergyMonitor {
    private struct ProcessIdentity {
        let groupID: String
        let displayName: String
        let iconPath: String?
    }

    private struct ProcessSample {
        let pid: Int32
        let totalCPUTimeMicros: UInt64
        let residentBytes: UInt64
        let pageins: Int32
        let threadCount: Int32
    }

    private struct RankedProcess {
        let pid: Int32
        let impactScore: Double
        let cpuPercent: Double
        let memoryBytes: UInt64
        let pageinsPerSecond: Double
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

    private var lastSamples: [Int32: ProcessSample] = [:]
    private var lastRefreshAt: Date?
    private var cachedOffenders: [AppEnergyOffender] = []
    private var identityCache: [Int32: ProcessIdentity] = [:]

    func sample(detailLevel: PowerSnapshotDetailLevel, at now: Date = Date()) -> [AppEnergyOffender] {
        let refreshInterval = detailLevel == .full
            ? PowerflowConstants.appEnergyFullRefreshInterval
            : PowerflowConstants.appEnergySummaryRefreshInterval

        if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < refreshInterval {
            return cachedOffenders
        }

        let samples = currentProcessSamples()
        let sampleMap = Dictionary(uniqueKeysWithValues: samples.map { ($0.pid, $0) })
        identityCache = identityCache.filter { sampleMap[$0.key] != nil }

        defer {
            lastSamples = sampleMap
            lastRefreshAt = now
        }

        guard let lastRefreshAt else { return cachedOffenders }

        let elapsed = max(now.timeIntervalSince(lastRefreshAt), 0.5)
        let ranked = rankedProcesses(from: samples, elapsed: elapsed)
        cachedOffenders = groupedOffenders(from: ranked)
        return cachedOffenders
    }

    static func impactScore(
        cpuPercent: Double,
        pageinsPerSecond: Double,
        threadCount: Int32
    ) -> Double {
        let pageinPenalty = min(pageinsPerSecond * 2.5, 12)
        let threadPenalty = min(Double(max(threadCount - 8, 0)) * 0.08, 6)
        return cpuPercent + pageinPenalty + threadPenalty
    }

    private func rankedProcesses(
        from samples: [ProcessSample],
        elapsed: TimeInterval
    ) -> [RankedProcess] {
        samples.compactMap { current in
            guard current.pid != getpid(),
                  let previous = lastSamples[current.pid],
                  current.totalCPUTimeMicros >= previous.totalCPUTimeMicros else {
                return nil
            }

            let cpuDeltaMicros = current.totalCPUTimeMicros - previous.totalCPUTimeMicros
            let cpuPercent = (Double(cpuDeltaMicros) / (elapsed * 1_000_000.0)) * 100.0
            let pageinsDelta = max(current.pageins - previous.pageins, 0)
            let pageinsPerSecond = Double(pageinsDelta) / elapsed
            let impactScore = Self.impactScore(
                cpuPercent: cpuPercent,
                pageinsPerSecond: pageinsPerSecond,
                threadCount: current.threadCount
            )

            guard impactScore >= PowerflowConstants.minimumAppEnergyContributorImpact else { return nil }

            return RankedProcess(
                pid: current.pid,
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
        var taskInfo = proc_taskinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.stride)
        let result = withUnsafeMutablePointer(to: &taskInfo) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, expectedSize)
        }
        guard result == expectedSize else { return nil }

        return ProcessSample(
            pid: pid,
            totalCPUTimeMicros: taskInfo.pti_total_user + taskInfo.pti_total_system,
            residentBytes: taskInfo.pti_resident_size,
            pageins: taskInfo.pti_pageins,
            threadCount: taskInfo.pti_threadnum
        )
    }

    private func groupedOffenders(from rankedProcesses: [RankedProcess]) -> [AppEnergyOffender] {
        var groups: [String: GroupedProcess] = [:]

        for rankedProcess in rankedProcesses {
            let identity = processIdentity(for: rankedProcess.pid)

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
                    pageinsPerSecond: group.pageinsPerSecond
                )
            }
    }

    private func processIdentity(for pid: Int32) -> ProcessIdentity {
        if let cached = identityCache[pid] {
            return cached
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if pathLength > 0 {
            let executableURL = URL(fileURLWithPath: String(cString: pathBuffer))
            if let appInfo = rootApplicationInfo(for: executableURL) {
                let normalizedName = normalizeProcessName(appInfo.name)
                let identity = ProcessIdentity(
                    groupID: appInfo.bundlePath.lowercased(),
                    displayName: normalizedName,
                    iconPath: appInfo.bundlePath
                )
                identityCache[pid] = identity
                return identity
            }

            let executableName = normalizeProcessName(executableURL.deletingPathExtension().lastPathComponent)
            let identity = ProcessIdentity(
                groupID: executableName.lowercased(),
                displayName: executableName,
                iconPath: executableURL.path
            )
            identityCache[pid] = identity
            return identity
        }

        var nameBuffer = [CChar](repeating: 0, count: 64)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        if nameLength > 0 {
            let processName = normalizeProcessName(String(cString: nameBuffer))
            let identity = ProcessIdentity(
                groupID: processName.lowercased(),
                displayName: processName,
                iconPath: nil
            )
            identityCache[pid] = identity
            return identity
        }

        let fallbackName = "Process \(pid)"
        let identity = ProcessIdentity(
            groupID: fallbackName.lowercased(),
            displayName: fallbackName,
            iconPath: nil
        )
        identityCache[pid] = identity
        return identity
    }

    private func rootApplicationInfo(for executableURL: URL) -> (name: String, bundlePath: String)? {
        let pathComponents = executableURL.pathComponents
        guard let appIndex = pathComponents.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let bundlePath = NSString.path(withComponents: Array(pathComponents.prefix(appIndex + 1)))
        let bundleURL = URL(fileURLWithPath: bundlePath)
        let appName = bundleURL.deletingPathExtension().lastPathComponent
        guard !appName.isEmpty else { return nil }
        return (name: appName, bundlePath: bundleURL.path)
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
