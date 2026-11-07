import Foundation
import Darwin

/// Tool-specific roots only. Conversation files, databases, settings and credentials
/// never pass through the diagnostic-log removal path.
public struct AgentDataService: Sendable {
    public static let minimumLogAge: TimeInterval = 30 * 86400
    public let codexRoot: URL
    public let claudeRoot: URL
    private let usage: any UsageInspecting

    public init(codexRoot: URL? = nil, claudeRoot: URL? = nil, usage: any UsageInspecting = UsageInspector()) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.codexRoot = (codexRoot ?? home.appendingPathComponent(".codex")).standardizedFileURL
        self.claudeRoot = (claudeRoot ?? home.appendingPathComponent(".claude")).standardizedFileURL
        self.usage = usage
    }

    private var logRoots: [(URL, String)] {
        [(codexRoot.appendingPathComponent("log"), "Codex"), (claudeRoot.appendingPathComponent("debug"), "Claude")]
    }
    private func isLog(_ url: URL, tool: String) -> Bool {
        tool == "Codex" ? url.lastPathComponent == "codex-tui.log"
        : url.pathExtension == "txt" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }
    private func fileInfo(_ url: URL, root: URL) throws -> stat {
        try LocalFiles.validate(root, within: root)
        guard url.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else {
            throw CleanupError.unavailable("Diagnostic log is outside its known root: \(url.path) (root \(root.path)).")
        }
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else {
            throw CleanupError.unavailable("Diagnostic log path contains a symbolic link: \(url.path).")
        }
        var item = stat(), directory = stat()
        guard lstat(url.path, &item) == 0, stat(root.path, &directory) == 0,
              item.st_mode & S_IFMT == S_IFREG, item.st_dev == directory.st_dev,
              item.st_nlink == 1 else { throw CleanupError.unavailable("Diagnostic log is not a regular, singly linked file on its root volume.") }
        return item
    }

    public func load(now: Date = .now) async throws -> LocalReport {
        var entries: [LocalEntry] = []
        for (root, tool) in logRoots {
            let files = try LocalFiles.children(root).filter { isLog($0, tool: tool) }
            var evidence: UsageEvidence?
            for file in files {
                let info = try fileInfo(file, root: root)
                let changed = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
                let eligibility: CleanupEligibility
                if now.timeIntervalSince(changed) < Self.minimumLogAge {
                    eligibility = .protected("Diagnostic log changed within 30 days")
                } else {
                    if evidence == nil { evidence = await usage.inspect(root) }
                    let decision = evidence!.eligibility(for: file)
                    eligibility = decision.canClean
                        ? .review("Old diagnostic log, not a conversation. Deleting it loses past troubleshooting evidence; the tool can create new logs.") : decision
                }
                entries.append(LocalEntry(id: file.path, name: "\(tool) · \(file.lastPathComponent)", path: file.path,
                    bytes: Int64(info.st_blocks) * 512, modified: changed, kind: .agentLog, eligibility: eligibility,
                    privateBytes: LocalFiles.privateFileBytes(file), evidence: "Only this diagnostic log is removed. 30-day modification threshold; executable, mapped-file and open-file checks. Conversations, settings, credentials and worktrees stay."))
            }
        }
        let histories = [(codexRoot.appendingPathComponent("sessions"), "Codex conversations"),
                         (codexRoot.appendingPathComponent("archived_sessions"), "Codex archived conversations"),
                         (claudeRoot.appendingPathComponent("projects"), "Claude session data")]
        for (root, name) in histories where FileManager.default.fileExists(atPath: root.path) {
            let measurement = try await Task.detached { try LocalFiles.measurement(root) }.value
            guard measurement.bytes > 0 else { continue }
            entries.append(LocalEntry(id: root.path, name: name, path: root.path, bytes: measurement.bytes,
                modified: measurement.modified, kind: .agentHistory,
                eligibility: .protected("Unique conversation history · cannot be rebuilt"), privateBytes: measurement.privateBytes,
                evidence: "This contains conversation/session records, not a rebuildable cache. Age alone does not make it disposable. Manage history in the owning app. Generated data in registered Codex/Claude worktrees is assessed separately under Projects. No transcript contents are read."))
        }
        return LocalReport(entries: entries, notice: "Codex and Claude: old diagnostic logs can be reviewed; unique conversation history stays. Registered worktree build outputs and dependencies appear under Projects. No transcript contents are read.")
    }

    public func clean(ids: [String], now: Date = .now) async throws -> String {
        guard !ids.isEmpty, Set(ids).count == ids.count else { throw CleanupError.stale }
        // Resolve only exact allowlisted diagnostic filenames. Never accept a history root.
        for id in ids {
            let file = URL(fileURLWithPath: id)
            guard let (root, tool) = logRoots.first(where: { $0.0.path == file.deletingLastPathComponent().path }),
                  isLog(file, tool: tool) else { throw CleanupError.unsafePath }
            let initial = try FileIdentity(file)
            _ = try fileInfo(file, root: root)
            let use = await usage.inspect(root)
            guard use.eligibility(for: file).canClean else { throw CleanupError.stale }
            let fresh = try fileInfo(file, root: root)
            guard now.timeIntervalSince1970 - Double(fresh.st_mtimespec.tv_sec) >= Self.minimumLogAge,
                  try FileIdentity(file) == initial else { throw CleanupError.stale }
            try FileManager.default.removeItem(at: file)
        }
        return "Removed \(ids.count) old diagnostic logs. Conversations, session history, settings, credentials and worktrees were preserved."
    }
}
