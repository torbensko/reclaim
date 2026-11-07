import Foundation
import Testing
@testable import ReclaimCore

private struct ArtifactFixture {
    let root: URL
    var repo: URL { root.appendingPathComponent("repo") }
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ReclaimArtifacts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    @discardableResult func file(_ relative: String, _ text: String = "generated fixture") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    func swiftOutput() throws -> URL {
        try file("repo/Package.swift", "// swift-tools-version: 6.0")
        try file("repo/.build/workspace-state.json", "{}")
        try file("repo/.build/manifest.pif", "{}")
        try file("repo/.build/out/Products/debug/App")
        try file("repo/.build/out/Intermediates.noindex/object.o")
        return repo.appendingPathComponent(".build/out")
    }
    func nodeOutput(lock: Bool = true) throws -> URL {
        try file("repo/package.json", #"{"dependencies":{"next":"1.0"}}"#)
        if lock { try file("repo/package-lock.json", "{}") }
        try file("repo/node_modules/package/index.js")
        return repo.appendingPathComponent("node_modules")
    }
}

private func makeOld(_ url: URL, days: Double = 8) throws {
    let children = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
    for child in children + [url] {
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-days * 86400)], ofItemAtPath: child.path)
    }
}
private struct ArtifactRepositories: RepositoriesInspecting {
    let roots: [URL]
    var complete = true
    func inventory() async -> RepositoryInventory { RepositoryInventory(roots: roots, complete: complete) }
}
private struct ArtifactUsage: UsageInspecting {
    var evidence = UsageEvidence()
    func inspect(_ root: URL) async -> UsageEvidence { evidence }
}
private actor ArtifactChangingUsage: UsageInspecting {
    var calls = 0
    func inspect(_ root: URL) async -> UsageEvidence {
        calls += 1
        return calls == 1 ? UsageEvidence() : UsageEvidence(openPaths: [99: [root.appendingPathComponent("source.swift").path]])
    }
}
private actor ArtifactGit: CommandRunning {
    var trackedOnCall: Int?
    var failure = false
    private(set) var commands: [Command] = []
    init(trackedOnCall: Int? = nil, failure: Bool = false) { self.trackedOnCall = trackedOnCall; self.failure = failure }
    func run(_ command: Command) async throws -> CommandResult {
        commands.append(command)
        if failure { throw CleanupError.unavailable("Fixture Git failure") }
        return CommandResult(output: commands.count == trackedOnCall ? Data("node_modules/owned.js\0".utf8) : Data(), exitCode: 0)
    }
}
private func artifacts(_ fixture: ArtifactFixture, usage: any UsageInspecting = ArtifactUsage(),
                       runner: any CommandRunning = ArtifactGit(), complete: Bool = true) -> ProjectArtifactsService {
    ProjectArtifactsService(repositories: ArtifactRepositories(roots: [fixture.repo], complete: complete), usage: usage, runner: runner)
}

