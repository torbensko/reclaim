import Foundation
import Testing
@testable import Reclaim
@testable import ReclaimCore

private actor ModeFixture {
    var mode = BackupMode.automatic
    private(set) var writes = 0
    private(set) var scans = 0
    private(set) var measurements = 0
    func set(_ mode: BackupMode) { self.mode = mode; writes += 1 }
    func scan() -> SnapshotReport {
        scans += 1
        return SnapshotReport(snapshots: [], storage: nil)
    }
    func storage() -> StorageInfo {
        measurements += 1
        return StorageInfo(volumeName: "Fixture", totalBytes: 1_000_000_000_000,
                           freeBytes: measurements > 2 ? 180_000_000_000 : 5_000_000_000, availableBytes: 250_000_000_000)
    }
}

private func modeServices(_ fixture: ModeFixture) -> ReclaimServices {
    var services = ReclaimServices()
    services.backupMode = { await fixture.mode }
    services.setBackupMode = { await fixture.set($0) }
    services.storage = { await fixture.storage() }
    services.snapshots = { await fixture.scan() }
    services.xcode = { LocalReport(entries: [], notice: nil) }
    services.projects = { LocalReport(entries: [], notice: nil) }
    services.agents = { LocalReport(entries: [], notice: nil) }
    services.browser = { LocalReport(entries: [], notice: nil) }
    services.docker = { DockerReport(items: [], imageBytes: 0, cacheBytes: 0, reclaimableCacheBytes: 0, reclaimableImageBytes: 0) }
    services.schedule = { throw CleanupError.unavailable("No fixture schedule") }
    services.perform = { _ in throw CleanupError.unavailable("Unexpected cleanup") }
    services.pause = { _ in try Task.checkCancellation() }
    return services
}

private actor ModeGate {
    var opened = false
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        guard !opened else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { opened = true; continuation?.resume(); continuation = nil }
}

private func waitForGate(_ gate: ModeGate) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await gate.started) && ContinuousClock.now < deadline { await Task.yield() }
    return await gate.started
}

@Test @MainActor func backupModeIsReadOnRefreshAndExternalChangesAreReflected() async {
    let fixture = ModeFixture()
    let store = ReclaimStore(services: modeServices(fixture), storageDelays: [], isDemo: false)
    await store.refresh()
    #expect(store.backupMode == .automatic)
    #expect(await fixture.writes == 0)
    await fixture.set(.manual) // Simulate a change made in System Settings.
    await store.refreshBackupMode()
    #expect(store.backupMode == .manual)
    #expect(store.canChangeBackupMode)
}

@Test @MainActor func confirmedBackupModeChangeWaitsForReadbackAndRefreshesStorage() async {
    let fixture = ModeFixture()
    let gate = ModeGate()
    var services = modeServices(fixture)
    services.setBackupMode = { mode in await gate.wait(); await fixture.set(mode) }
    let store = ReclaimStore(services: services, storageDelays: [.zero], isDemo: false)
    await store.refreshBackupMode()
    let change = Task { await store.changeBackupMode(to: .manual) }
    #expect(await waitForGate(gate))
    #expect(store.backupMode == .automatic) // No optimistic switch movement.
    #expect(store.isBusy)
    #expect(!store.canChangeBackupMode)
    #expect(!store.canAct)
    await store.changeBackupMode(to: .manual) // Duplicate action is ignored.
    await gate.release()
    await change.value
    await store.storageMonitor?.value
    #expect(await fixture.writes == 1)
    #expect(store.backupMode == .manual)
    #expect(store.resultMessage?.hasPrefix("Manual backups are on.") == true)
    #expect(store.errorMessage == nil)
    #expect(await fixture.scans == 1)
    #expect(await fixture.measurements >= 3)
    #expect(store.storage?.freeBytes == 180_000_000_000)
    #expect(!store.isBusy)
}

@Test @MainActor func cancelledAndFailedModeChangesKeepActualStateAndRescan() async {
    for cancelled in [true, false] {
        let fixture = ModeFixture()
        var services = modeServices(fixture)
        services.setBackupMode = { _ in
            if cancelled { throw SnapshotError.cancelled }
            throw BackupSettingsError.notVerified
        }
        let store = ReclaimStore(services: services, storageDelays: [], isDemo: false)
        await store.refreshBackupMode()
        await store.changeBackupMode(to: .manual)
        await store.storageMonitor?.value
        #expect(store.backupMode == .automatic)
        #expect(store.resultMessage?.hasPrefix(cancelled ? "Backup setting change cancelled." : "Backup setting change could not be confirmed.") == true)
        #expect(cancelled ? store.errorMessage == nil : store.errorMessage != nil)
        #expect(await fixture.scans == 1)
        #expect(await fixture.writes == 0)
    }
}

@Test @MainActor func missingReadbackCannotClaimASettingWasChanged() async {
    let fixture = ModeFixture()
    var services = modeServices(fixture)
    services.backupMode = {
        if await fixture.writes > 0 { throw BackupSettingsError.unreadable }
        return .automatic
    }
    let store = ReclaimStore(services: services, storageDelays: [], isDemo: false)
    await store.refreshBackupMode()
    await store.changeBackupMode(to: .manual)
    await store.storageMonitor?.value
    #expect(store.backupMode == nil)
    #expect(store.backupModeError != nil)
    #expect(store.errorMessage != nil)
    #expect(store.resultMessage?.hasPrefix("Backup setting change could not be confirmed.") == true)
    #expect(!store.canChangeBackupMode)
}

@Test @MainActor func unknownModeAndDemoNeverChangeRealSettings() async {
    let fixture = ModeFixture()
    var services = modeServices(fixture)
    services.backupMode = { throw BackupSettingsError.unreadable }
    let unknown = ReclaimStore(services: services, storageDelays: [], isDemo: false)
    await unknown.refreshBackupMode()
    await unknown.changeBackupMode(to: .manual)
    #expect(unknown.backupMode == nil)
    #expect(!unknown.canChangeBackupMode)
    let demo = ReclaimStore(services: services, storageDelays: [], isDemo: true)
    await demo.refreshBackupMode()
    #expect(demo.backupMode == .automatic)
    await demo.changeBackupMode(to: .manual)
    #expect(!demo.canChangeBackupMode)
    #expect(await fixture.writes == 0)
}

@Test @MainActor func lateBackupModeReadCannotOverwriteANewerReading() async {
    let fixture = ModeFixture()
    let gate = ModeGate()
    var services = modeServices(fixture)
    services.backupMode = {
        if await fixture.mode == .automatic { await gate.wait(); return .automatic }
        return .manual
    }
    let store = ReclaimStore(services: services, storageDelays: [], isDemo: false)
    let oldRead = Task { await store.refreshBackupMode() }
    #expect(await waitForGate(gate))
    await fixture.set(.manual)
    await store.refreshBackupMode()
    await gate.release()
    await oldRead.value
    #expect(store.backupMode == .manual)
    #expect(!store.checkingBackupMode)
}
