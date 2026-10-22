import Foundation
import Darwin
import Testing
@testable import ReclaimCore

private struct Fixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ReclaimTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func file(_ path: String, data: Data = Data(repeating: 1, count: 16384)) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
    func plist(_ path: String, _ value: [String: Any]) throws {
        _ = try file(path, data: PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0))
    }
}

private actor Runner: CommandRunning {
    var responses: [CommandResult]
    private(set) var commands: [Command] = []
    init(_ responses: [CommandResult]) { self.responses = responses }
    func run(_ command: Command) async throws -> CommandResult {
        commands.append(command)
        guard !responses.isEmpty else { throw CleanupError.unavailable("Unexpected command") }
        return responses.removeFirst()
    }
}
private func response(_ text: String = "", code: Int32 = 0) -> CommandResult { CommandResult(output: Data(text.utf8), exitCode: code) }

@Test func applicablePrivateSizeExcludesKeptDataAndPreservesUnknownMeasurements() {
    func entry(_ id: String, privateBytes: Int64?, eligibility: CleanupEligibility) -> LocalEntry {
        LocalEntry(id: id, name: id, path: "/fixture/\(id)", bytes: 1_000_000,
                   modified: .distantPast, kind: .chromeClone, eligibility: eligibility, privateBytes: privateBytes)
    }
    let first = entry("first", privateBytes: 100, eligibility: .candidate)
    let second = entry("second", privateBytes: 200, eligibility: .candidate)
    let kept = entry("kept", privateBytes: 50_000, eligibility: .protected("In use"))
    let unmeasuredKept = entry("unmeasured-kept", privateBytes: nil, eligibility: .unknown("Usage unknown"))
    let report = LocalReport(entries: [first, second, kept, unmeasuredKept], notice: nil)
    #expect(report.applicablePrivateBytes == 300)
    #expect(report.privateBytes == nil)
    let unmeasured = entry("unmeasured", privateBytes: nil, eligibility: .candidate)
    #expect(LocalReport(entries: [first, unmeasured], notice: nil).applicablePrivateBytes == nil)
    let shared = entry("shared", privateBytes: 0, eligibility: .candidate)
    #expect(LocalReport(entries: [shared], notice: nil).applicablePrivateBytes == 0)
    #expect(LocalReport(entries: [kept, unmeasuredKept], notice: nil).applicablePrivateBytes == 0)
    #expect(LocalReport(entries: [], notice: nil).applicablePrivateBytes == 0)
}

@Test func dockerSizesUseUnitsAndRejectMalformedValues() throws {
    #expect(try DockerService.parseSize("3.937GB") == 3_937_000_000)
    #expect(try DockerService.parseSize("32B") == 32)
    #expect(try DockerService.parseSize("1.5 MiB") == 1_572_864)
    for size in ["-1GB", "unknown", "4GB\n", "4GBextra", "999999999999999999999TB"] {
        #expect(throws: (any Error).self) { try DockerService.parseSize(size) }
    }
}

private let imageID = "sha256:" + String(repeating: "a", count: 64)
private let dockerSummary = """
{"Type":"Images","Size":"4GB","Reclaimable":"2GB (50%)"}
{"Type":"Build Cache","Size":"3GB","Reclaimable":"1.5GB"}
"""
private func dockerDetail(containers: Int = 0, tagged: Bool = false) -> String {
    """
    {"Images":[{"ID":"\(imageID)","Repository":"\(tagged ? "test" : "<none>")","Tag":"\(tagged ? "latest" : "<none>")","Containers":"\(containers)","Size":"4GB","CreatedSince":"2 days ago","CreatedAt":"2026-01-01 00:00:00 +0000 UTC","UniqueSize":"1GB","SharedSize":"3GB"}],"BuildCache":[]}
    """
}

private func dockerReferences(tags: [String] = [], digests: [String] = [], id: String = imageID) -> CommandResult {
    let data = try! JSONSerialization.data(withJSONObject: ["ID": id, "RepoTags": tags, "RepoDigests": digests])
    return CommandResult(output: data, exitCode: 0)
}

private func dockerLoad(containers: Int = 0, tags: [String] = [], digests: [String] = []) -> [CommandResult] {
    [response(dockerSummary), response(dockerDetail(containers: containers, tagged: !tags.isEmpty)),
     dockerReferences(tags: tags, digests: digests)]
}

