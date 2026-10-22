import SwiftUI
import ReclaimCore

enum Source: String, CaseIterable, Identifiable, Sendable {
    case overview = "Overview", timeMachine = "Time Machine", xcode = "Xcode", docker = "Docker", browser = "Browser"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "internaldrive"
        case .timeMachine: "clock.arrow.circlepath"
        case .xcode: "hammer"
        case .docker: "shippingbox"
        case .browser: "globe"
        }
    }
}

enum CleanupAction: Identifiable, Sendable {
    case snapshot(SnapshotAction), xcode([String]), chrome([String]), images([String])
    var id: String { title }
    var title: String {
        switch self {
        case let .snapshot(action): action.title
        case let .xcode(ids): "Clear build data for \(ids.count) project\(ids.count == 1 ? "" : "s")?"
        case let .chrome(ids): "Remove \(ids.count) Chrome signing \(ids.count == 1 ? "copy" : "copies")?"
        case let .images(ids): "Remove \(ids.count) Docker image\(ids.count == 1 ? "" : "s")?"
        }
    }
    var explanation: String {
        switch self {
        case let .snapshot(action): action.confirmation
        case .xcode: "Permanently remove Build and Index folders from the selected orphaned DerivedData projects, inactive for at least 7 days. Existing source folders and registered worktrees are protected. Xcode will recreate them on the next build, which may take longer. SourcePackages, archives, logs, simulators and your source files are kept.\n\nOwnership, file activity and running build tools are checked again before removal."
        case .chrome: "Permanently remove selected signing copies older than 24 hours from Chrome’s temporary signing folder. The installed Chrome app, profiles and browser caches are kept.\n\nEach copy is checked against executable paths, mapped files and open files. In-use or unverified copies are kept; other Chrome instances can remain open. APFS copies may share disk blocks, so the listed size is not a promise of space recovered."
        case .images: "Remove the selected unused images and all their local tags from the local Docker engine. Images must be older than 24 hours with no running or stopped container references and no reported active builder. Tags, image identity and usage are checked again before each removal; removal is never forced.\n\nLocally built images may need to be rebuilt, and downloaded images may need to be pulled again. Registry copies, containers, volumes, build cache and unselected parent images are kept. Shared layers mean the listed sizes are not a promise of SSD space recovered."
        }
    }
    var confirmLabel: String {
        if case let .snapshot(action) = self { return action.confirmLabel }
        return "Remove Data"
    }
}

private enum SourceResult: Sendable {
    case snapshots(SnapshotReport)
    case local(Source, LocalReport)
    case docker(DockerReport)
    case schedule(ScheduleState)
    case failure(Source?, String)
}

/// Injectable operations keep cleanup/refresh tests entirely off the user's data.
struct ReclaimServices: Sendable {
    var snapshots: @Sendable () async throws -> SnapshotReport = { try await SnapshotService().load() }
    var storage: @Sendable () async throws -> StorageInfo = { try await SnapshotService().storage() }
    var xcode: @Sendable () async throws -> LocalReport = { try await XcodeService().load() }
    var browser: @Sendable () async throws -> LocalReport = { try await BrowserService().load() }
    var docker: @Sendable () async throws -> DockerReport = { try await DockerService().load() }
    var schedule: @Sendable () async throws -> ScheduleState = { try await ScheduleManager().state() }
    var perform: @Sendable (CleanupAction) async throws -> String = { action in
        let lock = try CleanupLock()
        defer { withExtendedLifetime(lock) {} }
        switch action {
        case let .snapshot(action): return try await SnapshotService().perform(action)
        case let .xcode(ids): return try await XcodeService().clean(ids: ids)
        case let .chrome(ids): return try await BrowserService().clean(ids: ids)
        case let .images(ids): return try await DockerService().removeImages(ids: ids)
        }
    }
    var pause: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

@MainActor
final class ReclaimStore: ObservableObject {
    @Published var source = Source.overview
    @Published var report: SnapshotReport?
    @Published var xcode: LocalReport?
    @Published var browser: LocalReport?
    @Published var docker: DockerReport?
    @Published var schedule: ScheduleState?
    @Published var selection: Set<String> = []
    @Published var busyMessage: String?
    @Published var errors: [Source: String] = [:]
    @Published var loading: Set<Source> = []
    @Published var errorMessage: String?
    @Published var resultMessage: String?
    @Published var resultDetails = ""
    @Published var scheduleError: String?
    @Published private(set) var storage: StorageInfo?
    @Published private(set) var storageUpdatedAt: Date?
    @Published private(set) var storageError: String?
    @Published private(set) var checkingStorage = false
    @Published private(set) var monitoringStorage = false
    private(set) var storageMonitor: Task<Void, Never>?
    private var storageGeneration = UUID()
    private var beforeCleanup: Int64?
    private var cleanupOutcome: String?
    private let services: ReclaimServices
    private let storageDelays: [Duration]
    let isDemo: Bool

