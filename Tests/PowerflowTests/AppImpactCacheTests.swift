import Foundation
import XCTest
@testable import Powerflow

final class AppImpactCacheTests: XCTestCase {
    func testCachePersistsOnlyMinimalPrivateRestartData() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let cache = try AppImpactCache(fileURL: fixture.fileURL)
        let now = Date()
        try await cache.setEnabled(true, generation: 0)

        let sample = AppImpactSample(
            timestamp: now,
            offenders: [
                offender(
                    id: "com.example.editor",
                    name: "Editor",
                    iconPath: "/Users/private/Applications/Editor.app",
                    energyWh: 0.004
                ),
                offender(
                    id: "process:helper",
                    name: "Local Helper",
                    iconPath: "/Users/private/bin/helper",
                    energyWh: 0.002
                ),
            ],
            durationSeconds: 10,
            totalComputeEnergyWh: 0.01
        )

        try await cache.persist([sample], generation: 0, force: true, now: now)

        let data = try Data(contentsOf: fixture.fileURL)
        XCTAssertFalse(AppImpactCache.containsPrivateRuntimeFields(data))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("Local Helper"))
        XCTAssertFalse(text.contains("private"))
        XCTAssertFalse(text.contains("primaryPID"))
        XCTAssertTrue(text.contains("com.example.editor"))
        XCTAssertTrue(text.contains("Other"))

        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)

        let restored = await cache.restore(generation: 0, endingAt: now.addingTimeInterval(1))
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].offenders.map(\.name), ["Editor", "Other"])
        XCTAssertEqual(restored[0].totalComputeEnergyWh, 0.01)
    }

    func testDisableWinsOverStaleQueuedWrite() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let cache = try AppImpactCache(fileURL: fixture.fileURL)
        let now = Date()
        let sample = AppImpactSample(
            timestamp: now,
            offenders: [offender(id: "com.example.app", name: "App", iconPath: nil, energyWh: 0.002)],
            durationSeconds: 5,
            totalComputeEnergyWh: 0.002
        )

        try await cache.setEnabled(true, generation: 0)
        try await cache.persist([sample], generation: 0, force: true, now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path))

        try await cache.setEnabled(false, generation: 1)
        try await cache.setEnabled(true, generation: 0)
        try await cache.persist([sample], generation: 0, force: true, now: now.addingTimeInterval(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        let restored = await cache.restore(generation: 0, endingAt: now)
        XCTAssertTrue(restored.isEmpty)
    }

    private func makeFixture() -> (directory: URL, fileURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (directory, directory.appendingPathComponent("app-impact.json"))
    }

    private func offender(
        id: String,
        name: String,
        iconPath: String?,
        energyWh: Double
    ) -> AppEnergyOffender {
        AppEnergyOffender(
            groupID: id,
            primaryPID: 42,
            name: name,
            iconPath: iconPath,
            processCount: 2,
            impactScore: 10,
            cpuPercent: 8,
            memoryBytes: 512_000_000,
            pageinsPerSecond: 0.5,
            activityShare: 0.4,
            estimatedPowerWatts: energyWh * 360,
            estimatedEnergyWh: energyWh,
            sampleDurationSeconds: 10
        )
    }
}