private var emptyDockerLoad: [CommandResult] {
    [response(dockerSummary), response(#"{"Images":[],"BuildCache":[]}"#)]
}

@Test func dockerCacheCannotBePrunedAndCommandsStayLocal() async throws {
    let runner = Runner([])
    let service = DockerService(executable: "/fixture/docker", socket: "/fixture/docker.sock", runner: runner)
    await #expect(throws: (any Error).self) { try await service.cleanBuildCache() }
    #expect(await runner.commands.isEmpty)
    let command = try service.command(["system", "df"])
    #expect(command.arguments.prefix(2) == ["--host", "unix:///fixture/docker.sock"])
    #expect(command.unsetEnvironment.contains("DOCKER_CONTEXT"))
    #expect(command.unsetEnvironment.contains("DOCKER_HOST"))
}

@Test func dockerUsedImageIsRejectedAndUnusedRemovalNeverForced() async throws {
    for count in [0, 1] {
        let runner = Runner(dockerLoad(containers: count) + dockerLoad(containers: count) + [response()] + emptyDockerLoad)
        let service = DockerService(executable: "/fixture/docker", socket: "/fixture/docker.sock", runner: runner)
        if count == 0 {
            _ = try await service.removeImages(ids: [imageID])
            let removals = await runner.commands.filter { $0.arguments.contains("rm") }
            #expect(removals.count == 1)
            #expect(removals.first?.arguments.suffix(5) == ["image", "rm", "--no-prune", "--", imageID])
            #expect(removals.first?.arguments.contains("--force") == false)
        } else {
            await #expect(throws: (any Error).self) { try await service.removeImages(ids: [imageID]) }
            #expect(await runner.commands.count == 3)
        }
    }
    let runner = Runner([])
    await #expect(throws: (any Error).self) {
        try await DockerService(runner: runner).removeImages(ids: ["--all"])
    }
    #expect(await runner.commands.isEmpty)
}

private struct Repositories: RepositoriesInspecting {
    var roots: [URL] = []
    var complete = true
    func inventory() async -> RepositoryInventory { RepositoryInventory(roots: roots, complete: complete) }
}
private struct Usage: UsageInspecting {
    var evidence = UsageEvidence()
    func inspect(_ root: URL) async -> UsageEvidence { evidence }
}
private actor ChangingUsage: UsageInspecting {
    var calls = 0
    func inspect(_ root: URL) async -> UsageEvidence {
        calls += 1
        return calls == 1 ? UsageEvidence() : UsageEvidence(openPaths: [42: [root.appendingPathComponent("file").path]])
    }
}
private func ageTree(_ url: URL, days: Double = 8) throws {
    let children = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }
    for item in children + [url] {
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-days * 86400)], ofItemAtPath: item.path)
    }
}
private func makeProject(_ fixture: Fixture, owner: String? = nil) throws -> URL {
    try fixture.plist("DerivedData/Example/info.plist", ["WorkspacePath": owner ?? fixture.root.appendingPathComponent("removed/Example.xcodeproj").path])
    let output = try fixture.file("DerivedData/Example/Build/nested/output")
    try ageTree(fixture.root.appendingPathComponent("DerivedData/Example/Build"))
    return output
}

@Test func xcodeOnlyRemovesVerifiedOrphanGeneratedFolders() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    _ = try makeProject(fixture)
    _ = try fixture.file("DerivedData/Example/Index.noindex/data")
    try ageTree(fixture.root.appendingPathComponent("DerivedData/Example/Index.noindex"))
    let preserved = try fixture.file("DerivedData/Example/SourcePackages/checkout/code.swift")
    let archive = try fixture.file("Archives/Example.xcarchive/data")
    let service = XcodeService(root: fixture.root.appendingPathComponent("DerivedData"), usage: Usage(), repositories: Repositories())
    let report = try await service.load()
    #expect(report.entries.map(\.id) == ["Example"])
    #expect(report.candidateCount == 1)
    _ = try await service.clean(ids: ["Example"])
    #expect(FileManager.default.fileExists(atPath: preserved.path))
    #expect(FileManager.default.fileExists(atPath: archive.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("DerivedData/Example/Build").path))
}

