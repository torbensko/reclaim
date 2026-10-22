import Foundation

public struct DockerImageReferences: Equatable, Sendable {
    public let tags: [String]
    public let digests: [String]
    public var all: Set<String> { Set(tags + digests) }
    var removableByID: Bool {
        if all.count <= 1 { return true }
        guard tags.count == 1, let separator = tags[0].lastIndex(of: ":") else { return false }
        let repository = tags[0][..<separator]
        return digests.allSatisfy { $0.hasPrefix(repository + "@sha256:") }
    }
}

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
    public let references: DockerImageReferences
}

public struct DockerReport: Sendable {
    public let items: [DockerItem]
    public let imageBytes: Int64
    public let cacheBytes: Int64
    public let reclaimableCacheBytes: Int64
    public let reclaimableImageBytes: Int64?
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
        let report = try Self.parse(summary: summary.output, detail: detail.output)
        let ids = report.items.filter { $0.kind == .image }.map(\.id)
        guard !ids.isEmpty else { return report }
        // system df can report just one tag per image, even when Desktop shows many.
        let references = try await inspectReferences(ids)
        guard Set(references.keys) == Set(ids) else { throw CleanupError.stale }
        return try Self.parse(summary: summary.output, detail: detail.output, references: references)
    }

    public static func parse(summary: Data, detail: Data, now: Date = .now,
                             references: [String: DockerImageReferences]? = nil) throws -> DockerReport {
        guard let object = try JSONSerialization.jsonObject(with: detail) as? [String: Any] else { throw CleanupError.invalidResponse }
        func rows(_ key: String) throws -> [[String: Any]] {
            if object[key] is NSNull { return [] }
            guard let rows = object[key] as? [[String: Any]] else { throw CleanupError.invalidResponse }
            return rows
        }
        let images = try rows("Images")
        let caches = try rows("BuildCache")
        var imageBytes: Int64?
        var reclaimableImages: Int64?
        var cacheBytes: Int64?
        var reclaimable: Int64?
        for line in String(decoding: summary, as: UTF8.self).split(separator: "\n") {
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let size = row["Size"] as? String else { throw CleanupError.invalidResponse }
            if row["Type"] as? String == "Images" {
                imageBytes = try parseSize(size)
                if let value = row["Reclaimable"] as? String {
                    reclaimableImages = try parseSize(String(value.split(separator: " ").first ?? ""))
                }
            }
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
            var digests: [String] = []
            for entry in rows {
                guard let countString = entry["Containers"] as? String, let count = Int(countString), count >= 0,
                      let repository = entry["Repository"] as? String, let tag = entry["Tag"] as? String else { throw CleanupError.invalidResponse }
                containerCount = max(containerCount, count)
                if repository != "<none>" && tag != "<none>" { tags.append("\(repository):\(tag)") }
                if repository != "<none>", let digest = entry["Digest"] as? String, digest != "<none>" {
                    digests.append("\(repository)@\(digest)")
                }
            }
            let imageReferences: DockerImageReferences
            if let references {
                guard let value = references[id] else { throw CleanupError.stale }
                imageReferences = value
            } else {
                imageReferences = DockerImageReferences(tags: Set(tags).sorted(), digests: Set(digests).sorted())
            }
            guard imageReferences.all.allSatisfy(Self.validImageReference) else { throw CleanupError.invalidResponse }
            let created = (row["CreatedAt"] as? String).flatMap(Self.parseDate)
            let decision: CleanupEligibility
            if containerCount > 0 { decision = .protected("Referenced by containers") }
            else if builderBusy { decision = .protected("Builder in use") }
            else if let created {
                decision = now.timeIntervalSince(created) >= 24 * 3600 ? .candidate : .protected("Keep for 24 hours")
            } else { decision = .unknown("Docker did not report a usable creation time.") }
            let names = imageReferences.tags.isEmpty ? imageReferences.digests : imageReferences.tags
            items.append(DockerItem(id: id, name: names.isEmpty ? "Untagged · \(id.prefix(19))" : names.joined(separator: ", "),
                                    bytes: try parseSize(size), lastUsed: row["CreatedSince"] as? String ?? "—",
                                    inUse: containerCount > 0, kind: .image, containerCount: containerCount,
                                    uniqueBytes: (row["UniqueSize"] as? String).flatMap { try? parseSize($0) },
                                    sharedBytes: (row["SharedSize"] as? String).flatMap { try? parseSize($0) }, eligibility: decision,
                                    references: imageReferences))
        }
        for row in caches {
            guard let id = row["ID"] as? String, let size = row["Size"] as? String,
                  let inUse = row["InUse"] as? String, ["true", "false"].contains(inUse) else { throw CleanupError.invalidResponse }
            items.append(DockerItem(id: "cache:" + id, name: (row["Description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                                    bytes: try parseSize(size), lastUsed: row["LastUsedSince"] as? String ?? "—",
                                    inUse: inUse == "true", kind: .buildCache, containerCount: nil,
                                    uniqueBytes: nil, sharedBytes: nil, eligibility: .protected("Project ownership unknown"),
                                    references: DockerImageReferences(tags: [], digests: [])))
        }
        guard let imageBytes, let cacheBytes, let reclaimable else { throw CleanupError.invalidResponse }
        return DockerReport(items: items.sorted { $0.bytes > $1.bytes }, imageBytes: imageBytes, cacheBytes: cacheBytes,
                            reclaimableCacheBytes: reclaimable, reclaimableImageBytes: reclaimableImages)
    }

    public static func validImageReference(_ value: String) -> Bool {
        guard let range = value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,1023}$"#, options: .regularExpression) else { return false }
        return range == value.startIndex..<value.endIndex
    }

    private func inspectReferences(_ names: [String]) async throws -> [String: DockerImageReferences] {
        // Request only identity fields, never image configuration/environment values.
        let format = #"{"ID":{{json .Id}},"RepoTags":{{json .RepoTags}},"RepoDigests":{{json .RepoDigests}}}"#
        let result = try await runner.run(command(["image", "inspect", "--format", format, "--"] + names, timeout: 30)).checked()
        return try Self.parseReferences(result.output)
    }

    public static func parseReferences(_ data: Data) throws -> [String: DockerImageReferences] {
        var references: [String: DockerImageReferences] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["ID"] as? String, validImageID(id), references[id] == nil else { throw CleanupError.invalidResponse }
            func names(_ key: String) throws -> [String] {
                if row[key] is NSNull { return [] }
                guard let names = row[key] as? [String], names.allSatisfy(validImageReference) else { throw CleanupError.invalidResponse }
                return Set(names).sorted()
            }
            references[id] = try DockerImageReferences(tags: names("RepoTags"), digests: names("RepoDigests"))
        }
        guard !references.isEmpty else { throw CleanupError.invalidResponse }
        return references
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
        var output: [String] = []
        for id in Set(ids).sorted() {
            let original = current.items.first { $0.id == id }!
            var remaining = original.references.all
            var changed = false
            while true {
                // Re-read usage and tags before each step. Retagging, new container
                // references, failed checks or builder activity stop the operation.
                let fresh = try await load()
                guard let item = fresh.items.first(where: { $0.id == id }) else {
                    guard changed else { throw CleanupError.stale }
                    break
                }
                guard item.eligibility.canClean, item.references.all.isSubset(of: remaining) else { throw CleanupError.stale }
                if changed && item.references.all == remaining { throw CleanupError.unavailable("Docker kept the image. Refresh to review its remaining references.") }
                remaining = item.references.all
                // An ID with multiple references cannot be removed without force.
                // Untag only verified aliases of this selected image, then let the
                // engine remove it normally. --no-prune preserves unselected parents.
                let reference = item.references.removableByID ? id : (item.references.tags.first ?? item.references.digests.first!)
                if reference != id {
                    let resolved = try await inspectReferences([reference])
                    guard resolved.count == 1, resolved[id] == item.references else { throw CleanupError.stale }
                }
                output.append(try await runner.run(command(["image", "rm", "--no-prune", "--", reference], timeout: 60)).checked().text)
                changed = true
            }
        }
        return output.joined(separator: "\n")
    }

    public func cleanBuildCache() async throws -> String {
        // Deliberately retain this guard for older callers/configuration files.
        // Docker's "unused" cache flag does not establish that its project is inactive.
        throw CleanupError.unavailable("Build cache is protected because it cannot be reliably associated with active projects. Let the project's build tools manage it.")
    }
}
