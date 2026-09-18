import Foundation

actor AppImpactCache {
    private struct CacheFile: Codable {
        let version: Int
        let generatedAt: Date
        let samples: [CachedSample]
    }

    private struct CachedSample: Codable {
        let timestamp: Date
        let durationSeconds: TimeInterval
        let totalComputeEnergyWh: Double?
        let applications: [CachedApplication]
    }

    private struct CachedApplication: Codable {
        let id: String
        let name: String
        let energyWh: Double
        let activeSeconds: TimeInterval
        let peakPowerWatts: Double
    }

    private static let version = 1
    private static let retention: TimeInterval = 10 * 60
    private static let writeInterval: TimeInterval = 60

    private let fileURL: URL
    private let temporaryURL: URL
    private var generation = 0
    private var isEnabled = true
    private var lastWriteAt: Date?

    init(fileURL: URL? = nil) throws {
        let resolvedURL = try fileURL ?? Self.defaultFileURL()
        self.fileURL = resolvedURL
        self.temporaryURL = resolvedURL.appendingPathExtension("replacement")
        try FileManager.default.createDirectory(
            at: resolvedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func setEnabled(_ enabled: Bool, generation: Int) throws {
        guard generation >= self.generation else { return }
        self.generation = generation
        isEnabled = enabled
        if !enabled {
            try removeCacheFiles()
            lastWriteAt = nil
        }
    }

    func restore(generation requestedGeneration: Int, endingAt now: Date = Date()) -> [AppImpactSample] {
        guard isEnabled, requestedGeneration == generation else { return [] }
        guard let data = try? Data(contentsOf: fileURL),
              let cache = try? JSONDecoder().decode(CacheFile.self, from: data),
              cache.version == Self.version else {
            try? removeCacheFiles()
            return []
        }
        let cutoff = now.addingTimeInterval(-Self.retention)
        return cache.samples
            .filter { $0.timestamp >= cutoff && $0.timestamp <= now }
            .map(Self.restoredSample)
    }

    func persist(
        _ samples: [AppImpactSample],
        generation requestedGeneration: Int,
        force: Bool = false,
        now: Date = Date()
    ) throws {
        guard isEnabled, requestedGeneration == generation else { return }
        if !force,
           let lastWriteAt,
           now.timeIntervalSince(lastWriteAt) < Self.writeInterval {
            return
        }

        let cutoff = now.addingTimeInterval(-Self.retention)
        let cachedSamples = samples
            .filter { $0.timestamp >= cutoff && $0.timestamp <= now }
            .map(Self.cachedSample)
        let payload = CacheFile(version: Self.version, generatedAt: now, samples: cachedSamples)
        let data = try JSONEncoder().encode(payload)
        try writeAtomically(data)
        lastWriteAt = now
    }

    func clear(generation requestedGeneration: Int) throws {
        guard requestedGeneration >= generation else { return }
        generation = requestedGeneration
        try removeCacheFiles()
        lastWriteAt = nil
    }

    static func containsPrivateRuntimeFields(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8)?.lowercased() else { return true }
        return [
            "primarypid", "iconpath", "memorybytes", "pageinspersecond",
            "/users/", "/applications/", "process:",
        ]
            .contains { text.contains($0) }
    }

    private func writeAtomically(_ data: Data) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: temporaryURL)
        try data.write(to: temporaryURL, options: [])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = fileURL
        try mutableURL.setResourceValues(values)
    }

    private func removeCacheFiles() throws {
        let fileManager = FileManager.default
        for url in [fileURL, temporaryURL] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private static func cachedSample(_ sample: AppImpactSample) -> CachedSample {
        var applications: [CachedApplication] = sample.offenders.compactMap { offender in
            guard isPersistableBundleIdentifier(offender.groupID),
                  let energy = offender.estimatedEnergyWh,
                  energy.isFinite,
                  energy >= 0 else {
                return nil
            }
            return CachedApplication(
                id: offender.groupID,
                name: offender.name,
                energyWh: energy,
                activeSeconds: max(offender.sampleDurationSeconds ?? sample.durationSeconds, 0),
                peakPowerWatts: max(offender.estimatedPowerWatts ?? 0, 0)
            )
        }

        let representedEnergy = applications.reduce(0) { $0 + $1.energyWh }
        if let total = sample.totalComputeEnergyWh,
           total.isFinite,
           total > representedEnergy {
            let otherEnergy = total - representedEnergy
            applications.append(
                CachedApplication(
                    id: "other",
                    name: "Other",
                    energyWh: otherEnergy,
                    activeSeconds: max(sample.durationSeconds, 0),
                    peakPowerWatts: sample.durationSeconds > 0
                        ? otherEnergy * 3_600 / sample.durationSeconds
                        : 0
                )
            )
        }

        return CachedSample(
            timestamp: sample.timestamp,
            durationSeconds: max(sample.durationSeconds, 0),
            totalComputeEnergyWh: sample.totalComputeEnergyWh,
            applications: applications
        )
    }

    private static func isPersistableBundleIdentifier(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
            }
        }
    }

    private static func restoredSample(_ sample: CachedSample) -> AppImpactSample {
        let total = sample.totalComputeEnergyWh
        let offenders = sample.applications.map { application in
            let share = total.flatMap { value in
                value > 0 ? min(max(application.energyWh / value, 0), 1) : nil
            }
            return AppEnergyOffender(
                groupID: application.id,
                primaryPID: 0,
                name: application.name,
                iconPath: nil,
                processCount: 0,
                impactScore: share ?? 0,
                cpuPercent: 0,
                memoryBytes: 0,
                pageinsPerSecond: 0,
                activityShare: share,
                estimatedPowerWatts: application.peakPowerWatts,
                estimatedEnergyWh: application.energyWh,
                sampleDurationSeconds: application.activeSeconds
            )
        }
        return AppImpactSample(
            timestamp: sample.timestamp,
            offenders: offenders,
            durationSeconds: sample.durationSeconds,
            totalComputeEnergyWh: total
        )
    }

    private static func defaultFileURL() throws -> URL {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return caches
            .appendingPathComponent("Powerflow", isDirectory: true)
            .appendingPathComponent("app-impact-v1.json")
    }
}
