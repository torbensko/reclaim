import Foundation
import Testing
@testable import ReclaimCore

private let localName = "com.apple.TimeMachine.2026-10-20-212512.local"
private let secondName = "com.apple.TimeMachine.2026-10-20-202512.local"

private func plist(_ value: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
}

private func volumeData(internalDisk: Bool = true, mount: String = SnapshotCommands.localVolume) throws -> Data {
    try plist([
        "Internal": internalDisk, "FilesystemType": "apfs", "MountPoint": mount,
        "VolumeName": "Macintosh HD - Data",
        "APFSContainerSize": Int64(1_000_000_000_000),
        "APFSContainerFree": Int64(5_000_000_000),
        // FreeSpace is often zero on APFS; use the container's actual free bytes.
        "FreeSpace": 0
    ])
}

private func snapshotData(_ names: [String]) throws -> Data {
    try plist(["Snapshots": names.map { ["SnapshotName": $0, "Purgeable": true] as [String: Any] }])
}

private actor MockRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var commands: [Command] = []

    init(_ results: [CommandResult]) { self.results = results }

    func run(_ command: Command) async throws -> CommandResult {
        commands.append(command)
        guard !results.isEmpty else { throw SnapshotError.commandFailed("Unexpected command", 99) }
        return results.removeFirst()
    }
}

private func success(_ data: Data) -> CommandResult { CommandResult(output: data, exitCode: 0) }

@Test func recognizesOnlyStrictLocalTimeMachineNames() {
    #expect(Snapshot(name: localName).canDelete)
    #expect(Snapshot(name: localName).timestamp == "2026-10-20-212512")
    for name in [
        "com.apple.os.update-MSUPrepareUpdate",
        "com.apple.TimeMachine.2026-10-20-212512.backup",
        "com.apple.TimeMachine.2026-02-30-212512.local",
        "com.apple.TimeMachine.2026-10-20-252512.local",
        "com.apple.TimeMachine.2026-10-20-212512.local; touch /tmp/injected",
        localName + "\n", "unrecognized"
    ] {
        #expect(!Snapshot(name: name).canDelete)
    }
    #expect(Snapshot.isValidTimestamp("2024-02-29-120000"))
    #expect(!Snapshot.isValidTimestamp("2025-02-29-120000"))
}

@Test func parsesAPFSMetadataAndDeduplicates() throws {
    let data = try plist(["Snapshots": [
        ["SnapshotName": localName, "Purgeable": true],
        ["SnapshotName": secondName, "Purgeable": false],
        ["SnapshotName": localName, "Purgeable": true]
    ]])
    let snapshots = try SnapshotParser.parseAPFS(data)
    #expect(snapshots.count == 2)
    #expect(snapshots[0].name == localName)
    #expect(snapshots[0].purgeable == true)
    #expect(snapshots[1].purgeable == false)
    #expect(try SnapshotParser.parseAPFS(snapshotData([])).isEmpty)
}

@Test func malformedOutputIsNotMistakenForNoSnapshots() throws {
    #expect(throws: (any Error).self) {
        try SnapshotParser.parseAPFS(Data("Operation not permitted".utf8))
    }
    #expect(throws: (any Error).self) {
        try SnapshotParser.parseAPFS(plist(["Unexpected": []]))
    }
    #expect(throws: (any Error).self) {
        try SnapshotParser.parseAPFS(plist(["Snapshots": [["Purgeable": true]]]))
    }
}

@Test func separatesPhysicalFreeFromAvailableEstimate() throws {
    let storage = try StorageInfo.parse(volumeData(), availableBytes: 125_000_000_000)
    #expect(storage.freeBytes == 5_000_000_000)
    #expect(storage.availableBytes == 125_000_000_000)
    #expect(storage.usedFraction == 0.995)
    #expect(throws: (any Error).self) {
        try StorageInfo.parse(plist(["APFSContainerSize": 10, "APFSContainerFree": 20]))
    }
}

@Test func refusesExternalAndUnexpectedVolumes() throws {
    try StorageInfo.validateLocalVolume(volumeData())
    #expect(throws: (any Error).self) {
        try StorageInfo.validateLocalVolume(volumeData(internalDisk: false))
    }
    #expect(throws: (any Error).self) {
        try StorageInfo.validateLocalVolume(volumeData(mount: "/Volumes/Backup"))
    }
}

@Test func commandsCannotTargetExternalOrSystemSnapshots() throws {
    let commands = try SnapshotCommands.commands(for: .delete(names: [localName, localName]))
    #expect(commands == [Command(executable: "/usr/sbin/diskutil", arguments: [
        "apfs", "deleteSnapshot", "/System/Volumes/Data", "-name", localName
    ])])
    #expect(throws: (any Error).self) {
        try SnapshotCommands.commands(for: .delete(names: ["com.apple.os.update-MSUPrepareUpdate"]))
    }
    #expect(throws: (any Error).self) {
        try SnapshotCommands.commands(for: .delete(names: []))
    }
    let script = try SnapshotCommands.authorizationScript(for: .delete(names: [localName, secondName]))
    #expect(script.contains(" && "))
    #expect(script.hasSuffix("with administrator privileges"))
    #expect(!script.contains("deletelocalsnapshots"))
    #expect(!script.contains("/Volumes/Backup"))
}

