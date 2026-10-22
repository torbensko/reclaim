import Foundation
import Darwin

public enum CleanupEligibility: Hashable, Sendable {
    case candidate
    case protected(String)
    case unknown(String)
    case inspectOnly
    public var canClean: Bool { if case .candidate = self { true } else { false } }
    public var label: String {
        switch self {
        case .candidate: "Safe to clean"
        case let .protected(reason): reason
        case .unknown: "Unverified — kept"
        case .inspectOnly: "Inspect only"
        }
    }
    public var explanation: String {
        switch self {
        case .candidate: "Passed the current checks. Ownership, age and usage are checked again before removal."
        case let .protected(reason): reason
        case let .unknown(reason): "Protected because cleanup safety could not be verified: \(reason)"
        case .inspectOnly: "Reclaim does not delete this data."
        }
    }
}

public struct UsageEvidence: Sendable {
    public let executablePaths: [Int32: String]
    public let openPaths: [Int32: [String]]
    public let complete: Bool
    public let issue: String?
    public init(executablePaths: [Int32: String] = [:], openPaths: [Int32: [String]] = [:], complete: Bool = true, issue: String? = nil) {
        self.executablePaths = executablePaths; self.openPaths = openPaths; self.complete = complete; self.issue = issue
    }
    public func users(of root: URL) -> [Int32] {
        let rootPath = LocalFiles.canonicalPath(root.path)
        func matches(_ path: String) -> Bool {
            guard path.hasPrefix("/") else { return false }
            let normalized = LocalFiles.canonicalPath(path)
            return normalized == rootPath || normalized.hasPrefix(rootPath + "/")
        }
        return Set(executablePaths.filter { matches($0.value) }.map(\.key) + openPaths.filter { $0.value.contains(where: matches) }.map(\.key)).sorted()
    }
    public var buildToolsRunning: Bool {
        executablePaths.values.contains {
            ["Xcode", "xcodebuild", "XCBBuildService", "swift-frontend", "swiftc", "clang", "clang++", "ld"].contains(URL(fileURLWithPath: $0).lastPathComponent)
        }
    }
    public func eligibility(for root: URL) -> CleanupEligibility {
        let pids = users(of: root)
        if !pids.isEmpty { return .protected("In use · PID " + pids.map(String.init).joined(separator: ", ")) }
        if !complete { return .unknown(issue ?? "Process or open-file inspection failed.") }
        return .candidate
    }
}

public protocol UsageInspecting: Sendable {
    func inspect(_ root: URL) async -> UsageEvidence
}

public struct UsageInspector: UsageInspecting {
    private let runner: any CommandRunning
    public init(runner: any CommandRunning = ProcessRunner()) { self.runner = runner }
    public func inspect(_ root: URL) async -> UsageEvidence {
        var executables: [Int32: String] = [:]
        do {
            let ps = try await runner.run(Command(executable: "/bin/ps", arguments: ["-ww", "-axo", "pid=,comm="], timeoutSeconds: 15)).checked()
            executables = try Self.parseProcesses(ps.text)
            // Include mapped libraries and working directories, not just executable paths.
            let files = try await runner.run(Command(executable: "/usr/sbin/lsof", arguments: ["-n", "-P", "-F0pn", "+D", root.path], timeoutSeconds: 45))
            return Self.parseOpenFiles(files, executables: executables)
        } catch {
            return UsageEvidence(executablePaths: executables, complete: false, issue: error.localizedDescription)
        }
    }
    public static func parseProcesses(_ text: String) throws -> [Int32: String] {
        var paths: [Int32: String] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]), pid > 0 else { throw CleanupError.invalidResponse }
            paths[pid] = String(fields[1]).trimmingCharacters(in: .whitespaces)
        }
        guard !paths.isEmpty else { throw CleanupError.invalidResponse }
        return paths
    }
    public static func parseOpenFiles(_ result: CommandResult, executables: [Int32: String]) -> UsageEvidence {
        var paths: [Int32: [String]] = [:]
        var pid: Int32?
        var awaitingPath = false
        var complete = [0, 1].contains(result.exitCode)
        if !result.text.isEmpty && !result.text.contains("\0") { complete = false }
        // lsof exits 1 for unselected files even when other files match. Any diagnostics,
        // malformed field or unexpected exit code prevents a claim of no active use.
        for part in result.text.split(separator: "\0", omittingEmptySubsequences: false) {
            let field = part.drop(while: { $0 == "\n" })
            guard !field.isEmpty else { continue }
            switch field.first {
            case "p":
                if awaitingPath { complete = false }
                awaitingPath = false
                if let value = Int32(field.dropFirst()), value > 0 { pid = value }
                else { complete = false; pid = nil }
            case "f":
                if awaitingPath || pid == nil || field.count < 2 || field.contains("NOFD") { complete = false }
                awaitingPath = true
            case "n":
                if !awaitingPath { complete = false }
                if let pid, field.dropFirst().hasPrefix("/") { paths[pid, default: []].append(String(field.dropFirst())) }
                else { complete = false }
                awaitingPath = false
            default: complete = false
            }
        }
        if awaitingPath { complete = false }
        if pid != nil && paths.isEmpty { complete = false }
        return UsageEvidence(executablePaths: executables, openPaths: paths, complete: complete,
                             issue: complete ? nil : "Open-file inspection was incomplete or denied. No unmatched item is eligible.")
    }
}

