import Foundation
import Darwin

/// A deliberately small vocabulary of generated paths, anchored in Git's inventory.
/// Never execute package scripts or treat all ignored/untracked files as disposable.
public struct ProjectArtifactsService: Sendable {
    public static let minimumAge: TimeInterval = 7 * 86400
    private let repositories: any RepositoriesInspecting
    private let usage: any UsageInspecting
    private let runner: any CommandRunning

    public init(repositories: (any RepositoriesInspecting)? = nil,
                usage: (any UsageInspecting)? = nil, runner: any CommandRunning = ProcessRunner()) {
        self.repositories = repositories ?? RepositoryInspector(runner: runner)
        self.usage = usage ?? UsageInspector(runner: runner)
        self.runner = runner
    }

    private struct Target: Sendable {
        let repository: URL
        let relative: String
        let kind: LocalEntry.Kind
        var url: URL { repository.appendingPathComponent(relative) }
        var tool: String {
            if repository.path.contains("/.codex/worktrees/") { return "Codex worktree" }
            if repository.path.contains("/.claude/worktrees/") { return "Claude worktree" }
            return "Git project/worktree"
        }
        var consequence: String {
            switch kind {
            case .nodeDependencies:
                "Reinstall dependencies using the project's lockfile. Downloads, registry access and install scripts may be needed. Local edits inside node_modules cannot be reliably distinguished; review first."
            case .nextCache:
                "Next.js recreates this cache. The next build may be slower. Other .next contents, source files and dependencies stay."
            default:
                "Swift recreates this build output. The next build may take longer. Dependency checkouts, repositories, downloaded artifacts, source files and worktrees stay."
            }
        }
    }

    private func targets(in inventory: RepositoryInventory) throws -> [Target] {
        var targets: [Target] = []
        var seen = Set<String>()
        for root in inventory.roots.sorted(by: { $0.path < $1.path }) {
            // Missing registered worktrees still protect ownership elsewhere; they
            // do not contain artifacts to inspect here.
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            try LocalFiles.validate(root, within: root)
            var paths: [(String, LocalEntry.Kind)] = [("node_modules", .nodeDependencies), (".next/cache", .nextCache)]
            if regularFile(root.appendingPathComponent("Package.swift")) {
                let build = root.appendingPathComponent(".build")
                // Current Swift Build layout. Never offer all of .build.
                paths.append((".build/out", .swiftBuild))
                // Older SwiftPM layout. Skip debug/release convenience symlinks.
                if FileManager.default.fileExists(atPath: build.path) {
                    for triple in try LocalFiles.children(build) where triple.lastPathComponent.range(
                        of: #"^(arm64|x86_64|arm64e)-apple-macosx([0-9.]+)?$"#, options: .regularExpression) != nil {
                        paths.append((".build/\(triple.lastPathComponent)/debug", .swiftBuild))
                        paths.append((".build/\(triple.lastPathComponent)/release", .swiftBuild))
                    }
                }
            }
            for (path, kind) in paths {
                let target = Target(repository: root, relative: path, kind: kind)
                if FileManager.default.fileExists(atPath: target.url.path), seen.insert(target.url.path).inserted {
                    targets.append(target)
                }
            }
        }
        return targets
    }

    private func regularFile(_ url: URL) -> Bool {
        var info = stat()
        return url.standardizedFileURL.path == url.resolvingSymlinksInPath().path
            && lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    private func identity(_ target: Target) throws {
        try LocalFiles.validate(target.url, within: target.repository)
        switch target.kind {
        case .swiftBuild:
            guard regularFile(target.repository.appendingPathComponent("Package.swift")),
                  regularFile(target.repository.appendingPathComponent(".build/workspace-state.json")) else {
                throw CleanupError.unavailable("Swift package/build identity could not be verified.")
            }
            if target.relative == ".build/out" {
                guard regularFile(target.repository.appendingPathComponent(".build/manifest.pif")),
                      FileManager.default.fileExists(atPath: target.url.appendingPathComponent("Products").path),
                      FileManager.default.fileExists(atPath: target.url.appendingPathComponent("Intermediates.noindex").path) else {
                    throw CleanupError.unavailable("Unrecognised Swift build-output layout; kept.")
                }
            }
        case .nodeDependencies, .nextCache:
            let manifest = target.repository.appendingPathComponent("package.json")
            guard regularFile(manifest),
                  let package = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any] else {
                throw CleanupError.unavailable("Package manifest could not be verified.")
            }
            if target.kind == .nodeDependencies {
                let locks = ["package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb"]
                guard locks.contains(where: { regularFile(target.repository.appendingPathComponent($0)) }) else {
                    throw CleanupError.unavailable("No recognised lockfile; reinstalling the same dependencies is unverified.")
                }
            } else {
                let dependencies = (package["dependencies"] as? [String: Any] ?? [:])
                    .merging(package["devDependencies"] as? [String: Any] ?? [:]) { first, _ in first }
                guard dependencies["next"] != nil else { throw CleanupError.unavailable("Next.js dependency could not be verified.") }
            }
        default: throw CleanupError.unsafePath
        }
    }