@Test func xcodeRejectsRunningBuildRecentActivityAndSymlinkedProject() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let output = try makeProject(fixture)
    let root = fixture.root.appendingPathComponent("DerivedData")
    let active = XcodeService(root: root, usage: Usage(evidence: UsageEvidence(executablePaths: [42: "/usr/bin/xcodebuild"])), repositories: Repositories())
    #expect(try await active.load().candidateCount == 0)
    await #expect(throws: (any Error).self) { try await active.clean(ids: ["Example"]) }
    try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: output.path)
    let recent = XcodeService(root: root, usage: Usage(), repositories: Repositories())
    #expect(try await recent.load().candidateCount == 0)
    await #expect(throws: (any Error).self) { try await recent.clean(ids: ["Example"]) }
    #expect(FileManager.default.fileExists(atPath: output.path))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked"), withDestinationURL: root.appendingPathComponent("Example"))
    await #expect(throws: (any Error).self) { try await recent.load() }
}

@Test func xcodeProtectsExistingSourcesRegisteredWorktreesAndUncertainInventory() async throws {
    for mode in 0...2 {
        let fixture = try Fixture(); defer { fixture.remove() }
        let workspace = fixture.root.appendingPathComponent("repos/worktree/Project.xcodeproj")
        if mode == 0 { _ = try fixture.file("repos/worktree/Project.xcodeproj") }
        let output = try makeProject(fixture, owner: workspace.path)
        let repos = Repositories(roots: mode == 1 ? [workspace.deletingLastPathComponent()] : [], complete: mode != 2)
        let service = XcodeService(root: fixture.root.appendingPathComponent("DerivedData"), usage: Usage(), repositories: repos)
        #expect(try await service.load().candidateCount == 0)
        await #expect(throws: (any Error).self) { try await service.clean(ids: ["Example"]) }
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
}

@Test func xcodeRechecksUseBeforeRemovingAnOldOrphan() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let output = try makeProject(fixture)
    let service = XcodeService(root: fixture.root.appendingPathComponent("DerivedData"), usage: ChangingUsage(), repositories: Repositories())
    await #expect(throws: (any Error).self) { try await service.clean(ids: ["Example"]) }
    #expect(FileManager.default.fileExists(atPath: output.path))
}

private func makeClone(_ fixture: Fixture, id: String, age: TimeInterval) throws -> URL {
    let path = "Clones/\(id)"
    try fixture.plist(path + "/Google Chrome.app.bundle/Contents/Info.plist", ["CFBundleIdentifier": "com.google.Chrome", "CFBundleShortVersionString": "1.2.3"])
    _ = try fixture.file(path + "/Google Chrome.app.bundle/Contents/MacOS/Chrome")
    let url = fixture.root.appendingPathComponent(path)
    try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    return url
}

@Test func chromeStrictNamesAgeAndOpenFilesProtectCopies() async throws {
    #expect(BrowserService.validCloneName("code_sign_clone.lWRU6k"))
    for name in ["code_sign_clone.lWRU6k\n", "../code_sign_clone.lWRU6k", "code_sign_clone.*", "Google Chrome.app"] {
        #expect(!BrowserService.validCloneName(name))
    }
    let fixture = try Fixture(); defer { fixture.remove() }
    let id = "code_sign_clone.abcdef"
    let clone = try makeClone(fixture, id: id, age: 0)
    let service = BrowserService(cloneRoot: fixture.root.appendingPathComponent("Clones"), cacheRoot: fixture.root.appendingPathComponent("Caches"), usage: Usage())
    await #expect(throws: (any Error).self) { try await service.clean(ids: [id]) }
    try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-25 * 3600)], ofItemAtPath: clone.path)
    let inUse = BrowserService(cloneRoot: fixture.root.appendingPathComponent("Clones"), cacheRoot: fixture.root.appendingPathComponent("Caches"), usage: Usage(evidence: UsageEvidence(openPaths: [42: [clone.appendingPathComponent("Google Chrome.app.bundle/Contents/MacOS/Chrome").path]])))
    await #expect(throws: (any Error).self) { try await inUse.clean(ids: [id]) }
    #expect(FileManager.default.fileExists(atPath: clone.path))
}

