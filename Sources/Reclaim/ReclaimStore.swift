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

enum CleanupAction: Identifiable {
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
        case .images: "Remove the selected images from the local Docker engine. Only untagged images older than 24 hours with no running or stopped containers are eligible. Tagged images and images checked during an active build are protected. Docker will refuse images that are still needed; removal is never forced. You may need to download or rebuild them later.\n\nContainers and volumes are kept."
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
    let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
    var isBusy: Bool { busyMessage != nil }
    var snapshots: [Snapshot] { report?.snapshots ?? [] }
    var localEntries: [LocalEntry] { source == .xcode ? xcode?.entries ?? [] : browser?.entries ?? [] }
    var canAct: Bool { !isBusy && errors[source] == nil && !isDemo }
    var scheduleLabel: String {
        guard let schedule else { return "Schedule" }
        return schedule.configuration.enabled && schedule.loaded ? "Scheduled" : "Schedule"
    }

    func refresh() async {
        guard !isBusy else { return }
        busyMessage = "Reading storage…"
        await reload()
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
        await withTaskGroup(of: SourceResult.self) { group in
            group.addTask {
                do { return .snapshots(try await SnapshotService().load()) }
                catch { return .failure(.timeMachine, error.localizedDescription) }
            }
            group.addTask {
                do { return .local(.xcode, try await XcodeService().load()) }
                catch { return .failure(.xcode, error.localizedDescription) }
            }
            group.addTask {
                do { return .local(.browser, try await BrowserService().load()) }
                catch { return .failure(.browser, error.localizedDescription) }
            }
            group.addTask {
                do { return .docker(try await DockerService().load()) }
                catch { return .failure(.docker, error.localizedDescription) }
            }
            group.addTask {
                do { return .schedule(try await ScheduleManager().state()) }
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
            }
        }
    }

    func perform(_ action: CleanupAction) async {
        guard canAct else { return }
        busyMessage = "Cleaning…"
        errorMessage = nil
        resultMessage = nil
        let before = report?.storage?.freeBytes
        var output = ""
        do {
            let lock = try CleanupLock()
            defer { withExtendedLifetime(lock) {} }
            switch action {
            case let .snapshot(action): output = try await SnapshotService().perform(action)
            case let .xcode(ids): output = try await XcodeService().clean(ids: ids)
            case let .chrome(ids): output = try await BrowserService().clean(ids: ids)
            case let .images(ids): output = try await DockerService().removeImages(ids: ids)
            }
        } catch SnapshotError.cancelled {
            resultMessage = "Authorization cancelled."
        } catch {
            errorMessage = error.localizedDescription
            resultMessage = "Cleanup stopped. Review the refreshed list."
        }
        busyMessage = "Refreshing storage…"
        await reload()
        if resultMessage == nil {
            if let before, let after = report?.storage?.freeBytes {
                let difference = after - before
                resultMessage = difference > 0 ? "\(formatBytes(difference)) more free space." : "Cleanup finished."
            } else { resultMessage = "Cleanup finished; storage figures unavailable." }
        }
        resultDetails = output + "\n\nOther disk activity can affect the free-space change. Listed sizes can share blocks; host disk reclamation can be delayed. A failed batch may have completed partially."
        busyMessage = nil
    }

    func saveSchedule(_ config: ScheduleConfiguration, replaceLegacy: Bool) async -> Bool {
        guard !isBusy, !isDemo else { return false }
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
