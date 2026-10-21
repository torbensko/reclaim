import Foundation

public struct DockerItem: Identifiable, Sendable {
    public enum Kind: String, Sendable { case image = "Image", buildCache = "Build cache" }
    public let id: String
    public let name: String
    public let bytes: Int64
    public let lastUsed: String
    public let inUse: Bool
    public let kind: Kind
    public let containerCount: Int?
    public let uniqueBytes: Int64?
    public let sharedBytes: Int64?
    public let eligibility: CleanupEligibility
}

public struct DockerReport: Sendable {
    public let items: [DockerItem]
    public let imageBytes: Int64
    public let cacheBytes: Int64
    public let reclaimableCacheBytes: Int64
    public var candidateCount: Int { items.filter { $0.eligibility.canClean }.count }
}

public struct DockerService: Sendable {
    public let executable: String
    public let socket: String
    private let runner: any CommandRunning

    public init(executable: String? = nil, socket: String? = nil, runner: any CommandRunning = ProcessRunner()) {
        self.executable = executable ?? ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/Applications/Docker.app/Contents/Resources/bin/docker"
        self.socket = socket ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker/run/docker.sock").path
        self.runner = runner
    }

    public func command(_ arguments: [String], timeout: TimeInterval? = nil) throws -> Command {
        guard socket.hasPrefix("/"), !socket.contains("\n") else { throw CleanupError.unsafePath }
        return Command(executable: executable, arguments: ["--host", "unix://" + socket] + arguments,
                       unsetEnvironment: ["DOCKER_CONTEXT", "DOCKER_HOST", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "BUILDX_BUILDER", "BUILDKIT_HOST"], timeoutSeconds: timeout)
    }

    public func load() async throws -> DockerReport {
        let summary = try await runner.run(command(["system", "df", "--format", "{{json .}}"], timeout: 30)).checked()
        let detail = try await runner.run(command(["system", "df", "--verbose", "--format", "{{json .}}"], timeout: 30)).checked()
        return try Self.parse(summary: summary.output, detail: detail.output)
    }

