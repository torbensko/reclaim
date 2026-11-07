import Foundation
import Testing
@testable import ReclaimCore

private actor SettingsRunner: CommandRunning {
    var replies: [CommandResult]
    private(set) var commands: [Command] = []
    init(_ replies: [CommandResult]) { self.replies = replies }
    func run(_ command: Command) async throws -> CommandResult {
        commands.append(command)
        guard !replies.isEmpty else { throw BackupSettingsError.unreadable }
        return replies.removeFirst()
    }
}

private func reply(_ text: String, exit: Int32 = 0) -> CommandResult {
    CommandResult(output: Data(text.utf8), exitCode: exit)
}

@Test func backupModeRequiresAnExplicitSystemBoolean() throws {
    #expect(try BackupMode.parse("0\n") == .manual)
    #expect(try BackupMode.parse("1\n") == .automatic)
    for value in ["", "2", "false", "Unknown", "Operation not permitted", "0\nwarning"] {
        #expect(throws: BackupSettingsError.self) { try BackupMode.parse(value) }
    }
}

@Test func backupSettingUsesOnlyTheGlobalKeyAndSupportedAuthorizedVerbs() async throws {
    for target in [BackupMode.manual, .automatic] {
        let old = target == .manual ? "1" : "0"
        let new = target == .manual ? "0" : "1"
        let runner = SettingsRunner([reply(old), reply(""), reply(old), reply(new)])
        let service = BackupSettingsService(runner: runner, pause: {})
        try await service.setMode(target)
        let commands = await runner.commands
        #expect(commands.count == 4)
        let read = Command(executable: "/usr/bin/defaults", arguments: [
            "read", "/Library/Preferences/com.apple.TimeMachine", "AutoBackup"
        ], timeoutSeconds: 10)
        #expect(commands[0] == read)
        #expect(commands[2] == read)
        #expect(commands[3] == read)
        let verb = target == .manual ? "disable" : "enable"
        #expect(commands[1] == Command(executable: "/usr/bin/osascript", arguments: [
            "-e", "do shell script \"'/usr/bin/tmutil' '\(verb)'\" with administrator privileges"
        ]))
    }
}

@Test func alreadyChangedBackupSettingNeedsNoAuthorization() async throws {
    let runner = SettingsRunner([reply("0")])
    try await BackupSettingsService(runner: runner).setMode(.manual)
    #expect(await runner.commands == [BackupSettingsService.readCommand])
}

@Test func unknownOrUnreadableBackupSettingNeverWrites() async {
    for output in [reply(""), reply("0", exit: 1), reply("Permission denied", exit: 1)] {
        let runner = SettingsRunner([output])
        await #expect(throws: (any Error).self) {
            try await BackupSettingsService(runner: runner).setMode(.manual)
        }
        #expect(await runner.commands == [BackupSettingsService.readCommand])
    }
}

@Test func backupSettingAuthorizationCancellationAndDenialStopTheOperation() async {
    for output in [reply("User canceled. (-128)", exit: 1), reply("Full Disk Access is required", exit: 1)] {
        let runner = SettingsRunner([reply("1"), output])
        do {
            try await BackupSettingsService(runner: runner).setMode(.manual)
            Issue.record("Expected authorization failure")
        } catch SnapshotError.cancelled {
            #expect(output.text.contains("(-128)"))
        } catch {
            #expect(!output.text.contains("(-128)"))
        }
        #expect(await runner.commands.count == 2)
    }
}

@Test func successfulCommandWithoutMatchingReadbackIsNotSuccess() async {
    let runner = SettingsRunner([reply("1"), reply("")] + Array(repeating: reply("1"), count: 5))
    await #expect(throws: BackupSettingsError.self) {
        try await BackupSettingsService(runner: runner, pause: {}).setMode(.manual)
    }
    #expect(await runner.commands.count == 7)
    let denied = SettingsRunner([reply("1"), reply(""), reply("Permission denied", exit: 1)])
    await #expect(throws: (any Error).self) {
        try await BackupSettingsService(runner: denied, pause: {}).setMode(.manual)
    }
}