@Test func chromeRemovesOnlyValidatedOldCopiesAndPreservesCaches() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let id = "code_sign_clone.abcdef"
    let clone = try makeClone(fixture, id: id, age: 25 * 3600)
    let cache = try fixture.file("Caches/Default/Cache/data")
    let unknown = try fixture.file("Clones/unrecognized/data")
    let service = BrowserService(cloneRoot: fixture.root.appendingPathComponent("Clones"), cacheRoot: fixture.root.appendingPathComponent("Caches"), usage: Usage())
    let report = try await service.load()
    #expect(report.entries.count == 2)
    _ = try await service.clean(ids: [id])
    #expect(!FileManager.default.fileExists(atPath: clone.path))
    #expect(FileManager.default.fileExists(atPath: cache.path))
    #expect(FileManager.default.fileExists(atPath: unknown.path))
}

@Test func symlinkedRootsAndUnrecognizedChromeBundlesAreRejected() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let id = "code_sign_clone.abcdef"
    _ = try makeClone(fixture, id: id, age: 25 * 3600)
    let root = fixture.root.appendingPathComponent("Clones")
    let link = fixture.root.appendingPathComponent("Linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    await #expect(throws: (any Error).self) { try await BrowserService(cloneRoot: link).load() }
    try fixture.plist("Clones/\(id)/Google Chrome.app.bundle/Contents/Info.plist", ["CFBundleIdentifier": "unrelated.app"])
    let runner = Runner([response(code: 1)])
    await #expect(throws: (any Error).self) { try await BrowserService(cloneRoot: root, runner: runner).clean(ids: [id]) }
    #expect(await runner.commands.isEmpty)
}

private actor LaunchRunner: CommandRunning {
    private(set) var labels: Set<String>
    private(set) var commands: [Command] = []
    var failNextReclaimBootstrap: Bool
    init(legacy: Bool = false, failBootstrap: Bool = false) {
        labels = legacy ? [ScheduleManager.legacyLabel] : []
        failNextReclaimBootstrap = failBootstrap
    }
    func run(_ command: Command) async throws -> CommandResult {
        commands.append(command)
        let args = command.arguments
        if args.first == "print" {
            return response(code: labels.contains(String(args[1].split(separator: "/").last!)) ? 0 : 113)
        }
        if args.first == "bootout" {
            labels.remove(String(args[1].split(separator: "/").last!)); return response()
        }
        if args.first == "bootstrap" {
            let label = URL(fileURLWithPath: args[2]).deletingPathExtension().lastPathComponent
            if label == ScheduleManager.label && failNextReclaimBootstrap {
                failNextReclaimBootstrap = false
                return response("simulated bootstrap failure", code: 5)
            }
            labels.insert(label); return response()
        }
        throw CleanupError.unavailable("Unexpected launchctl call")
    }
}

private func legacyData() throws -> Data {
    // Foundation may retain /private/var when the Chrome root does not exist
    // (for example on a clean CI runner). Never add /private a second time.
    let root = BrowserService().cloneRoot.path
    let legacyRoot = root.hasPrefix("/var/") ? "/private" + root : root
    return try PropertyListSerialization.data(fromPropertyList: [
        "Label": ScheduleManager.legacyLabel, "StartInterval": 3600, "RunAtLoad": true,
        "ProgramArguments": ["/usr/bin/find", legacyRoot, "-mindepth", "1", "-maxdepth", "1", "-mmin", "+720", "-exec", "rm", "-rf", "{}", "+"]
    ], format: .xml, options: 0)
}

@Test func schedulesAreOffByDefaultAndNeverRunAtLoad() throws {
    let config = ScheduleConfiguration()
    #expect(!config.enabled)
    let manager = ScheduleManager(directory: URL(fileURLWithPath: "/fixture/support"))
    let data = try manager.agentData(for: config)
    let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(plist["RunAtLoad"] as? Bool == false)
    #expect(plist["StartInterval"] as? Int == 3600)
    #expect(plist["ProgramArguments"] as? [String] == ["/fixture/support/ReclaimWorker", "--scheduled"])
    var invalid = config; invalid.intervalHours = 0
    #expect(throws: (any Error).self) { try invalid.validate() }
    invalid = config; invalid.enabled = true; invalid.chrome = false
    #expect(throws: (any Error).self) { try invalid.validate() }
}