    public static func parse(summary: Data, detail: Data, now: Date = .now) throws -> DockerReport {
        guard let object = try JSONSerialization.jsonObject(with: detail) as? [String: Any] else { throw CleanupError.invalidResponse }
        func rows(_ key: String) throws -> [[String: Any]] {
            if object[key] is NSNull { return [] }
            guard let rows = object[key] as? [[String: Any]] else { throw CleanupError.invalidResponse }
            return rows
        }
        let images = try rows("Images")
        let caches = try rows("BuildCache")
        var imageBytes: Int64?
        var cacheBytes: Int64?
        var reclaimable: Int64?
        for line in String(decoding: summary, as: UTF8.self).split(separator: "\n") {
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let size = row["Size"] as? String else { throw CleanupError.invalidResponse }
            if row["Type"] as? String == "Images" { imageBytes = try parseSize(size) }
            if row["Type"] as? String == "Build Cache" {
                cacheBytes = try parseSize(size)
                guard let value = row["Reclaimable"] as? String else { throw CleanupError.invalidResponse }
                reclaimable = try parseSize(String(value.split(separator: " ").first ?? ""))
            }
        }
        var items: [DockerItem] = []
        // An image can have several tags. Merge every row before deciding eligibility.
        var grouped: [String: [[String: Any]]] = [:]
        for row in images {
            guard let id = row["ID"] as? String, validImageID(id) else { throw CleanupError.invalidResponse }
            grouped[id, default: []].append(row)
        }
        let builderBusy = caches.contains { $0["InUse"] as? String == "true" }
        for (id, rows) in grouped {
            guard let row = rows.first, let size = row["Size"] as? String else { throw CleanupError.invalidResponse }
            var containerCount = 0
            var tags: [String] = []
            for entry in rows {
                guard let countString = entry["Containers"] as? String, let count = Int(countString), count >= 0,
                      let repository = entry["Repository"] as? String, let tag = entry["Tag"] as? String else { throw CleanupError.invalidResponse }
                containerCount = max(containerCount, count)
                if repository != "<none>" || tag != "<none>" { tags.append("\(repository):\(tag)") }
            }
            let created = (row["CreatedAt"] as? String).flatMap(Self.parseDate)
            let decision: CleanupEligibility
            if containerCount > 0 { decision = .protected("Referenced by containers") }
            else if !tags.isEmpty { decision = .protected("Tagged image — kept") }
            else if builderBusy { decision = .protected("Builder in use") }
            else if let created {
                decision = now.timeIntervalSince(created) >= 24 * 3600 ? .candidate : .protected("Keep for 24 hours")
            } else { decision = .unknown("Docker did not report a usable creation time.") }
            items.append(DockerItem(id: id, name: tags.isEmpty ? "Untagged · \(id.prefix(19))" : Set(tags).sorted().joined(separator: ", "),
                                    bytes: try parseSize(size), lastUsed: row["CreatedSince"] as? String ?? "—",
                                    inUse: containerCount > 0, kind: .image, containerCount: containerCount,
                                    uniqueBytes: (row["UniqueSize"] as? String).flatMap { try? parseSize($0) },
                                    sharedBytes: (row["SharedSize"] as? String).flatMap { try? parseSize($0) }, eligibility: decision))
        }
        for row in caches {
            guard let id = row["ID"] as? String, let size = row["Size"] as? String,
                  let inUse = row["InUse"] as? String, ["true", "false"].contains(inUse) else { throw CleanupError.invalidResponse }
            items.append(DockerItem(id: "cache:" + id, name: (row["Description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                                    bytes: try parseSize(size), lastUsed: row["LastUsedSince"] as? String ?? "—",
                                    inUse: inUse == "true", kind: .buildCache, containerCount: nil,
                                    uniqueBytes: nil, sharedBytes: nil, eligibility: .protected("Project ownership unknown")))
        }
        guard let imageBytes, let cacheBytes, let reclaimable else { throw CleanupError.invalidResponse }
        return DockerReport(items: items.sorted { $0.bytes > $1.bytes }, imageBytes: imageBytes, cacheBytes: cacheBytes,
                            reclaimableCacheBytes: reclaimable)
    }

    public static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.isLenient = false
        return formatter.date(from: String(value.prefix(25)))
    }

    public static func validImageID(_ value: String) -> Bool {
        guard let range = value.range(of: #"^sha256:[a-f0-9]{64}$"#, options: .regularExpression) else { return false }
        return range == value.startIndex..<value.endIndex
    }

    public static func parseSize(_ value: String) throws -> Int64 {
        let pattern = #"^([0-9]+(?:\.[0-9]+)?)\s*(B|kB|KB|MB|GB|TB|KiB|MiB|GiB|TiB)$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, range: range), match.range == range,
              let numberRange = Range(match.range(at: 1), in: value), let unitRange = Range(match.range(at: 2), in: value),
              let number = Double(value[numberRange]) else { throw CleanupError.invalidResponse }
        let multipliers: [String: Double] = ["B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
                                            "KiB": 1024, "MiB": 1_048_576, "GiB": 1_073_741_824, "TiB": 1_099_511_627_776]
        guard let multiplier = multipliers[String(value[unitRange])], number * multiplier < Double(Int64.max) else { throw CleanupError.invalidResponse }
        return Int64((number * multiplier).rounded())
    }

    public func removeImages(ids: [String]) async throws -> String {
        guard !ids.isEmpty, ids.allSatisfy(Self.validImageID) else { throw CleanupError.unsafePath }
        let current = try await load()
        let unused = Set(current.items.filter { $0.kind == .image && $0.eligibility.canClean }.map(\.id))
        guard Set(ids).isSubset(of: unused) else { throw CleanupError.stale }
        // Docker refuses an image that becomes used; never override that protection.
        return try await runner.run(command(["image", "rm"] + Set(ids).sorted())).checked().text
    }

    public func cleanBuildCache() async throws -> String {
        // Deliberately retain this guard for older callers/configuration files.
        // Docker's "unused" cache flag does not establish that its project is inactive.
        throw CleanupError.unavailable("Build cache is protected because it cannot be reliably associated with active projects. Let the project's build tools manage it.")
    }
}
