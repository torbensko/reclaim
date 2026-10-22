import Foundation

public struct Command: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let unsetEnvironment: [String]
    public let timeoutSeconds: TimeInterval?

    public init(executable: String, arguments: [String], unsetEnvironment: [String] = [], timeoutSeconds: TimeInterval? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.unsetEnvironment = unsetEnvironment
        self.timeoutSeconds = timeoutSeconds
    }

    public var shellString: String {
        ([executable] + arguments).map(Self.shellQuote).joined(separator: " ")
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum SnapshotAction: Equatable, Sendable {
    case reclaim(gigabytes: Int, urgency: Int)
    case delete(names: [String])

    public var title: String {
        switch self {
        case .reclaim: return "Ask macOS to reclaim space?"
        case let .delete(names): return "Delete \(names.count) local snapshot\(names.count == 1 ? "" : "s")?"
        }
    }

    public var confirmation: String {
        switch self {
        case let .reclaim(gigabytes, _):
            return """
            macOS will try to free \(gigabytes) GB from local Time Machine snapshots on your internal Data volume. \
            It chooses which restore points to remove and may free less than requested.

            Removed restore points cannot be recovered. Your current files and backups on your Time Machine backup disk are kept.
            """
        case let .delete(names):
            let dates = names.compactMap { Snapshot(name: $0).timestamp }.sorted()
            return """
            This permanently removes the local Time Machine restore points for the selected dates:

            \(dates.joined(separator: "\n"))

            Only snapshots on this Mac's internal Data volume are targeted. \
            Your current files and backups on your Time Machine backup disk are kept.
            """
        }
    }

    public var confirmLabel: String {
        switch self {
        case .reclaim: return "Reclaim Space"
        case .delete: return "Delete Snapshots"
        }
    }
}

public enum SnapshotCommands {
    public static let localVolume = "/System/Volumes/Data"
    public static let list = Command(
        executable: "/usr/sbin/diskutil",
        arguments: ["apfs", "listSnapshots", localVolume, "-plist"], timeoutSeconds: 30
    )
    public static let storage = Command(
        executable: "/usr/sbin/diskutil",
        arguments: ["info", "-plist", localVolume], timeoutSeconds: 30
    )

    public static func commands(for action: SnapshotAction) throws -> [Command] {
        switch action {
        case let .reclaim(gigabytes, urgency):
            guard (1...1_000).contains(gigabytes), (1...4).contains(urgency) else {
                throw SnapshotError.invalidReclaimAmount
            }
            return [Command(executable: "/usr/bin/tmutil", arguments: [
                "thinlocalsnapshots", localVolume, String(Int64(gigabytes) * 1_000_000_000), String(urgency)
            ])]
        case let .delete(names):
            guard !names.isEmpty, names.count <= 1_000 else { throw SnapshotError.invalidSelection }
            let snapshots = names.map { Snapshot(name: $0) }
            guard snapshots.allSatisfy(\.canDelete) else { throw SnapshotError.invalidSelection }
            return Set(snapshots.map(\.name)).sorted().map {
                Command(executable: "/usr/sbin/diskutil", arguments: [
                    "apfs", "deleteSnapshot", localVolume, "-name", $0
                ])
            }
        }
    }

    public static func authorizationScript(for action: SnapshotAction) throws -> String {
        // Only commands constructed by the allowlist above reach the elevated shell.
        // Stop on the first failure; completed deletions will be reflected by the next refresh.
        let shell = try commands(for: action).map(\.shellString).joined(separator: " && ")
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }
}

public struct CommandResult: Sendable {
    public let output: Data
    public let exitCode: Int32
    public var text: String { String(decoding: output, as: UTF8.self) }

    public init(output: Data, exitCode: Int32) {
        self.output = output
        self.exitCode = exitCode
    }

    public func checked() throws -> CommandResult {
        guard exitCode == 0 else {
            if text.contains("(-128)") { throw SnapshotError.cancelled }
            throw SnapshotError.commandFailed(text, exitCode)
        }
        return self
    }
}

public protocol CommandRunning: Sendable {
    func run(_ command: Command) async throws -> CommandResult
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ command: Command) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: command.executable)
                process.arguments = command.arguments
                // Drain a single stream continuously, so neither stdout nor stderr can deadlock.
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                var environment = ProcessInfo.processInfo.environment
                environment["LC_ALL"] = "C"
                environment["LANG"] = "C"
                for key in command.unsetEnvironment { environment.removeValue(forKey: key) }
                process.environment = environment
                do {
                    try process.run()
                    if let timeout = command.timeoutSeconds {
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                            if process.isRunning { process.terminate() }
                        }
                    }
                    try? pipe.fileHandleForWriting.close()
                    let output = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: CommandResult(output: output, exitCode: process.terminationStatus))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