@Test func schedulerRequiresExplicitLegacyTakeoverAndRollsBackFailure() async throws {
    for failBootstrap in [false, true] {
        let fixture = try Fixture(); defer { fixture.remove() }
        let runner = LaunchRunner(legacy: true, failBootstrap: failBootstrap)
        let manager = ScheduleManager(directory: fixture.root.appendingPathComponent("Support"), agentsDirectory: fixture.root.appendingPathComponent("Agents"), runner: runner)
        let oldData = try legacyData()
        _ = try fixture.file("Agents/\(ScheduleManager.legacyLabel).plist", data: oldData)
        let helper = try fixture.file("Bundle/ReclaimWorker", data: Data("dummy fixture — never executed".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        var config = ScheduleConfiguration(); config.enabled = true
        await #expect(throws: (any Error).self) { try await manager.save(config, bundledWorker: helper, replaceLegacy: false) }
        #expect(await runner.labels == [ScheduleManager.legacyLabel])
        if failBootstrap {
            await #expect(throws: (any Error).self) { try await manager.save(config, bundledWorker: helper, replaceLegacy: true) }
            #expect(try Data(contentsOf: manager.legacyURL) == oldData)
            #expect(await runner.labels == [ScheduleManager.legacyLabel])
            #expect(try manager.configuration().enabled == false)
        } else {
            try await manager.save(config, bundledWorker: helper, replaceLegacy: true)
            #expect(await runner.labels == [ScheduleManager.label])
            #expect(!FileManager.default.fileExists(atPath: manager.legacyURL.path))
            #expect(try manager.configuration() == config)
            let backups = try FileManager.default.contentsOfDirectory(at: manager.directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "backup" }
            #expect(backups.count == 1)
            #expect(try Data(contentsOf: backups[0]) == oldData)
            config.enabled = false
            try await manager.save(config, bundledWorker: helper, replaceLegacy: false)
            #expect(await runner.labels.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: manager.agentURL.path))
        }
    }
}

@Test func cleanupLockPreventsOverlapAndDisabledWorkerDoesNothing() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let manager = ScheduleManager(directory: fixture.root.appendingPathComponent("Support"))
    do {
        let lock = try CleanupLock(directory: manager.directory)
        defer { withExtendedLifetime(lock) {} }
        #expect(throws: (any Error).self) { try CleanupLock(directory: manager.directory) }
    }
    try await ScheduledCleanup().run(manager: manager)
    #expect(!FileManager.default.fileExists(atPath: manager.lastRunURL.path))
}

@Test func frameworkSymlinksDoNotHideVersionedFilesOrFollowDestinations() throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let external = try fixture.file("outside/should-not-count", data: Data(repeating: 3, count: 1048576))
    _ = try fixture.file("Framework/Versions/1/large-binary", data: Data(repeating: 2, count: 32768))
    let root = fixture.root.appendingPathComponent("Framework")
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Current"), withDestinationURL: root.appendingPathComponent("Versions/1"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Libraries"), withDestinationURL: external.deletingLastPathComponent())
    let bytes = try LocalFiles.allocatedBytes(root)
    #expect(bytes == 32768)
    try LocalFiles.removeGeneratedDirectory(root, within: fixture.root)
    #expect(FileManager.default.fileExists(atPath: external.path))
}

@Test func chromeRootUsesTheOSUserTemporaryRootNotAnAppSpecificOverride() {
    #expect(BrowserService().cloneRoot.lastPathComponent == "com.google.Chrome.code_sign_clone")
    #expect(BrowserService().cloneRoot.deletingLastPathComponent().lastPathComponent == "X")
    #expect(BrowserService().cloneRoot.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == LocalFiles.userTemporaryDirectory.deletingLastPathComponent().standardizedFileURL)
}

@Test func emptyDockerInventoryIsValidButMissingFieldsAreNot() throws {
    let report = try DockerService.parse(summary: Data(dockerSummary.utf8), detail: Data("{\"Images\":null,\"BuildCache\":null}".utf8))
    #expect(report.items.isEmpty)
    #expect(throws: (any Error).self) { try DockerService.parse(summary: Data(dockerSummary.utf8), detail: Data("{}".utf8)) }
}

