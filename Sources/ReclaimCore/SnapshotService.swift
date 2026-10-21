import Foundation

public struct StorageInfo: Sendable {
    public let volumeName: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let availableBytes: Int64?
    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(totalBytes - freeBytes) / Double(totalBytes)))
    }

    public init(volumeName: String, totalBytes: Int64, freeBytes: Int64, availableBytes: Int64?) {
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.availableBytes = availableBytes
    }

    public static func parse(_ data: Data, availableBytes: Int64? = nil) throws -> StorageInfo {
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let info = plist as? [String: Any],
              let total = (info["APFSContainerSize"] as? NSNumber)?.int64Value,
              let free = (info["APFSContainerFree"] as? NSNumber)?.int64Value,
              total > 0, free >= 0, free <= total else {
            throw SnapshotError.unrecognizedOutput
        }
        return StorageInfo(
            volumeName: info["VolumeName"] as? String ?? "Startup disk",
            totalBytes: total,
            freeBytes: free,
            availableBytes: availableBytes
        )
    }

    public static func validateLocalVolume(_ data: Data) throws {
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let info = plist as? [String: Any],
              info["Internal"] as? Bool == true,
              info["FilesystemType"] as? String == "apfs",
              info["MountPoint"] as? String == SnapshotCommands.localVolume else {
            throw SnapshotError.unsupportedVolume
        }
    }
}

public struct SnapshotReport: Sendable {
    public let snapshots: [Snapshot]
    public let storage: StorageInfo?
    public let notices: [String]
    public let refreshedAt: Date

    public init(snapshots: [Snapshot], storage: StorageInfo?, notices: [String] = [], refreshedAt: Date = .now) {
        self.snapshots = snapshots
        self.storage = storage
        self.notices = notices
        self.refreshedAt = refreshedAt
    }
}

public struct SnapshotService: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func list() async throws -> [Snapshot] {
        let result = try await runner.run(SnapshotCommands.list).checked()
        return try SnapshotParser.parseAPFS(result.output).filter(\.canDelete)
    }

    public func load() async throws -> SnapshotReport {
        let volumeResult = try await runner.run(SnapshotCommands.storage).checked()
        try StorageInfo.validateLocalVolume(volumeResult.output)
        async let snapshotsTask = list()
        async let storageTask = loadStorage(from: volumeResult.output)
        let snapshots = try await snapshotsTask
        let (storage, storageNotice) = await storageTask
        return SnapshotReport(
            snapshots: snapshots,
            storage: storage,
            notices: [storageNotice].compactMap { $0 }
        )
    }

    public func perform(_ action: SnapshotAction) async throws -> String {
        // Validate before querying the OS, then recheck that selected names still exist.
        let script = try SnapshotCommands.authorizationScript(for: action)
        let volumeResult = try await runner.run(SnapshotCommands.storage).checked()
        try StorageInfo.validateLocalVolume(volumeResult.output)
        if case let .delete(names) = action {
            let currentNames = Set(try await list().filter(\.canDelete).map(\.name))
            guard Set(names).isSubset(of: currentNames) else { throw SnapshotError.staleSelection }
        }
        let command = Command(executable: "/usr/bin/osascript", arguments: ["-e", script])
        return try await runner.run(command).checked().text
    }

    private func loadStorage(from data: Data) async -> (StorageInfo?, String?) {
        do {
            let values = try? URL(fileURLWithPath: SnapshotCommands.localVolume)
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return (try StorageInfo.parse(
                data,
                availableBytes: values?.volumeAvailableCapacityForImportantUsage
            ), nil)
        } catch {
            return (nil, "Storage figures are unavailable. \(error.localizedDescription)")
        }
    }

}
