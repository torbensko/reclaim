import SwiftUI
import ReclaimCore

enum Source: String, CaseIterable, Identifiable, Sendable {
    case overview = "Overview", projects = "Projects", xcode = "Xcode", docker = "Docker", agents = "AI tools", browser = "Browser", timeMachine = "Time Machine"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "internaldrive"
        case .projects: "folder.badge.gearshape"
        case .agents: "text.bubble"
        case .timeMachine: "clock.arrow.circlepath"
        case .xcode: "hammer"
        case .docker: "shippingbox"
        case .browser: "globe"
        }
    }
}

enum CleanupAction: Identifiable, Sendable {
    case snapshot(SnapshotAction), xcode([String]), chrome([String]), images([String]), projects([String]), agentLogs([String])
    case batch(actions: [CleanupAction], items: [String])
    var id: String { title }
    var title: String {
        switch self {
        case let .snapshot(action): action.title
        case let .xcode(ids): "Clear build data for \(ids.count) project\(ids.count == 1 ? "" : "s")?"
        case let .chrome(ids): "Remove \(ids.count) Chrome signing \(ids.count == 1 ? "copy" : "copies")?"
        case let .images(ids): "Remove \(ids.count) Docker image\(ids.count == 1 ? "" : "s")?"
        case let .projects(ids): "Remove \(ids.count) generated folder\(ids.count == 1 ? "" : "s")?"
        case let .agentLogs(ids): "Remove \(ids.count) old diagnostic logs?"
        case let .batch(_, items): "Review \(items.count) cleanup item\(items.count == 1 ? "" : "s")"
        }
    }
    var explanation: String {
        switch self {
        case let .snapshot(action): action.confirmation
        case .xcode: "Permanently remove only Build and Index folders from the selected DerivedData projects, unchanged for at least 7 days. Existing projects can be selected: Xcode recreates this output on the next build, which may take longer. SourcePackages, archives, logs, simulators, worktrees and source files stay.\n\nProject identity, age, source/output usage and running build tools are checked again before removal. Modification times are evidence, not a complete usage history."
        case .chrome: "Permanently remove selected signing copies older than 24 hours from Chrome’s temporary signing folder. The installed Chrome app, profiles and browser caches are kept.\n\nEach copy is checked against executable paths, mapped files and open files. In-use or unverified copies are kept; other Chrome instances can remain open. APFS copies may share disk blocks, so the listed size is not a promise of space recovered."
        case .images: "Remove the selected unused images and all their local tags from the local Docker engine. Images must be older than 24 hours with no running or stopped container references and no reported active builder. Tags, image identity and usage are checked again before each removal; removal is never forced.\n\nLocally built images may need to be rebuilt, and downloaded images may need to be pulled again. Registry copies, containers, volumes, build cache and unselected parent images are kept. Shared layers mean the listed sizes are not a promise of SSD space recovered."
        case .projects: "Remove only the listed generated folders, unchanged for at least 7 days. Source files, worktrees, Git data and Swift dependency checkouts stay. Swift/Next.js builds may take longer afterward.\n\nSelected node_modules folders require reinstalling dependencies from the lockfile, potentially using downloads, registry credentials and install scripts. Local edits inside dependencies will be lost; those items are marked Review first.\n\nPath identity, Git-tracked files, age and current project usage are checked again. An in-use, changed or unverifiable item stops the batch."
        case .agentLogs: "Remove only the listed Codex/Claude diagnostic logs unchanged for at least 30 days, after checking for current users. Past troubleshooting evidence is lost; new logs can be created. Conversation history, sessions, settings, credentials and worktrees stay."
        case let .batch(actions, items):
            "Only these selected items will be considered. Protected items are excluded. Checks run again before removal; the batch can stop after partial completion.\n\n" + items.joined(separator: "\n\n") + "\n\n" + actions.map(\.explanation).joined(separator: "\n\n")
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
    var xcode: @Sendable () async throws -> LocalReport = { try await XcodeService(policy: .manual).load() }
    var projects: @Sendable () async throws -> LocalReport = { try await ProjectArtifactsService().load() }
    var agents: @Sendable () async throws -> LocalReport = { try await AgentDataService().load() }
    var browser: @Sendable () async throws -> LocalReport = { try await BrowserService().load() }
    var docker: @Sendable () async throws -> DockerReport = { try await DockerService().load() }
    var schedule: @Sendable () async throws -> ScheduleState = { try await ScheduleManager().state() }
    var backupMode: @Sendable () async throws -> BackupMode = { try await BackupSettingsService().readMode() }
    var setBackupMode: @Sendable (BackupMode) async throws -> Void = {
        let lock = try CleanupLock()
        defer { withExtendedLifetime(lock) {} }
        try await BackupSettingsService().setMode($0)
    }
    var perform: @Sendable (CleanupAction) async throws -> String = { action in
        let lock = try CleanupLock()
        defer { withExtendedLifetime(lock) {} }
        return try await CleanupExecutor.perform(action)
    }
    var pause: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

enum CleanupExecutor {
    struct BatchFailure: LocalizedError {
        let completed: [String]
        let reason: String
        var errorDescription: String? {
            (completed.isEmpty ? "No source batch completed." : "Completed before stopping:\n" + completed.joined(separator: "\n"))
            + "\n\nStopped: " + reason + "\nThe interrupted source may have completed partially. All sources will be rescanned."
        }
    }
    static func runBatch(_ actions: [CleanupAction], run: (CleanupAction) async throws -> String) async throws -> String {
        var outcomes: [String] = []
        for action in actions {
            do { outcomes.append(try await run(action)) }
            catch SnapshotError.cancelled { throw BatchFailure(completed: outcomes, reason: "Authorization cancelled.") }
            catch {
                throw BatchFailure(completed: outcomes, reason: error.localizedDescription)
            }
        }
        return outcomes.joined(separator: "\n")
    }
    /// The caller holds one cleanup lock for the entire cross-source operation.
    static func perform(_ action: CleanupAction) async throws -> String {
        switch action {
        case let .snapshot(action): return try await SnapshotService().perform(action)
        case let .xcode(ids): return try await XcodeService(policy: .manual).clean(ids: ids)
        case let .chrome(ids): return try await BrowserService().clean(ids: ids)
        case let .images(ids): return try await DockerService().removeImages(ids: ids)
        case let .projects(ids): return try await ProjectArtifactsService().clean(ids: ids)
        case let .agentLogs(ids): return try await AgentDataService().clean(ids: ids)
        case let .batch(actions, _):
            return try await runBatch(actions, run: perform)
        }
    }
}

@MainActor
final class ReclaimStore: ObservableObject {
    @Published var source = Source.overview
    @Published var report: SnapshotReport?
    @Published var xcode: LocalReport?
    @Published var projects: LocalReport?
    @Published var agents: LocalReport?
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
    @Published private(set) var backupMode: BackupMode?
    @Published private(set) var backupModeError: String?
    @Published private(set) var checkingBackupMode = false
    @Published private(set) var changingBackupMode = false
    private var backupModeGeneration = UUID()
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
    func localReport(for source: Source) -> LocalReport? {
        switch source {
        case .xcode: xcode
        case .projects: projects
        case .agents: agents
        case .browser: browser
        default: nil
        }
    }
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
        async let backupRead: Void = refreshBackupMode()
        await reload()
        await storageRead
        await backupRead
        busyMessage = nil
    }

    func refreshBackupMode() async {
        guard !changingBackupMode else { return }
        await readBackupMode()
    }

    private func readBackupMode() async {
        let generation = UUID()
        backupModeGeneration = generation
        checkingBackupMode = true
        defer { if backupModeGeneration == generation { checkingBackupMode = false } }
        do {
            let mode = isDemo ? BackupMode.automatic : try await services.backupMode()
            guard backupModeGeneration == generation, !Task.isCancelled else { return }
            backupMode = mode
            backupModeError = nil
        } catch {
            guard backupModeGeneration == generation, !Task.isCancelled else { return }
            backupMode = nil
            backupModeError = error.localizedDescription
        }
    }

    var canChangeBackupMode: Bool {
        !isBusy && !isDemo && !checkingBackupMode && backupMode != nil
    }

    /// Called only after the user confirms the system-wide setting change.
    func changeBackupMode(to mode: BackupMode) async {
        guard canChangeBackupMode, backupMode != mode else { return }
        stopStorageMonitoring()
        changingBackupMode = true
        backupModeGeneration = UUID()
        busyMessage = "Checking free space before changing backup mode…"
        cleanupOutcome = nil
        beforeCleanup = nil
        errorMessage = nil
        resultMessage = nil
        resultDetails = ""
        await refreshStorage()
        beforeCleanup = storage?.freeBytes
        busyMessage = "Waiting for authorization to change macOS backup mode…"
        var changed = false
        do {
            try await services.setBackupMode(mode)
            changed = true
            cleanupOutcome = "macOS backup mode updated."
        } catch SnapshotError.cancelled {
            cleanupOutcome = "Backup setting change cancelled."
        } catch {
            errorMessage = error.localizedDescription
            cleanupOutcome = "Backup setting change could not be confirmed."
        }
        // Never move the switch optimistically. Read back even after cancellation
        // or failure, including when the setting was changed outside Reclaim.
        await readBackupMode()
        if changed {
            if backupMode == mode {
                cleanupOutcome = mode == .manual ? "Manual backups are on." : "Automatic backups are on."
            } else {
                errorMessage = backupModeError ?? BackupSettingsError.notVerified.localizedDescription
                cleanupOutcome = "Backup setting change could not be confirmed."
            }
        }
        changingBackupMode = false
        busyMessage = "Checking storage after backup setting change…"
        await refreshStorage()
        monitorStorage()
        await reload()
        await refreshStorage()
        resultDetails = "This is macOS’s Time Machine setting, not a Reclaim schedule. Check it in System Settings → General → Time Machine → Options → Backup Frequency.\n\nManual mode turns off automatic backups. Connect your backup disk and choose Back Up Now to make a backup; connecting the disk alone does not start one. macOS may remove existing local restore points after switching to manual mode. Space release can take several minutes; macOS update snapshots can still exist.\n\nReclaim rescanned the sources and checks free space for about a minute. Other disk activity can affect the observed change. If macOS refuses the shortcut, change Backup Frequency directly in System Settings; tmutil requires administrator authorization and Full Disk Access."
        busyMessage = nil
    }

    private func reload() async {
        errors = [:]
        loading = Set(Source.allCases.filter { $0 != .overview })
        selection = []
        if isDemo {
            report = SnapshotReport(snapshots: [Snapshot(name: "com.apple.TimeMachine.2026-10-20-210000.local", purgeable: true)],
                                    storage: StorageInfo(volumeName: "Macintosh HD – Data", totalBytes: 1_000_000_000_000, freeBytes: 5_000_000_000, availableBytes: 125_000_000_000))
            projects = LocalReport(entries: [
                LocalEntry(id: "sample-build", name: "Sample app · Swift build output", path: "/Sample/App/.build/out", bytes: 2_500_000_000,
                           modified: .now.addingTimeInterval(-18 * 86400), kind: .swiftBuild, eligibility: .candidate,
                           ownerPath: "/Sample/App", privateBytes: 1_800_000_000, evidence: "Sample data. Generated output unchanged for 18 days; no current project users detected. Swift rebuilds it. Source and dependency checkouts stay."),
                LocalEntry(id: "sample-dependencies", name: "Sample website · Node dependencies", path: "/Sample/Website/node_modules", bytes: 1_100_000_000,
                           modified: .now.addingTimeInterval(-12 * 86400), kind: .nodeDependencies,
                           eligibility: .review("Reinstall from the lockfile. Downloads and registry credentials may be needed; local edits inside dependencies are lost."),
                           ownerPath: "/Sample/Website", privateBytes: 800_000_000, evidence: "Sample data. Package manifest and lockfile verified; unchanged for 12 days; no current users detected."),
                LocalEntry(id: "sample-active", name: "Sample active app · Swift build output", path: "/Sample/Active/.build/out", bytes: 600_000_000,
                           modified: .now, kind: .swiftBuild, eligibility: .protected("In use · PID 123"), privateBytes: 400_000_000)
            ], notice: "Preview data; cleanup is disabled.")
            agents = LocalReport(entries: [LocalEntry(id: "sample-history", name: "Codex conversations", path: "/Sample/.codex/sessions",
                bytes: 250_000_000, modified: .now, kind: .agentHistory, eligibility: .protected("Unique conversation history · cannot be rebuilt"),
                privateBytes: 200_000_000, evidence: "Sample data. Conversation records stay; their age does not make them rebuildable.")], notice: "Preview data; cleanup is disabled.")
            xcode = LocalReport(entries: [], notice: nil)
            browser = LocalReport(entries: [], notice: nil)
            docker = DockerReport(items: [], imageBytes: 0, cacheBytes: 0, reclaimableCacheBytes: 0, reclaimableImageBytes: 0)
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
                do { return .local(.projects, try await services.projects()) }
                catch { return .failure(.projects, error.localizedDescription) }
            }
            group.addTask {
                do { return .local(.agents, try await services.agents()) }
                catch { return .failure(.agents, error.localizedDescription) }
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
                    switch source {
                    case .xcode: xcode = value
                    case .projects: projects = value
                    case .agents: agents = value
                    default: browser = value
                    }
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
                        case .projects: projects = nil
                        case .agents: agents = nil
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