@Test func usageMatchesMappedFilesAndExecutablesWithAliasesAndPathBoundaries() throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let file = try fixture.file("copy/Framework/Versions/1/library\nwith-space")
    let root = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let alias = fixture.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    let paths: [Int32: String] = [42: alias.appendingPathComponent("Chrome").path, 44: root.path + "-other/Chrome"]
    let output = "p43\0\nftxt\0n\(file.path)\0\n"
    // lsof may return 1 with valid matches; mapped libraries still protect the copy.
    let evidence = UsageInspector.parseOpenFiles(response(output, code: 1), executables: paths)
    #expect(evidence.complete)
    #expect(evidence.users(of: root) == [42, 43])
    #expect(!evidence.eligibility(for: root).canClean)
    let processes = try UsageInspector.parseProcesses(" 42 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome\n 43 /usr/bin/xcodebuild\n")
    #expect(processes[42]?.contains("Google Chrome.app") == true)
    #expect(UsageEvidence(executablePaths: processes).buildToolsRunning)
}

@Test func incompleteProcessAndOpenFileChecksNeverClaimUnused() async throws {
    let root = URL(fileURLWithPath: "/fixture/copy")
    for result in [response("lsof: permission denied\n", code: 1), response("p42"),
                   response("p42\0\nfNOFD\0\n"), response("p42\0\nftxt\0\n"),
                   response("p42\0\nn/fixture/copy/file\0\n"), response(code: 2)] {
        let evidence = UsageInspector.parseOpenFiles(result, executables: [:])
        #expect(!evidence.complete)
        #expect(!evidence.eligibility(for: root).canClean)
    }
    #expect(UsageInspector.parseOpenFiles(response(code: 1), executables: [:]).complete)
    let runner = Runner([response(" 42 /Applications/Chrome\n"), response("lsof: denied", code: 1)])
    #expect(!(await UsageInspector(runner: runner).inspect(root)).eligibility(for: root).canClean)
    let failedPS = Runner([response("permission denied", code: 1)])
    #expect(!(await UsageInspector(runner: failedPS).inspect(root)).complete)
    #expect(await failedPS.commands.count == 1)
}

@Test func chromeRequires24HoursVerifiedUseAndFreshChecks() async throws {
    for mode in 0...2 {
        let fixture = try Fixture(); defer { fixture.remove() }
        let id = "code_sign_clone.abcdef"
        let clone = try makeClone(fixture, id: id, age: (mode == 0 ? 13 : 25) * 3600)
        let usage: any UsageInspecting = mode == 2 ? ChangingUsage() : Usage(evidence: UsageEvidence(complete: mode != 1))
        let service = BrowserService(cloneRoot: clone.deletingLastPathComponent(), cacheRoot: fixture.root.appendingPathComponent("Caches"), usage: usage)
        await #expect(throws: (any Error).self) { try await service.clean(ids: [id]) }
        #expect(FileManager.default.fileExists(atPath: clone.path))
    }
}