@Test func reclaimUsesDecimalGBAndFixedLocalVolume() throws {
    let commands = try SnapshotCommands.commands(for: .reclaim(gigabytes: 25, urgency: 4))
    #expect(commands == [Command(executable: "/usr/bin/tmutil", arguments: [
        "thinlocalsnapshots", "/System/Volumes/Data", "25000000000", "4"
    ])])
    for action in [
        SnapshotAction.reclaim(gigabytes: 0, urgency: 1),
        .reclaim(gigabytes: 1_001, urgency: 1),
        .reclaim(gigabytes: 25, urgency: 0),
        .reclaim(gigabytes: 25, urgency: 5)
    ] {
        #expect(throws: (any Error).self) { try SnapshotCommands.commands(for: action) }
    }
}

@Test func shellQuotingPreservesLiteralMetacharacters() async throws {
    let literal = "a'b\"c $(printf injected); `printf injected` \n end"
    let command = Command(executable: "/bin/sh", arguments: [
        "-c", "printf '%s' \(Command.shellQuote(literal))"
    ])
    let result = try await ProcessRunner().run(command).checked()
    #expect(result.text == literal)
}

@Test func drainsLargeProcessOutputWithoutDeadlocking() async throws {
    let result = try await ProcessRunner().run(Command(executable: "/usr/bin/seq", arguments: ["1", "50000"])).checked()
    #expect(result.text.hasPrefix("1\n2\n"))
    #expect(result.text.hasSuffix("50000\n"))
    #expect(result.output.count > 200_000)
}

@Test func liveReportFiltersSystemAndBackupEntries() async throws {
    let runner = MockRunner([
        success(try volumeData()),
        success(try snapshotData([
            localName,
            "com.apple.os.update-MSUPrepareUpdate",
            "com.apple.TimeMachine.2026-10-20-212512.backup"
        ]))
    ])
    let report = try await SnapshotService(runner: runner).load()
    #expect(report.snapshots.map(\.name) == [localName])
    let commands = await runner.commands
    #expect(commands == [SnapshotCommands.storage, SnapshotCommands.list])
}

@Test func externalStartupIsRejectedBeforeListingOrPurging() async throws {
    for perform in [true, false] {
        let runner = MockRunner([success(try volumeData(internalDisk: false))])
        let service = SnapshotService(runner: runner)
        await #expect(throws: (any Error).self) {
            if perform { _ = try await service.perform(.reclaim(gigabytes: 25, urgency: 1)) }
            else { _ = try await service.load() }
        }
        #expect(await runner.commands == [SnapshotCommands.storage])
    }
}

@Test func staleSelectionNeverRequestsAuthorization() async throws {
    let runner = MockRunner([success(try volumeData()), success(try snapshotData([]))])
    do {
        _ = try await SnapshotService(runner: runner).perform(.delete(names: [localName]))
        Issue.record("Expected stale selection rejection")
    } catch SnapshotError.staleSelection {
        #expect(await runner.commands == [SnapshotCommands.storage, SnapshotCommands.list])
    }
}

@Test func selectedDeletionRevalidatesBeforeAuthorization() async throws {
    let runner = MockRunner([
        success(try volumeData()), success(try snapshotData([localName])),
        success(Data("Finished APFS operation\n".utf8))
    ])
    let output = try await SnapshotService(runner: runner).perform(.delete(names: [localName]))
    #expect(output == "Finished APFS operation\n")
    let commands = await runner.commands
    #expect(commands.count == 3)
    #expect(commands[2].executable == "/usr/bin/osascript")
    let expectedScript = try SnapshotCommands.authorizationScript(for: .delete(names: [localName]))
    #expect(commands[2].arguments[1] == expectedScript)
}

@Test func cancellationIsNotReportedAsSuccess() async throws {
    let runner = MockRunner([
        success(try volumeData()),
        CommandResult(output: Data("execution error: User canceled. (-128)".utf8), exitCode: 1)
    ])
    do {
        _ = try await SnapshotService(runner: runner).perform(.reclaim(gigabytes: 25, urgency: 1))
        Issue.record("Expected cancellation")
    } catch SnapshotError.cancelled {
        #expect(await runner.commands.count == 2)
    }
}

@Test func invalidSelectionNeverRunsACommand() async {
    let runner = MockRunner([])
    await #expect(throws: (any Error).self) {
        try await SnapshotService(runner: runner).perform(.delete(names: ["$(malicious)"]))
    }
    #expect(await runner.commands.isEmpty)
}

@Test func permissionFailurePreservesDiagnostic() throws {
    let result = CommandResult(output: Data("Operation not permitted".utf8), exitCode: 77)
    do {
        _ = try result.checked()
        Issue.record("Expected permission failure")
    } catch {
        #expect(error.localizedDescription.contains("Operation not permitted"))
        #expect(error.localizedDescription.contains("77"))
    }
}
