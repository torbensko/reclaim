import Foundation

public struct Snapshot: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case timeMachine = "Time Machine"
        case system = "macOS update"
        case other = "Other snapshot"
    }

    public let name: String
    public var id: String { name }
    public let timestamp: String?
    public let kind: Kind
    public let purgeable: Bool?
    public var canDelete: Bool { kind == .timeMachine && timestamp != nil }

    public init(name: String, purgeable: Bool? = nil) {
        self.name = name
        self.purgeable = purgeable
        let pattern = #"^com\.apple\.TimeMachine\.(\d{4}-\d{2}-\d{2}-\d{6})\.local$"#
        if let match = name.range(of: pattern, options: .regularExpression),
           match == name.startIndex..<name.endIndex {
            let value = String(name[match])
                .replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
                .replacingOccurrences(of: ".local", with: "")
            if Self.isValidTimestamp(value) {
                timestamp = value
                kind = .timeMachine
                return
            }
        }
        timestamp = nil
        kind = name.hasPrefix("com.apple.os.update") ? .system : .other
    }

    public var date: Date? {
        guard let timestamp else { return nil }
        return Self.dateFormatter(timeZone: .current).date(from: timestamp)
    }

    public static func isValidTimestamp(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#, options: .regularExpression) != nil else {
            return false
        }
        // UTC validation avoids rejecting a valid filename because of a local DST gap.
        let formatter = dateFormatter(timeZone: TimeZone(secondsFromGMT: 0)!)
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    private static func dateFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.isLenient = false
        return formatter
    }
}

public enum SnapshotParser {
    /// The caller supplies only the startup Data volume, never a backup destination.
    public static func parseAPFS(_ data: Data) throws -> [Snapshot] {
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = plist as? [String: Any],
              let snapshots = dictionary["Snapshots"] as? [[String: Any]] else {
            throw SnapshotError.unrecognizedOutput
        }
        var seen = Set<String>()
        return try snapshots.compactMap { item -> Snapshot? in
            guard let name = item["SnapshotName"] as? String else { throw SnapshotError.unrecognizedOutput }
            guard seen.insert(name).inserted else { return nil }
            return Snapshot(name: name, purgeable: item["Purgeable"] as? Bool)
        }.sorted { $0.name > $1.name }
    }

}

public enum SnapshotError: LocalizedError, Sendable {
    case unrecognizedOutput
    case invalidSelection
    case invalidReclaimAmount
    case commandFailed(String, Int32)
    case cancelled
    case staleSelection
    case unsupportedVolume

    public var errorDescription: String? {
        switch self {
        case .unrecognizedOutput:
            return "macOS returned a response this app could not read. Refresh to try again."
        case .invalidSelection:
            return "Only recognized Time Machine local snapshots can be deleted."
        case .invalidReclaimAmount:
            return "Choose a reclaim target between 1 and 1,000 GB and an urgency from 1 to 4."
        case let .commandFailed(output, code):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "macOS could not complete the request (exit \(code)).\n\(detail)"
        case .cancelled:
            return "Authorization was cancelled. No command was started."
        case .staleSelection:
            return "The selected snapshots have changed since the last refresh. Review the current list and try again."
        case .unsupportedVolume:
            return "This app requires an APFS startup Data volume on the internal disk. External disks are outside its scope."
        }
    }
}