public struct RepositoryInventory: Sendable {
    public let roots: [URL]
    public let complete: Bool
    public init(roots: [URL], complete: Bool = true) { self.roots = roots; self.complete = complete }
    public func owner(of workspace: URL) -> URL? {
        let path = LocalFiles.canonicalPath(workspace.path)
        return roots.filter {
            let root = LocalFiles.canonicalPath($0.path)
            return path == root || path.hasPrefix(root + "/")
        }.max { $0.path.count < $1.path.count }
    }
}

public protocol RepositoriesInspecting: Sendable {
    func inventory() async -> RepositoryInventory
}

public struct RepositoryInspector: RepositoriesInspecting {
    public let root: URL
    private let runner: any CommandRunning
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("repos"), runner: any CommandRunning = ProcessRunner()) {
        self.root = root; self.runner = runner
    }
    public func inventory() async -> RepositoryInventory {
        do {
            guard FileManager.default.fileExists(atPath: root.path) else { return RepositoryInventory(roots: [], complete: false) }
            var roots = Set<URL>()
            var complete = true
            // Inspect direct repo folders only, then ask Git for registered worktrees
            // (including those outside ~/repos). Never scan source trees or prune Git.
            for directory in try LocalFiles.children(root) {
                var directoryInfo = stat()
                guard lstat(directory.path, &directoryInfo) == 0 else { complete = false; continue }
                if directoryInfo.st_mode & S_IFMT == S_IFREG { continue }
                if directoryInfo.st_mode & S_IFMT == S_IFLNK { complete = false; continue }
                guard directoryInfo.st_mode & S_IFMT == S_IFDIR else { continue }
                let marker = directory.appendingPathComponent(".git")
                var info = stat()
                guard lstat(marker.path, &info) == 0 else {
                    if errno != ENOENT { complete = false }
                    continue
                }
                roots.insert(directory.standardizedFileURL)
                do {
                    try LocalFiles.validate(directory, within: root)
                    let result = try await runner.run(Command(executable: "/usr/bin/git",
                        arguments: ["--no-optional-locks", "-C", directory.path, "worktree", "list", "--porcelain", "-z"],
                        unsetEnvironment: ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS"], timeoutSeconds: 15)).checked()
                    roots.formUnion(try Self.parseWorktrees(result.text))
                } catch { complete = false }
            }
            return RepositoryInventory(roots: Array(roots), complete: complete)
        } catch { return RepositoryInventory(roots: [], complete: false) }
    }
    public static func parseWorktrees(_ text: String) throws -> [URL] {
        guard text.contains("\0") else { throw CleanupError.invalidResponse }
        let roots = text.split(separator: "\0").filter { $0.hasPrefix("worktree ") }.map { String($0.dropFirst(9)) }
        guard !roots.isEmpty, roots.allSatisfy({ $0.hasPrefix("/") }) else { throw CleanupError.invalidResponse }
        return roots.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }
}

public enum XcodePolicy {
    public static let minimumAge: TimeInterval = 7 * 86400
    public static func ownership(workspace: URL, inventory: RepositoryInventory) -> CleanupEligibility? {
        if let owner = inventory.owner(of: workspace) { return .protected("Registered worktree · \(owner.lastPathComponent)") }
        // lstat distinguishes confirmed absence from access failures. A symlink,
        // renamed project in a surviving directory, or non-Git workspace stays kept.
        var info = stat()
        if lstat(workspace.path, &info) == 0 { return .protected("Source project exists") }
        guard errno == ENOENT else { return .unknown("Source project access could not be checked.") }
        if lstat(workspace.deletingLastPathComponent().path, &info) == 0 { return .protected("Source folder exists") }
        guard errno == ENOENT, inventory.complete else { return .unknown("Repository/worktree inventory is incomplete.") }
        return nil
    }
}