    init(services: ReclaimServices = ReclaimServices(),
         storageDelays: [Duration] = [.seconds(2), .seconds(3), .seconds(5), .seconds(10), .seconds(10), .seconds(15), .seconds(15)],
         isDemo: Bool = ProcessInfo.processInfo.arguments.contains("--demo")) {
        self.services = services
        self.storageDelays = storageDelays
        self.isDemo = isDemo
    }
    var isBusy: Bool { busyMessage != nil }
    var snapshots: [Snapshot] { report?.snapshots ?? [] }
    var localEntries: [LocalEntry] { source == .xcode ? xcode?.entries ?? [] : browser?.entries ?? [] }
    var canAct: Bool { !isBusy && errors[source] == nil && !isDemo }
    var actionBlockReason: String? {
        if isBusy { return "Please wait. \(busyMessage ?? "Updating storage…")" }
        if isDemo { return "Cleanup is unavailable in the preview." }
        return errors[source]
    }
    var storageStatus: String {
        if checkingStorage { return "Measuring free space…" }
        if monitoringStorage { return "Checking for delayed space release…" }
        if storageError != nil { return "Free-space check failed · refresh to retry" }
        return storageUpdatedAt.map { "Checked \($0.formatted(date: .omitted, time: .standard))" } ?? "Free space not yet checked"
    }
    var scheduleLabel: String {
        guard let schedule else { return "Schedule" }
        return schedule.configuration.enabled && schedule.loaded ? "Scheduled" : "Schedule"
    }

    func refresh() async {
        guard !isBusy else { return }
        stopStorageMonitoring()
        busyMessage = "Reading storage…"
        async let storageRead: Void = refreshStorage()
        await reload()
        await storageRead
        busyMessage = nil
    }

    private func reload() async {
        errors = [:]
        loading = Set(Source.allCases.filter { $0 != .overview })
        selection = []
        if isDemo {
            report = SnapshotReport(snapshots: [Snapshot(name: "com.apple.TimeMachine.2026-10-20-210000.local", purgeable: true)],
                                    storage: StorageInfo(volumeName: "Macintosh HD – Data", totalBytes: 1_000_000_000_000, freeBytes: 5_000_000_000, availableBytes: 125_000_000_000))
            loading = []
            return
        }
        let services = self.services
        updateScanMessage()
        await withTaskGroup(of: SourceResult.self) { group in
            group.addTask {
                do { return .snapshots(try await services.snapshots()) }
                catch { return .failure(.timeMachine, error.localizedDescription) }
            }
            group.addTask {
                do { return .local(.xcode, try await services.xcode()) }
                catch { return .failure(.xcode, error.localizedDescription) }
            }
            group.addTask {
                do { return .local(.browser, try await services.browser()) }
                catch { return .failure(.browser, error.localizedDescription) }
            }
            group.addTask {
                do { return .docker(try await services.docker()) }
                catch { return .failure(.docker, error.localizedDescription) }
            }
            group.addTask {
                do { return .schedule(try await services.schedule()) }
                catch { return .failure(nil, error.localizedDescription) }
            }
            for await result in group {
                switch result {
                case let .snapshots(value): report = value; loading.remove(.timeMachine)
                case let .local(source, value):
                    if source == .xcode { xcode = value } else { browser = value }
                    loading.remove(source)
                case let .docker(value): docker = value; loading.remove(.docker)
                case let .schedule(value): schedule = value; scheduleError = nil
                case let .failure(source, message):
                    if let source {
                        errors[source] = message
                        loading.remove(source)
                        switch source {
                        case .timeMachine: report = nil
                        case .xcode: xcode = nil
                        case .browser: browser = nil
                        case .docker: docker = nil
                        case .overview: break
                        }
                    } else { scheduleError = message }
                }
                updateScanMessage()
            }
        }
    }

    private func updateScanMessage() {
        let names = Source.allCases.filter { loading.contains($0) }.map(\.rawValue)
        busyMessage = names.isEmpty ? "Finishing storage checks…" : "Updating \(names.joined(separator: ", "))…"
    }