@Test func dockerAllowsOldUnusedTaggedImagesButKeepsRecentAndBuilderReferencedImages() throws {
    let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    for tagged in [false, true] {
        let report = try DockerService.parse(summary: Data(dockerSummary.utf8), detail: Data(dockerDetail(tagged: tagged).utf8), now: fixedNow)
        let item = try #require(report.items.first)
        #expect(!item.inUse) // Same no-container definition as Docker Desktop, independent of cleanup policy.
        #expect(item.eligibility.canClean)
        #expect(item.uniqueBytes == 1_000_000_000)
        #expect(item.sharedBytes == 3_000_000_000)
        #expect(report.imageBytes == 4_000_000_000)
        #expect(report.cacheBytes == 3_000_000_000)
        #expect(report.reclaimableImageBytes == 2_000_000_000)
    }
    var object = try #require(JSONSerialization.jsonObject(with: Data(dockerDetail().utf8)) as? [String: Any])
    var images = try #require(object["Images"] as? [[String: Any]])
    var tagged = images[0]; tagged["Repository"] = "active-project"; tagged["Tag"] = "latest"
    images.append(tagged); object["Images"] = images
    var report = try DockerService.parse(summary: Data(dockerSummary.utf8), detail: JSONSerialization.data(withJSONObject: object), now: fixedNow)
    #expect(report.items.count == 1)
    #expect(report.candidateCount == 1)
    object["Images"] = [images[0]]
    object["BuildCache"] = [["ID": "building", "Size": "1GB", "InUse": "true"]]
    report = try DockerService.parse(summary: Data(dockerSummary.utf8), detail: JSONSerialization.data(withJSONObject: object), now: fixedNow)
    #expect(report.candidateCount == 0)
    #expect(report.items.first(where: { $0.kind == .image })?.eligibility == .protected("Builder in use"))
    object["BuildCache"] = [["ID": "cached", "Size": "1GB", "InUse": "false"]]
    images[0]["CreatedAt"] = "2026-01-01 00:00:00 +0000 UTC"
    object["Images"] = [images[0]]
    report = try DockerService.parse(summary: Data(dockerSummary.utf8), detail: JSONSerialization.data(withJSONObject: object), now: try #require(DockerService.parseDate("2026-01-01 12:00:00 +0000 UTC")))
    #expect(report.candidateCount == 0)
    #expect(report.items.first(where: { $0.kind == .buildCache })?.eligibility == .protected("Project ownership unknown"))
}

@Test func dockerEnumeratesAllAliasesButCountsEachImageOnce() async throws {
    let tags = ["registry.example/project:old", "cdkasset-old:latest"]
    let runner = Runner(dockerLoad(tags: tags))
    let report = try await DockerService(executable: "/fixture/docker", socket: "/fixture/docker.sock", runner: runner).load()
    #expect(report.items.count == 1)
    #expect(report.candidateCount == 1)
    #expect(report.items[0].references.tags == tags.sorted())
    #expect(report.items[0].name.contains("cdkasset-old:latest"))
    #expect(report.items[0].bytes == 4_000_000_000)
    #expect(report.imageBytes == 4_000_000_000)
    #expect(await runner.commands.last?.arguments.contains("inspect") == true)
}

@Test func dockerRemovesVerifiedAliasesThenTheImageWithoutForceOrParentPruning() async throws {
    let tags = ["a:old", "b:old"]
    let digests = ["a@" + imageID, "b@" + imageID]
    let initial = dockerLoad(tags: tags, digests: digests)
    let runner = Runner(initial + initial + [dockerReferences(tags: tags, digests: digests), response("Untagged: a:old")]
                        + dockerLoad(tags: ["b:old"], digests: ["b@" + imageID]) + [response("Deleted: " + imageID)] + emptyDockerLoad)
    let service = DockerService(executable: "/fixture/docker", socket: "/fixture/docker.sock", runner: runner)
    _ = try await service.removeImages(ids: [imageID, imageID])
    let removals = await runner.commands.filter { $0.arguments.contains("rm") }
    #expect(removals.map { $0.arguments.last! } == ["a:old", imageID])
    #expect(removals.allSatisfy { $0.arguments.contains("--no-prune") && !$0.arguments.contains("--force") && !$0.arguments.contains("-f") })
}

@Test func dockerStopsForNewUsersNewTagsRetaggingAndFailedChecks() async throws {
    let tags = ["a:old", "b:old"]
    for mode in 0...3 {
        var sequence = dockerLoad(tags: tags)
        switch mode {
        case 0: sequence += dockerLoad(containers: 1, tags: tags)
        case 1: sequence += dockerLoad(tags: tags + ["new:latest"])
        case 2: sequence += dockerLoad(tags: tags) + [dockerReferences(tags: ["a:old"], id: "sha256:" + String(repeating: "b", count: 64))]
        default: sequence += [response("Docker unavailable", code: 1)]
        }
        let runner = Runner(sequence)
        let service = DockerService(executable: "/fixture/docker", socket: "/fixture/docker.sock", runner: runner)
        await #expect(throws: (any Error).self) { try await service.removeImages(ids: [imageID]) }
        #expect(await runner.commands.allSatisfy { !$0.arguments.contains("rm") })
    }
}

@Test func dockerStopsAfterPartialUntaggingIfAContainerStartsOrAnEngineConflictOccurs() async throws {
    let tags = ["a:old", "b:old"]
    let initial = dockerLoad(tags: tags)
    for conflict in [false, true] {
        let sequence = initial + initial + [dockerReferences(tags: tags), response("untag result", code: conflict ? 1 : 0)]
            + (conflict ? [] : dockerLoad(containers: 1, tags: ["b:old"]))
        let runner = Runner(sequence)
        let service = DockerService(executable: "/fixture/docker", socket: "/fixture/docker.sock", runner: runner)
        await #expect(throws: (any Error).self) { try await service.removeImages(ids: [imageID]) }
        #expect(await runner.commands.filter { $0.arguments.contains("rm") }.count == 1)
        #expect(await runner.commands.allSatisfy { !$0.arguments.contains("--force") })
    }
}

@Test func dockerReferenceInspectionRejectsMissingMalformedAndFlagShapedValues() throws {
    for value in ["--force", "repo:tag\n", "repo:tag;anything", "", "repo:tag with spaces"] {
        #expect(!DockerService.validImageReference(value))
        #expect(throws: (any Error).self) { try DockerService.parseReferences(dockerReferences(tags: [value]).output) }
    }
    for value in ["registry.example:5000/project/image:old", "image:latest", "registry/project@" + imageID] {
        #expect(DockerService.validImageReference(value))
    }
    #expect(throws: (any Error).self) { try DockerService.parseReferences(Data(#"{"ID":"invalid","RepoTags":[],"RepoDigests":[]}"#.utf8)) }
    #expect(throws: (any Error).self) { try DockerService.parseReferences(Data("{}".utf8)) }
    #expect(throws: (any Error).self) { try DockerService.parseReferences(Data()) }
}

@Test func repositoryInspectionProtectsRegisteredExternalAndMissingWorktrees() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    _ = try fixture.file("repos/main/.git/HEAD")
    _ = try fixture.file("repos/.DS_Store")
    let outside = fixture.root.appendingPathComponent("outside worktree")
    let main = fixture.root.appendingPathComponent("repos/main")
    let listing = "worktree \(main.path)\0HEAD abc\0branch refs/heads/main\0\0worktree \(outside.path)\0HEAD def\0detached\0prunable missing\0\0"
    let runner = Runner([response(listing)])
    let inventory = await RepositoryInspector(root: fixture.root.appendingPathComponent("repos"), runner: runner).inventory()
    #expect(inventory.complete)
    #expect(inventory.owner(of: outside.appendingPathComponent("Project.xcodeproj")) != nil)
    #expect(inventory.owner(of: URL(fileURLWithPath: outside.path + "-other/Project.xcodeproj")) == nil)
    #expect(await runner.commands.count == 1)
    let failed = await RepositoryInspector(root: fixture.root.appendingPathComponent("repos"), runner: Runner([response("failed", code: 1)])).inventory()
    #expect(!failed.complete)
    #expect(failed.owner(of: main.appendingPathComponent("Project.xcodeproj")) != nil)
    #expect(throws: (any Error).self) { try RepositoryInspector.parseWorktrees("worktree /somewhere\n") }
}

