import Foundation

public enum BackupMode: String, Sendable, Identifiable {
    case manual, automatic
    public var id: String { rawValue }

    public static func parse(_ value: String) throws -> BackupMode {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "0": return .manual
        case "1": return .automatic
        default: throw BackupSettingsError.unreadable
        }
    }
}

public enum BackupSettingsError: LocalizedError {
    case unreadable, notVerified

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            "Reclaim could not read macOS’s automatic-backup setting. Check Backup Frequency in Time Machine settings."
        case .notVerified:
            "macOS has not reported the requested backup mode. Check Backup Frequency in Time Machine settings."
        }
    }
}

/// A shortcut to macOS's automatic-backup setting, not a Reclaim backup scheduler.
public struct BackupSettingsService: Sendable {
    private let runner: any CommandRunning
    private let pause: @Sendable () async throws -> Void

    public init(runner: any CommandRunning = ProcessRunner(),
                pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(500)) }) {
        self.runner = runner
        self.pause = pause
    }

    public static let readCommand = Command(executable: "/usr/bin/defaults", arguments: [
        "read", "/Library/Preferences/com.apple.TimeMachine", "AutoBackup"
    ], timeoutSeconds: 10)

    public func readMode() async throws -> BackupMode {
        // Read only the system-wide key, never a per-user default or the destination
        // list. This preference is not a stable public API: missing, denied or
        // unfamiliar output must stay unknown, never default to manual mode.
        let result = try await runner.run(Self.readCommand).checked()
        return try BackupMode.parse(result.text)
    }

    public static func changeCommand(to mode: BackupMode) -> Command {
        // tmutil is the supported writer. Do not edit the preferences file or
        // accept arbitrary verbs, paths, destinations or user-provided shell text.
        let command = Command(executable: "/usr/bin/tmutil", arguments: [mode == .manual ? "disable" : "enable"])
        return Command(executable: "/usr/bin/osascript", arguments: [
            "-e", "do shell script \"\(command.shellString)\" with administrator privileges"
        ])
    }

    public func setMode(_ mode: BackupMode) async throws {
        // Recheck after confirmation; a change in System Settings may already
        // have applied the requested mode. Unknown state never authorizes a write.
        guard try await readMode() != mode else { return }
        _ = try await runner.run(Self.changeCommand(to: mode)).checked()
        for attempt in 0..<5 {
            if attempt > 0 { try await pause() }
            if try await readMode() == mode { return }
        }
        throw BackupSettingsError.notVerified
    }
}