    private func refreshStorage() async {
        guard !checkingStorage else { return }
        let generation = storageGeneration
        checkingStorage = true
        do {
            let fresh = isDemo
                ? StorageInfo(volumeName: "Preview", totalBytes: 1_000_000_000_000, freeBytes: 5_000_000_000, availableBytes: 125_000_000_000)
                : try await services.storage()
            guard generation == storageGeneration, !Task.isCancelled else { return }
            storage = fresh
            storageUpdatedAt = .now
            storageError = nil
        } catch {
            guard generation == storageGeneration, !Task.isCancelled else { return }
            storage = nil
            storageUpdatedAt = nil
            storageError = error.localizedDescription
        }
        checkingStorage = false
        updateCleanupFeedback()
    }

    func stopStorageMonitoring() {
        storageMonitor?.cancel()
        storageMonitor = nil
        storageGeneration = UUID()
        monitoringStorage = false
        checkingStorage = false
    }

    private func monitorStorage() {
        let generation = storageGeneration
        monitoringStorage = true
        storageMonitor = Task { [weak self, services, storageDelays] in
            for delay in storageDelays {
                do { try await services.pause(delay) } catch { break }
                guard !Task.isCancelled, let self, generation == self.storageGeneration else { break }
                await self.refreshStorage()
            }
            guard let self, generation == self.storageGeneration else { return }
            self.monitoringStorage = false
        }
    }

    private func updateCleanupFeedback() {
        guard let cleanupOutcome else { return }
        var detail = ""
        if let current = storage?.freeBytes {
            if let beforeCleanup {
                let difference = current - beforeCleanup
                if difference > 0 { detail = " Free space is up \(formatBytes(difference)) (\(formatBytes(current)) now)." }
                else if difference < 0 { detail = " Free space is down \(formatBytes(-difference)) (\(formatBytes(current)) now)." }
                else { detail = " No increase in free space yet (\(formatBytes(current)) free)." }
            } else { detail = " \(formatBytes(current)) free now; the starting measurement was unavailable." }
        } else { detail = " Free-space measurement unavailable; refresh to retry." }
        resultMessage = cleanupOutcome + detail
    }

    func perform(_ action: CleanupAction) async {
        guard canAct else { return }
        stopStorageMonitoring()
        busyMessage = "Checking free space before cleanup…"
        cleanupOutcome = nil
        beforeCleanup = nil
        errorMessage = nil
        resultMessage = nil
        resultDetails = ""
        await refreshStorage()
        beforeCleanup = storage?.freeBytes
        busyMessage = "Cleaning…"
        if case .snapshot = action { busyMessage = "Waiting for authorization or Time Machine cleanup…" }
        var output = ""
        do {
            output = try await services.perform(action)
            cleanupOutcome = "Cleanup finished."
        } catch SnapshotError.cancelled {
            cleanupOutcome = "Authorization cancelled."
        } catch {
            errorMessage = error.localizedDescription
            cleanupOutcome = "Cleanup stopped; some items may already have been removed."
        }
        busyMessage = "Cleanup ended. Measuring free space…"
        resultMessage = "\(cleanupOutcome ?? "Cleanup ended.") Updating totals…"
        await refreshStorage()
        monitorStorage()
        // Slow ownership/file scans cannot hold back the independent free-space readings.
        await reload()
        await refreshStorage()
        resultDetails = output + "\n\n\(cleanupOutcome ?? "Cleanup ended.")\nOther disk activity can affect the observed free-space change; it is not a measurement of bytes recovered by this cleanup. Reclaim checks again over the next minute for delayed release. All source inventories are rescanned. Listed sizes can share blocks; host disk reclamation can be delayed. A failed batch may have completed partially."
        busyMessage = nil
    }

    func saveSchedule(_ config: ScheduleConfiguration, replaceLegacy: Bool) async -> Bool {
        guard !isBusy, !isDemo else { return false }
        stopStorageMonitoring()
        cleanupOutcome = nil
        busyMessage = "Updating schedule…"
        scheduleError = nil
        defer { busyMessage = nil }
        do {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ReclaimWorker")
            try await ScheduleManager().save(config, bundledWorker: helper, replaceLegacy: replaceLegacy)
            schedule = try await ScheduleManager().state()
            resultMessage = config.enabled ? "Cleanup schedule saved." : "Scheduled cleanup is off."
            resultDetails = "Scheduled jobs run in your login session, including while Reclaim is closed. No cleanup runs when you save the schedule."
            return true
        } catch {
            scheduleError = error.localizedDescription
            schedule = try? await ScheduleManager().state()
            return false
        }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    bytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
}