@Test func oldSwiftOutputIsSuggestedInsideAnExistingRegisteredProject() async throws {
    let f = try ArtifactFixture(); defer { f.remove() }
    let output = try f.swiftOutput()
    let source = try f.file("repo/Sources/App.swift")
    let checkout = try f.file("repo/.build/checkouts/dependency/Source.swift")
    let downloaded = try f.file("repo/.build/artifacts/framework")
    try makeOld(output)
    let service = artifacts(f)
    let report = try await service.load()
    #expect(report.entries.count == 1)
    #expect(report.entries.first?.eligibility.isRecommended == true)
    #expect(report.entries.first?.ownerPath == f.repo.path)
    _ = try await service.clean(ids: [output.path])
    #expect(!FileManager.default.fileExists(atPath: output.path))
    for kept in [source, checkout, downloaded, f.repo] { #expect(FileManager.default.fileExists(atPath: kept.path)) }
}

@Test func nodeDependenciesRequireReviewAndALockfile() async throws {
    for lock in [true, false] {
        let f = try ArtifactFixture(); defer { f.remove() }
        let output = try f.nodeOutput(lock: lock)
        try makeOld(output)
        let service = artifacts(f)
        let report = try await service.load()
        #expect(report.entries.first?.eligibility.needsReview == lock)
        #expect(report.recommendedCount == 0)
        if lock {
            #expect(report.reviewCount == 1)
            _ = try await service.clean(ids: [output.path])
            #expect(FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("package-lock.json").path))
        } else {
            await #expect(throws: (any Error).self) { try await service.clean(ids: [output.path]) }
            #expect(FileManager.default.fileExists(atPath: output.path))
        }
    }
}

@Test func oldNextCacheIsRecognisedWithoutOfferingTheWholeBuildDirectory() async throws {
    let f = try ArtifactFixture(); defer { f.remove() }
    _ = try f.nodeOutput()
    let cache = try f.file("repo/.next/cache/compiler/file").deletingLastPathComponent().deletingLastPathComponent()
    let server = try f.file("repo/.next/server/app.js")
    try makeOld(cache)
    let service = artifacts(f)
    #expect(try await service.load().entries.contains { $0.path == cache.path && $0.eligibility.isRecommended })
    _ = try await service.clean(ids: [cache.path])
    #expect(FileManager.default.fileExists(atPath: server.path))
}

@Test func artifactUsageFailuresRecentChangesAndTrackedFilesAlwaysKeepData() async throws {
    for mode in 0...5 {
        let f = try ArtifactFixture(); defer { f.remove() }
        let output = try f.swiftOutput()
        try makeOld(output)
        if mode == 0 { try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: output.appendingPathComponent("Products/debug/App").path) }
        let usage = ArtifactUsage(evidence: mode == 1 ? UsageEvidence(openPaths: [42: [f.repo.appendingPathComponent("Source.swift").path]])
                                  : mode == 2 ? UsageEvidence(complete: false, issue: "Inspection denied") : UsageEvidence())
        let git = ArtifactGit(trackedOnCall: mode == 3 ? 1 : nil, failure: mode == 4)
        let service = artifacts(f, usage: usage, runner: git, complete: mode != 5)
        #expect(try await service.load().candidateCount == 0)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
}

@Test func removalRechecksUsageAndNewTrackedFiles() async throws {
    for tracked in [false, true] {
        let f = try ArtifactFixture(); defer { f.remove() }
        let output = try f.swiftOutput(); try makeOld(output)
        let service = tracked ? artifacts(f, runner: ArtifactGit(trackedOnCall: 2)) : artifacts(f, usage: ArtifactChangingUsage())
        await #expect(throws: (any Error).self) { try await service.clean(ids: [output.path]) }
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
}

@Test func arbitraryPathsAndSymlinkedArtifactRootsCannotBeRemoved() async throws {
    let f = try ArtifactFixture(); defer { f.remove() }
    let output = try f.swiftOutput(); try makeOld(output)
    let precious = try f.file("precious/Source.swift").deletingLastPathComponent()
    let service = artifacts(f)
    for path in [f.repo.path, precious.path, f.repo.appendingPathComponent(".build").path] {
        await #expect(throws: (any Error).self) { try await service.clean(ids: [path]) }
    }
    // Destructive setup is confined to this generated fixture.
    try FileManager.default.removeItem(at: output)
    try FileManager.default.createSymbolicLink(at: output, withDestinationURL: precious)
    #expect(try await service.load().candidateCount == 0)
    await #expect(throws: (any Error).self) { try await service.clean(ids: [output.path]) }
    #expect(FileManager.default.fileExists(atPath: precious.appendingPathComponent("Source.swift").path))
}

@Test func xcodeManualPolicyAllowsExistingSourcesButScheduledPolicyStillKeepsThem() async throws {
    let f = try ArtifactFixture(); defer { f.remove() }
    let workspace = try f.file("repo/App.xcodeproj/project.pbxproj").deletingLastPathComponent()
    let output = try f.file("DerivedData/App/Build/output").deletingLastPathComponent()
    let plist = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": workspace.path], format: .xml, options: 0)
    try plist.write(to: f.root.appendingPathComponent("DerivedData/App/info.plist"))
    try makeOld(output)
    let repositories = ArtifactRepositories(roots: [f.repo])
    let root = f.root.appendingPathComponent("DerivedData")
    let scheduled = XcodeService(root: root, usage: ArtifactUsage(), repositories: repositories)
    let manual = XcodeService(root: root, usage: ArtifactUsage(), repositories: repositories, policy: .manual)
    #expect(try await scheduled.load().candidateCount == 0)
    #expect(try await manual.load().candidateCount == 1)
    let busy = XcodeService(root: root, usage: ArtifactUsage(evidence: UsageEvidence(openPaths: [51: [workspace.path]])), repositories: repositories, policy: .manual)
    #expect(try await busy.load().candidateCount == 0)
    _ = try await manual.clean(ids: ["App"])
    #expect(FileManager.default.fileExists(atPath: workspace.path))
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test func agentHistoryIsNeverTreatedAsARebuildableLog() async throws {
    let f = try ArtifactFixture(); defer { f.remove() }
    let log = try f.file("codex/log/codex-tui.log")
    try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-31 * 86400)], ofItemAtPath: log.path)
    let history = try f.file("codex/sessions/2026/01/conversation.jsonl")
    let claude = try f.file("claude/projects/project/conversation.jsonl")
    let service = AgentDataService(codexRoot: f.root.appendingPathComponent("codex"), claudeRoot: f.root.appendingPathComponent("claude"), usage: ArtifactUsage())
    let report = try await service.load()
    #expect(report.reviewCount == 1)
    #expect(report.entries.filter { $0.kind == .agentHistory }.allSatisfy { !$0.eligible })
    await #expect(throws: (any Error).self) { try await service.clean(ids: [history.path]) }
    _ = try await service.clean(ids: [log.path])
    #expect(FileManager.default.fileExists(atPath: history.path))
    #expect(FileManager.default.fileExists(atPath: claude.path))
}

@Test func recentOrOpenAgentLogsStay() async throws {
    let f = try ArtifactFixture(); defer { f.remove() }
    let log = try f.file("claude/debug/00000000-0000-0000-0000-000000000001.txt")
    for inUse in [false, true] {
        if inUse { try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-31 * 86400)], ofItemAtPath: log.path) }
        let usage = ArtifactUsage(evidence: inUse ? UsageEvidence(openPaths: [44: [log.path]]) : UsageEvidence())
        let service = AgentDataService(codexRoot: f.root.appendingPathComponent("codex"), claudeRoot: f.root.appendingPathComponent("claude"), usage: usage)
        #expect(try await service.load().candidateCount == 0)
        await #expect(throws: (any Error).self) { try await service.clean(ids: [log.path]) }
        #expect(FileManager.default.fileExists(atPath: log.path))
    }
}
