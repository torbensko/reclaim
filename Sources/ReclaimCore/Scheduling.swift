import Foundation
import Darwin

public struct ScheduleConfiguration: Codable, Equatable, Sendable {
    public var version = 1
    public var enabled = false
    public var intervalHours = 1
    public var chrome = true
    public var xcode = false
    public var docker = false
    public init() {}

    public func validate() throws {
        guard version == 1, [1, 6, 24].contains(intervalHours), !enabled || chrome || xcode || docker else {
            throw CleanupError.unavailable("Choose at least one cleanup rule and a supported interval.")
        }
    }
}

public struct ScheduledRun: Codable, Sendable {
    public let date: Date
    public let outcomes: [String]
    public let freeBefore: Int64?
    public let freeAfter: Int64?
}

public struct ScheduleState: Sendable {
    public let configuration: ScheduleConfiguration
    public let loaded: Bool
    public let legacyPresent: Bool
    public let legacyLoaded: Bool
    public let lastRun: ScheduledRun?
}

/// Shared by manual cleanup and the worker. A second process cannot start a purge.
public final class CleanupLock: @unchecked Sendable {
    private let descriptor: Int32
    public init(directory: URL = ScheduleManager.defaultDirectory) throws {
        try ScheduleManager.prepareDirectory(directory)
        descriptor = open(directory.appendingPathComponent("cleanup.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CleanupError.unavailable("Unable to open the cleanup lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw CleanupError.unavailable("Another Reclaim cleanup is running. Try again when it finishes.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

public struct ScheduleManager: Sendable {
    public static let label = "local.reclaim.cleanup"
    public static let legacyLabel = "com.torben.chrome-clone-cleanup"
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Reclaim")
    }
    public let directory: URL
    public let agentsDirectory: URL
    public let userID: UInt32
    private let runner: any CommandRunning
    public var configurationURL: URL { directory.appendingPathComponent("schedule.json") }
    public var lastRunURL: URL { directory.appendingPathComponent("last-run.json") }
    public var agentURL: URL { agentsDirectory.appendingPathComponent(Self.label + ".plist") }
    public var legacyURL: URL { agentsDirectory.appendingPathComponent(Self.legacyLabel + ".plist") }
    public var workerURL: URL { directory.appendingPathComponent("ReclaimWorker") }
    private var domain: String { "gui/\(userID)" }

    public init(directory: URL = Self.defaultDirectory, agentsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"),
                userID: UInt32 = getuid(), runner: any CommandRunning = ProcessRunner()) {
        self.directory = directory
        self.agentsDirectory = agentsDirectory
        self.userID = userID
        self.runner = runner
    }

    public static func prepareDirectory(_ url: URL) throws {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw CleanupError.unsafePath }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try LocalFiles.validate(url, within: url)
    }

    private func readOptional(_ url: URL) throws -> Data? {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw CleanupError.unsafePath }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func configuration() throws -> ScheduleConfiguration {
        guard let data = try readOptional(configurationURL) else { return ScheduleConfiguration() }
        let configuration = try JSONDecoder().decode(ScheduleConfiguration.self, from: data)
        try configuration.validate()
        return configuration
    }

    private func loaded(_ label: String) async throws -> Bool {
        let result = try await runner.run(Command(executable: "/bin/launchctl", arguments: ["print", domain + "/" + label]))
        if result.exitCode == 0 { return true }
        guard result.exitCode == 113 else { throw CleanupError.unavailable("Could not read the background job status: \(result.text)") }
        return false
    }

    public func state() async throws -> ScheduleState {
        let config = try configuration()
        async let ownLoaded = loaded(Self.label)
        async let legacyLoaded = loaded(Self.legacyLabel)
        let lastRun = try readOptional(lastRunURL).map { try JSONDecoder().decode(ScheduledRun.self, from: $0) }
        return try await ScheduleState(configuration: config, loaded: ownLoaded, legacyPresent: readOptional(legacyURL) != nil,
                                       legacyLoaded: legacyLoaded, lastRun: lastRun)
    }

    public func agentData(for configuration: ScheduleConfiguration) throws -> Data {
        try configuration.validate()
        return try PropertyListSerialization.data(fromPropertyList: [
            "Label": Self.label,
            "ProgramArguments": [workerURL.path, "--scheduled"],
            "StartInterval": configuration.intervalHours * 3600,
            "RunAtLoad": false,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
            "AssociatedBundleIdentifiers": ["local.timemachinexray.app"]
        ], format: .xml, options: 0)
    }

    public static func recognizedLegacy(_ data: Data, cloneRoot: String) throws -> Bool {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              var arguments = plist["ProgramArguments"] as? [String], arguments.count == 13 else { return false }
        // Foundation normalizes the system's /private/var alias to /var.
        arguments[1] = URL(fileURLWithPath: arguments[1]).standardizedFileURL.path
        return plist["Label"] as? String == legacyLabel && plist["StartInterval"] as? Int == 3600 &&
            arguments == ["/usr/bin/find", URL(fileURLWithPath: cloneRoot).standardizedFileURL.path, "-mindepth", "1", "-maxdepth", "1", "-mmin", "+720", "-exec", "rm", "-rf", "{}", "+"]
    }

    private func launchctl(_ arguments: [String]) async throws {
        _ = try await runner.run(Command(executable: "/bin/launchctl", arguments: arguments)).checked()
    }

    private func write(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw CleanupError.unsafePath }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    public func save(_ desired: ScheduleConfiguration, bundledWorker: URL, replaceLegacy: Bool) async throws {
        try desired.validate()
        guard !desired.enabled || desired.chrome || desired.xcode else {
            throw CleanupError.unavailable("Choose Chrome or orphaned Xcode data. Docker build cache is protected and cannot be scheduled.")
        }
        let lock = try CleanupLock(directory: directory)
        defer { withExtendedLifetime(lock) {} }
        try Self.prepareDirectory(agentsDirectory)
        let previous = try await state()
        if !desired.enabled {
            // Disable the worker before unloading, including if launchctl subsequently fails.
            try write(JSONEncoder().encode(desired), to: configurationURL)
            if previous.loaded { try await launchctl(["bootout", domain + "/" + Self.label]) }
            if FileManager.default.fileExists(atPath: agentURL.path) { try FileManager.default.removeItem(at: agentURL) }
            return
        }
        let legacyData = try readOptional(legacyURL)
        let needsTakeover = desired.chrome && (previous.legacyPresent || previous.legacyLoaded)
        if needsTakeover {
            guard replaceLegacy, let legacyData,
                  try Self.recognizedLegacy(legacyData, cloneRoot: BrowserService().cloneRoot.path) else {
                throw CleanupError.unavailable("An existing Chrome job is present. Review and replace that job before scheduling Chrome cleanup in Reclaim.")
            }
            if previous.legacyLoaded {
                let status = try await runner.run(Command(executable: "/bin/launchctl", arguments: ["print", domain + "/" + Self.legacyLabel])).checked()
                guard !status.text.contains("state = running"), !status.text.contains("\tpid = ") else {
                    throw CleanupError.unavailable("The existing Chrome cleanup is running. Let it finish before replacing its schedule.")
                }
            }
        }
        guard FileManager.default.isExecutableFile(atPath: bundledWorker.path) else {
            throw CleanupError.unavailable("The Reclaim background helper is missing. Rebuild or reinstall the app.")
        }
        let newWorker = try Data(contentsOf: bundledWorker)
        let savedFiles = try [configurationURL, agentURL, workerURL].map { ($0, try readOptional($0)) }
        var ownStopped = false
        var legacyStopped = false
        var newLoaded = false
        var legacyRemoved = false
        do {
            if previous.loaded { try await launchctl(["bootout", domain + "/" + Self.label]); ownStopped = true }
            if needsTakeover {
                // Backup first; never overwrite the user's earlier backup.
                let backup = directory.appendingPathComponent("\(Self.legacyLabel).\(UUID().uuidString).plist.backup")
                try write(legacyData!, to: backup)
                if previous.legacyLoaded { try await launchctl(["bootout", domain + "/" + Self.legacyLabel]); legacyStopped = true }
                try FileManager.default.removeItem(at: legacyURL)
                legacyRemoved = true
            }
            var staged = desired
            staged.enabled = false
            try write(JSONEncoder().encode(staged), to: configurationURL)
            try write(newWorker, to: workerURL, permissions: 0o755)
            try write(agentData(for: desired), to: agentURL, permissions: 0o644)
            try await launchctl(["bootstrap", domain, agentURL.path])
            newLoaded = true
            guard try await loaded(Self.label) else { throw CleanupError.unavailable("The cleanup job did not register.") }
            try write(JSONEncoder().encode(desired), to: configurationURL)
        } catch {
            let original = error.localizedDescription
            var recovery: [String] = []
            if newLoaded {
                do { try await launchctl(["bootout", domain + "/" + Self.label]) }
                catch { recovery.append(error.localizedDescription) }
            }
            for (url, data) in savedFiles {
                do {
                    if let data { try write(data, to: url, permissions: url == workerURL ? 0o755 : 0o600) }
                    else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                } catch { recovery.append(error.localizedDescription) }
            }
            if legacyRemoved, let legacyData {
                do { try write(legacyData, to: legacyURL, permissions: 0o644) }
                catch { recovery.append(error.localizedDescription) }
            }
            if legacyStopped {
                do { try await launchctl(["bootstrap", domain, legacyURL.path]) }
                catch { recovery.append(error.localizedDescription) }
            }
            if ownStopped {
                do { try await launchctl(["bootstrap", domain, agentURL.path]) }
                catch { recovery.append(error.localizedDescription) }
            }
            throw CleanupError.unavailable(original + (recovery.isEmpty ? " Previous settings were restored." : " Recovery needs attention: " + recovery.joined(separator: "\n")))
        }
    }
}

public struct ScheduledCleanup: Sendable {
    public init() {}
    public func run(manager: ScheduleManager = ScheduleManager()) async throws {
        let lock = try CleanupLock(directory: manager.directory)
        defer { withExtendedLifetime(lock) {} }
        let config = try manager.configuration()
        guard config.enabled else { return }
        let before = await freeBytes()
        var outcomes: [String] = []
        if config.chrome {
            do {
                let service = BrowserService()
                let report = try await service.load(includeCaches: false)
                let ids = report.entries.filter { $0.kind == .chromeClone && $0.eligible }.map(\.id)
                outcomes.append(ids.isEmpty ? "Chrome: no verified unused copies older than 24 hours. Protected or unverified copies were kept." : "Chrome: " + (try await service.clean(ids: ids)))
            } catch { outcomes.append("Chrome skipped or incomplete: \(error.localizedDescription)") }
        }
        if config.xcode {
            do {
                let service = XcodeService()
                let cutoff = Date.now.addingTimeInterval(-7 * 86400)
                let ids = try await service.load().entries.filter { $0.eligible && $0.modified < cutoff }.map(\.id)
                outcomes.append(ids.isEmpty ? "Xcode: no verified orphaned build data. Existing repositories/worktrees and unverified items were kept." : "Xcode: " + (try await service.clean(ids: ids, inactiveBefore: cutoff)))
            } catch { outcomes.append("Xcode skipped or incomplete: \(error.localizedDescription)") }
        }
        if config.docker {
            outcomes.append("Docker: build cache kept; active-project ownership cannot be verified. No prune was run.")
        }
        let result = ScheduledRun(date: .now, outcomes: outcomes, freeBefore: before, freeAfter: await freeBytes())
        try JSONEncoder().encode(result).write(to: manager.lastRunURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manager.lastRunURL.path)
    }
    private func freeBytes() async -> Int64? {
        guard let response = try? await ProcessRunner().run(SnapshotCommands.storage).checked(),
              (try? StorageInfo.validateLocalVolume(response.output)) != nil else { return nil }
        return try? StorageInfo.parse(response.output).freeBytes
    }
}
