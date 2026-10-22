import Foundation
import Testing
@testable import Reclaim
@testable import ReclaimCore

private func space(_ gigabytes: Int64) -> StorageInfo {
    StorageInfo(volumeName: "Fixture SSD", totalBytes: 1_000_000_000_000,
                freeBytes: gigabytes * 1_000_000_000, availableBytes: 250_000_000_000)
}

private actor Readings {
    let values: [Int64?]
    private(set) var count = 0
    init(_ values: [Int64?]) { self.values = values }
    func read() throws -> StorageInfo {
        let value = values[min(count, values.count - 1)]
        count += 1
        guard let value else { throw CleanupError.unavailable("Fixture measurement failed") }
        return space(value)
    }
}

private actor Gate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        open = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

private func fixtures(read: @escaping @Sendable () async throws -> StorageInfo) -> ReclaimServices {
    var services = ReclaimServices()
    services.storage = read
    // Deliberately stale report storage must never overwrite fresh independent readings.
    services.snapshots = { SnapshotReport(snapshots: [], storage: space(1)) }
    services.xcode = { LocalReport(entries: [], notice: nil) }
    services.browser = { LocalReport(entries: [], notice: nil) }
    services.docker = { DockerReport(items: [], imageBytes: 0, cacheBytes: 0, reclaimableCacheBytes: 0, reclaimableImageBytes: 0) }
    services.schedule = { throw CleanupError.unavailable("No fixture schedule") }
    services.perform = { _ in "Mock cleanup complete" }
    services.pause = { _ in try Task.checkCancellation() }
    return services
}

@MainActor private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    return condition()
}

@Test @MainActor func delayedSpaceReleaseUpdatesWhileOtherSourcesAreStillScanning() async {
    let readings = Readings([5, 5, 180])
    let scan = Gate()
    var services = fixtures { try await readings.read() }
    services.browser = { await scan.wait(); return LocalReport(entries: [], notice: nil) }
    let store = ReclaimStore(services: services, storageDelays: [.zero, .zero], isDemo: false)
    store.source = .timeMachine
    let cleanup = Task { await store.perform(.snapshot(.reclaim(gigabytes: 100, urgency: 1))) }
    #expect(await eventually { store.storage?.freeBytes == 180_000_000_000 && store.loading == [.browser] })
    #expect(store.busyMessage == "Updating Browser…")
    #expect(!store.canAct)
    #expect(store.resultMessage?.contains("175 GB") == true)
    #expect(store.storageUpdatedAt != nil)
    await scan.release()
    await cleanup.value
    await store.storageMonitor?.value
    #expect(store.canAct)
    #expect(store.loading.isEmpty)
    #expect(!store.monitoringStorage)
    #expect(store.storage?.freeBytes == 180_000_000_000)
    #expect(await readings.count >= 4)
    #expect(store.resultDetails.contains("not a measurement of bytes recovered"))
}

@Test @MainActor func cancelledAndFailedCleanupsStillRefreshWithoutReportingSuccess() async {
    for cancelled in [true, false] {
        let readings = Readings([5, 6])
        var services = fixtures { try await readings.read() }
        services.perform = { _ in
            if cancelled { throw SnapshotError.cancelled }
            throw CleanupError.unavailable("Fixture partial failure")
        }
        let store = ReclaimStore(services: services, storageDelays: [.zero], isDemo: false)
        await store.perform(.chrome(["fixture-copy"]))
        await store.storageMonitor?.value
        #expect(store.storage?.freeBytes == 6_000_000_000)
        #expect(store.resultMessage?.hasPrefix(cancelled ? "Authorization cancelled." : "Cleanup stopped;") == true)
        #expect(store.resultMessage?.contains("Cleanup finished") == false)
        #expect(cancelled ? store.errorMessage == nil : store.errorMessage != nil)
        #expect(!store.isBusy)
        #expect(await readings.count >= 3)
    }
}

@Test @MainActor func failedMeasurementsStayUnknownInsteadOfReusingOldOrZeroSpace() async {
    let readings = Readings([nil])
    let store = ReclaimStore(services: fixtures { try await readings.read() }, storageDelays: [.zero], isDemo: false)
    await store.perform(.images(["fixture-id"]))
    await store.storageMonitor?.value
    #expect(store.storage == nil)
    #expect(store.storageUpdatedAt == nil)
    #expect(store.storageError != nil)
    #expect(store.resultMessage?.contains("measurement unavailable") == true)
    #expect(store.resultMessage?.contains("0 B") == false)
    #expect(store.report?.storage?.freeBytes == 1_000_000_000)
}

private actor DelayedReader {
    private(set) var count = 0
    let gate = Gate()
    func read() async -> StorageInfo {
        count += 1
        if count == 3 { await gate.wait(); return space(99) }
        return space(count > 3 ? 250 : 5)
    }
}

@Test @MainActor func manualRefreshCancelsPollingAndIgnoresAnOlderInFlightResult() async {
    let reader = DelayedReader()
    let scan = Gate()
    var services = fixtures { await reader.read() }
    services.browser = { await scan.wait(); return LocalReport(entries: [], notice: nil) }
    let store = ReclaimStore(services: services, storageDelays: [.zero], isDemo: false)
    let cleanup = Task { await store.perform(.xcode(["fixture-project"])) }
    #expect(await eventually { store.monitoringStorage && store.checkingStorage && store.loading.contains(.browser) })
    await scan.release()
    await cleanup.value
    let previousMonitor = store.storageMonitor
    await store.refresh()
    #expect(store.storage?.freeBytes == 250_000_000_000)
    await reader.gate.release()
    await previousMonitor?.value
    #expect(store.storage?.freeBytes == 250_000_000_000)
    #expect(!store.monitoringStorage)
    #expect(!store.checkingStorage)
}