private actor ChangingRepositories: RepositoriesInspecting {
    let workspace: URL
    var calls = 0
    init(_ workspace: URL) { self.workspace = workspace }
    func inventory() async -> RepositoryInventory {
        calls += 1
        return RepositoryInventory(roots: calls < 3 ? [] : [workspace.deletingLastPathComponent()])
    }
}

@Test func xcodeProtectsNewlyRegisteredWorktreeBeforeRemoving() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let owner = fixture.root.appendingPathComponent("removed/Example.xcodeproj")
    let output = try makeProject(fixture, owner: owner.path)
    let service = XcodeService(root: fixture.root.appendingPathComponent("DerivedData"), usage: Usage(), repositories: ChangingRepositories(owner))
    await #expect(throws: (any Error).self) { try await service.clean(ids: ["Example"]) }
    #expect(FileManager.default.fileExists(atPath: output.path))
}

@Test func privateFileBytesExcludeAPFSClonesAndMultiplyLinkedFiles() throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let original = try fixture.file("data/original", data: Data(repeating: 3, count: 1_048_576))
    let beforeCloning = try #require(LocalFiles.privateFileBytes(original))
    #expect(beforeCloning > 0)
    let clone = fixture.root.appendingPathComponent("data/clone")
    #expect(Darwin.clonefile(original.path, clone.path, 0) == 0)
    let measured = try LocalFiles.measurement(clone.deletingLastPathComponent())
    let privateBytes = try #require(measured.privateBytes)
    #expect(measured.bytes >= 2_097_152)
    #expect(privateBytes < measured.bytes) // Shared extents must not be counted twice as private data.
    #expect(LocalFiles.privateFileBytes(fixture.root.appendingPathComponent("missing")) == nil)
    let linked = try fixture.file("linked/file")
    try FileManager.default.linkItem(at: linked, to: fixture.root.appendingPathComponent("outside-link"))
    #expect(try LocalFiles.measurement(linked.deletingLastPathComponent()).privateBytes == 0)
}