    private func gitCheck(_ target: Target) async throws {
        // A tracked artifact is user data even if its name resembles a cache.
        let result = try await runner.run(Command(executable: "/usr/bin/git",
            arguments: ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", target.repository.path,
                        "ls-files", "--cached", "-z", "--", ":(literal)" + target.relative],
            unsetEnvironment: ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS"],
            timeoutSeconds: 15)).checked()
        guard result.output.isEmpty else { throw CleanupError.unavailable("Contains Git-tracked files; kept.") }
    }

    private func assess(_ target: Target, complete: Bool, now: Date) async -> LocalEntry {
        var bytes: Int64 = 0
        var privateBytes: Int64?
        var modified = Date.distantFuture
        var measured = false
        let decision: CleanupEligibility
        do {
            try identity(target)
            let measurement = try await Task.detached { try LocalFiles.measurement(target.url) }.value
            bytes = measurement.bytes; privateBytes = measurement.privateBytes; modified = measurement.modified; measured = true
            guard complete else { throw CleanupError.unavailable("Repository/worktree inventory is incomplete.") }
            try await gitCheck(target)
            if now.timeIntervalSince(modified) < Self.minimumAge {
                decision = .protected("Changed within 7 days")
            } else {
                let users = await usage.inspect(target.repository)
                let usageDecision = users.eligibility(for: target.repository)
                if !usageDecision.canClean { decision = usageDecision }
                else if target.kind == .swiftBuild && users.buildToolsRunning { decision = .protected("Build tools running") }
                else if target.kind == .nodeDependencies { decision = .review(target.consequence) }
                else { decision = .candidate }
            }
        } catch { decision = .unknown(error.localizedDescription) }
        return LocalEntry(id: target.url.path, name: "\(target.repository.lastPathComponent) · \(target.kind.rawValue)",
                          path: target.url.path, bytes: bytes, modified: modified, kind: target.kind,
                          eligibility: decision, ownerPath: target.repository.path, privateBytes: privateBytes,
                          evidence: "\(target.tool). \(target.consequence) Seven-day threshold uses the latest contained modification time, not a complete last-use history. Project processes and open files are checked before removal.",
                          footprintKnown: measured)
    }

    public func load(now: Date = .now) async throws -> LocalReport {
        let inventory = await repositories.inventory()
        let targets = try targets(in: inventory)
        // Bound expensive file/process inspections while allowing independent projects to finish.
        var entries: [LocalEntry] = []
        await withTaskGroup(of: LocalEntry.self) { group in
            var iterator = targets.makeIterator()
            for _ in 0..<3 {
                if let target = iterator.next() { group.addTask { await assess(target, complete: inventory.complete, now: now) } }
            }
            for await entry in group {
                if entry.bytes > 0 || !entry.footprintKnown { entries.append(entry) }
                if let target = iterator.next() { group.addTask { await assess(target, complete: inventory.complete, now: now) } }
            }
        }
        return LocalReport(entries: entries.sorted { $0.bytes > $1.bytes },
                           notice: "Known generated paths in ~/repos and Git-registered worktrees, including Codex and Claude worktrees. Sources and worktrees are never removed. Dependency installs require review; recent or in-use data stays. Manual only.")
    }

    public func clean(ids: [String], now: Date = .now) async throws -> String {
        guard !ids.isEmpty, Set(ids).count == ids.count else { throw CleanupError.stale }
        let inventory = await repositories.inventory()
        guard inventory.complete else { throw CleanupError.stale }
        let targets = try targets(in: inventory).filter { ids.contains($0.url.path) }
        guard targets.count == ids.count else { throw CleanupError.stale }
        for target in targets {
            let firstIdentity = try FileIdentity(target.url)
            let fresh = await assess(target, complete: true, now: now)
            guard fresh.eligible else { throw CleanupError.stale }
            let owners = await repositories.inventory()
            guard owners.complete, owners.roots.contains(where: { $0.path == target.repository.path }) else { throw CleanupError.stale }
            try identity(target)
            try await gitCheck(target)
            let use = await usage.inspect(target.repository)
            guard use.eligibility(for: target.repository).canClean,
                  target.kind != .swiftBuild || !use.buildToolsRunning else { throw CleanupError.stale }
            try await Task.detached {
                try identity(target)
                let last = try LocalFiles.measurement(target.url)
                guard now.timeIntervalSince(last.modified) >= Self.minimumAge,
                      try FileIdentity(target.url) == firstIdentity else { throw CleanupError.stale }
                try LocalFiles.removeGeneratedDirectory(target.url, within: target.repository)
            }.value
        }
        return "Removed \(targets.count) generated folders. Source files, worktrees and Swift dependency checkouts were preserved. Rebuild or reinstall selected dependencies before using those projects."
    }
}

/// Prevent a replacement at the same path from inheriting an earlier assessment.
struct FileIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    init(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { throw CleanupError.unsafePath }
        device = info.st_dev; inode = info.st_ino
    }
}
