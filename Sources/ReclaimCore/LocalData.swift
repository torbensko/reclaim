import Foundation
import Darwin

public enum CleanupError: LocalizedError, Sendable {
    case unsafePath
    case inUse(String)
    case invalidResponse
    case unavailable(String)
    case stale

    public var errorDescription: String? {
        switch self {
        case .unsafePath: return "The item is outside the supported cleanup location, is a link, or is on another volume."
        case let .inUse(app): return "Close \(app) before cleaning its data."
        case .invalidResponse: return "The storage source returned an unreadable response."
        case let .unavailable(message): return message
        case .stale: return "These items have changed. Refresh and review the selection."
        }
    }
}

public struct LocalEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case xcode = "Build & index", chromeClone = "Signing copy", chromeCache = "Browser cache" }
    public let id: String
    public let name: String
    public let path: String
    public let bytes: Int64
    public let privateBytes: Int64?
    public let modified: Date
    public let kind: Kind
    public let eligibility: CleanupEligibility
    public let ownerPath: String?
    public var eligible: Bool { eligibility.canClean }

    public init(id: String, name: String, path: String, bytes: Int64, modified: Date, kind: Kind,
                eligibility: CleanupEligibility = .unknown("Not checked"), ownerPath: String? = nil, privateBytes: Int64? = nil) {
        self.id = id; self.name = name; self.path = path; self.bytes = bytes; self.modified = modified
        self.kind = kind; self.eligibility = eligibility; self.ownerPath = ownerPath
        self.privateBytes = privateBytes
    }
    public func assessed(_ eligibility: CleanupEligibility) -> LocalEntry {
        LocalEntry(id: id, name: name, path: path, bytes: bytes, modified: modified, kind: kind, eligibility: eligibility, ownerPath: ownerPath, privateBytes: privateBytes)
    }
}

public struct LocalReport: Sendable {
    public let entries: [LocalEntry]
    public let notice: String?
    public var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    public var candidateCount: Int { entries.filter(\.eligible).count }
    public var privateBytes: Int64? {
        guard entries.allSatisfy({ $0.privateBytes != nil }) else { return nil }
        return entries.reduce(0) { $0 + ($1.privateBytes ?? 0) }
    }
}

public enum LocalFiles {
    /// Resolve the existing ancestor, including /var and Data-volume aliases.
    /// URL.standardizedFileURL normalizes existing and missing paths differently.
    public static func canonicalPath(_ path: String) -> String {
        var current = path
        var suffix: [String] = []
        while current != "/" {
            if let resolved = realpath(current, nil) {
                defer { free(resolved) }
                return ([String(cString: resolved)] + suffix.reversed()).joined(separator: "/")
            }
            let url = URL(fileURLWithPath: current)
            suffix.append(url.lastPathComponent)
            current = url.deletingLastPathComponent().path
        }
        return "/" + suffix.reversed().joined(separator: "/")
    }
    public static var userTemporaryDirectory: URL {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(1, length))
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let path = count > 0 ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : FileManager.default.temporaryDirectory.path
        if let canonical = realpath(path, nil) {
            defer { free(canonical) }
            return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func validate(_ url: URL, within root: URL) throws {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard root.resolvingSymlinksInPath().path == rootPath,
              url.resolvingSymlinksInPath().path == path,
              path == rootPath || path.hasPrefix(rootPath + "/") else { throw CleanupError.unsafePath }
        var item = stat()
        var disk = stat()
        guard lstat(path, &item) == 0, stat(SnapshotCommands.localVolume, &disk) == 0,
              item.st_dev == disk.st_dev, item.st_mode & S_IFMT == S_IFDIR else {
            throw CleanupError.unsafePath
        }
    }

    /// Measures allocated file blocks, not guaranteed uniquely reclaimable APFS blocks.
    public static func allocatedBytes(_ root: URL) throws -> Int64 {
        try measurement(root).bytes
    }

    public static func measurement(_ root: URL) throws -> (bytes: Int64, modified: Date, privateBytes: Int64?) {
        try validate(root, within: root)
        var failure: (any Error)?
        let manager = FileManager.default
        guard let iterator = manager.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [], errorHandler: { _, error in failure = error; return false }
        ) else { throw CleanupError.unavailable("Unable to read \(root.lastPathComponent).") }
        var rootStat = stat()
        guard stat(root.path, &rootStat) == 0 else { throw CleanupError.unsafePath }
        var total: Int64 = 0
        var privateTotal: Int64? = 0
        var latest = modified(root)
        var seen = Set<String>()
        for case let url as URL in iterator {
            var item = stat()
            guard lstat(url.path, &item) == 0 else { throw CleanupError.unavailable("A file changed while measuring. Refresh to try again.") }
            if item.st_mode & S_IFMT == S_IFLNK { continue }
            if item.st_dev != rootStat.st_dev {
                if item.st_mode & S_IFMT == S_IFDIR { iterator.skipDescendants() }
                continue
            }
            latest = max(latest, Date(timeIntervalSince1970: Double(item.st_mtimespec.tv_sec)))
            let key = "\(item.st_dev):\(item.st_ino)"
            if item.st_mode & S_IFMT == S_IFREG, seen.insert(key).inserted {
                total += Int64(item.st_blocks) * 512
                if let subtotal = privateTotal, let bytes = privateFileBytes(url) {
                    // A link elsewhere prevents this directory's deletion freeing the file.
                    privateTotal = subtotal + (item.st_nlink > 1 ? 0 : bytes)
                } else { privateTotal = nil }
            }
        }
        if let failure { throw failure }
        return (total, latest, privateTotal)
    }

    /// Public getattrlist attribute documented by macOS: file bytes not retained by
    /// another clone/snapshot. Unknown/unsupported is nil, never a fabricated zero.
    public static func privateFileBytes(_ url: URL) -> Int64? {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        attributes.forkattr = UInt32(ATTR_CMNEXT_PRIVATESIZE)
        // Packed 4-byte length, 20-byte returned attribute set, then 8-byte off_t.
        var buffer = [UInt8](repeating: 0, count: 32)
        guard getattrlist(url.path, &attributes, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)) == 0 else { return nil }
        return buffer.withUnsafeBytes {
            guard $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == 32,
                  $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            let value = $0.loadUnaligned(fromByteOffset: 24, as: Int64.self)
            return value >= 0 ? value : nil
        }
    }

    public static func children(_ root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try validate(root, within: root)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
    }

    public static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
    }

    public static func plist(_ url: URL) throws -> [String: Any] {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw CleanupError.unsafePath }
        guard let result = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else {
            throw CleanupError.invalidResponse
        }
        return result
    }

    public static func removeGeneratedDirectory(_ url: URL, within root: URL) throws {
        try validate(url, within: root)
        var directoryStat = stat()
        guard stat(url.path, &directoryStat) == 0 else { throw CleanupError.unsafePath }
        var failure: (any Error)?
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
            errorHandler: { _, error in failure = error; return false }) else { throw CleanupError.unsafePath }
        for case let child as URL in enumerator {
            var item = stat()
            guard lstat(child.path, &item) == 0, item.st_dev == directoryStat.st_dev else { throw CleanupError.unsafePath }
            // FileManager's enumerator never follows symlinks. Calling skipDescendants
            // on a link can skip a later sibling directory, hiding real files/mounts.
        }
        if let failure { throw failure }
        try validate(url, within: root)
        try FileManager.default.removeItem(at: url)
    }

    public static func requireClosed(_ pattern: String, app: String, runner: any CommandRunning) async throws {
        let result = try await runner.run(Command(executable: "/usr/bin/pgrep", arguments: ["-x", pattern]))
        if result.exitCode == 0 { throw CleanupError.inUse(app) }
        guard result.exitCode == 1, result.text.isEmpty else { throw CleanupError.unavailable("Could not check whether \(app) is running.") }
    }
}

public struct XcodeService: Sendable {
    public let root: URL
    private let usage: any UsageInspecting
    private let repositories: any RepositoriesInspecting
    public static let generatedFolders = ["Build", "Index.noindex", "Index"]

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
                runner: any CommandRunning = ProcessRunner(), usage: (any UsageInspecting)? = nil,
                repositories: (any RepositoriesInspecting)? = nil) {
        self.root = root.standardizedFileURL
        self.usage = usage ?? UsageInspector(runner: runner)
        self.repositories = repositories ?? RepositoryInspector(runner: runner)
    }

    public func load(now: Date = .now) async throws -> LocalReport {
        async let inventory = repositories.inventory()
        let entries = try await Task.detached {
            var entries: [LocalEntry] = []
            for project in try LocalFiles.children(root) {
                guard FileManager.default.fileExists(atPath: project.appendingPathComponent("info.plist").path) else { continue }
                try LocalFiles.validate(project, within: root)
                let info = try LocalFiles.plist(project.appendingPathComponent("info.plist"))
                guard let workspace = info["WorkspacePath"] as? String, workspace.hasPrefix("/") else { continue }
                var bytes: Int64 = 0
                var privateBytes: Int64? = 0
                var latest = info["LastAccessedDate"] as? Date ?? .distantPast
                for folder in Self.generatedFolders.map({ project.appendingPathComponent($0) }) {
                    guard FileManager.default.fileExists(atPath: folder.path) else { continue }
                    try LocalFiles.validate(folder, within: root)
                    let measurement = try LocalFiles.measurement(folder)
                    bytes += measurement.bytes
                    if let total = privateBytes, let value = measurement.privateBytes { privateBytes = total + value }
                    else { privateBytes = nil }
                    latest = max(latest, measurement.modified)
                }
                guard bytes > 0 else { continue }
                entries.append(LocalEntry(id: project.lastPathComponent,
                    name: URL(fileURLWithPath: workspace).deletingPathExtension().lastPathComponent,
                    path: project.path, bytes: bytes, modified: latest, kind: .xcode, ownerPath: workspace, privateBytes: privateBytes))
            }
            return entries
        }.value
        let owners = await inventory
        var assessed: [LocalEntry] = []
        for entry in entries {
            let workspace = URL(fileURLWithPath: entry.ownerPath!)
            let decision: CleanupEligibility
            if let ownership = XcodePolicy.ownership(workspace: workspace, inventory: owners) { decision = ownership }
            else if now.timeIntervalSince(entry.modified) < XcodePolicy.minimumAge { decision = .protected("Used within 7 days") }
            else {
                let evidence = await usage.inspect(URL(fileURLWithPath: entry.path))
                decision = evidence.buildToolsRunning ? .protected("Build tools running") : evidence.eligibility(for: URL(fileURLWithPath: entry.path))
            }
            assessed.append(entry.assessed(decision))
        }
        return LocalReport(entries: assessed.sorted { $0.bytes > $1.bytes },
                           notice: "Existing source folders and registered worktrees are protected, regardless of age. Only verified orphaned build data older than 7 days is eligible.")
    }

    public func clean(ids: [String], inactiveBefore: Date? = nil, now: Date = .now) async throws -> String {
        guard !ids.isEmpty, ids.allSatisfy({ !$0.contains("/") && $0 != "." && $0 != ".." }) else { throw CleanupError.unsafePath }
        let current = try await load(now: now)
        let selected = current.entries.filter { ids.contains($0.id) }
        guard Set(ids).isSubset(of: Set(selected.filter(\.eligible).map(\.id))) else { throw CleanupError.stale }
        if let inactiveBefore, selected.contains(where: { $0.modified > inactiveBefore }) { throw CleanupError.stale }
        // Repeat ownership and usage checks immediately before each removal. Never
        // infer that a workspace was abandoned solely from its build folder's age.
        for entry in selected {
            let owners = await repositories.inventory()
            guard let owner = entry.ownerPath,
                  XcodePolicy.ownership(workspace: URL(fileURLWithPath: owner), inventory: owners) == nil else { throw CleanupError.stale }
            let project = URL(fileURLWithPath: entry.path)
            let evidence = await usage.inspect(project)
            guard !evidence.buildToolsRunning, evidence.eligibility(for: project).canClean else { throw CleanupError.stale }
            let freshOwners = await repositories.inventory()
            guard XcodePolicy.ownership(workspace: URL(fileURLWithPath: owner), inventory: freshOwners) == nil else { throw CleanupError.stale }
            try await Task.detached {
                try LocalFiles.validate(project, within: root)
                let info = try LocalFiles.plist(project.appendingPathComponent("info.plist"))
                guard info["WorkspacePath"] as? String == owner else { throw CleanupError.stale }
                let accessed = info["LastAccessedDate"] as? Date ?? .distantPast
                guard now.timeIntervalSince(accessed) >= XcodePolicy.minimumAge else { throw CleanupError.stale }
                let folders = Self.generatedFolders.map { project.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
                for folder in folders {
                    let measurement = try LocalFiles.measurement(folder)
                    guard now.timeIntervalSince(measurement.modified) >= XcodePolicy.minimumAge else { throw CleanupError.stale }
                }
                for folder in folders { try LocalFiles.removeGeneratedDirectory(folder, within: root) }
            }.value
        }
        return "Removed orphaned build and index data for \(selected.count) projects. Source packages, archives, logs and source projects were preserved."
    }
}

public struct BrowserService: Sendable {
    public let cloneRoot: URL
    public let cacheRoot: URL
    private let usage: any UsageInspecting
    public static let minimumAge: TimeInterval = 24 * 3600

    public init(cloneRoot: URL? = nil, cacheRoot: URL? = nil, runner: any CommandRunning = ProcessRunner(), usage: (any UsageInspecting)? = nil) {
        self.cloneRoot = (cloneRoot ?? LocalFiles.userTemporaryDirectory.deletingLastPathComponent()
            .appendingPathComponent("X/com.google.Chrome.code_sign_clone")).standardizedFileURL
        self.cacheRoot = (cacheRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Google/Chrome")).standardizedFileURL
        self.usage = usage ?? UsageInspector(runner: runner)
    }

    public func load(includeCaches: Bool = true, now: Date = .now) async throws -> LocalReport {
        let entries = try await Task.detached {
            var entries: [LocalEntry] = []
            for clone in try LocalFiles.children(cloneRoot) {
                guard Self.validCloneName(clone.lastPathComponent) else { continue }
                try validateClone(clone)
                let info = try LocalFiles.plist(clone.appendingPathComponent("Google Chrome.app.bundle/Contents/Info.plist"))
                let version = info["CFBundleShortVersionString"] as? String ?? "Unknown version"
                let measurement = try LocalFiles.measurement(clone)
                entries.append(LocalEntry(id: clone.lastPathComponent, name: "Chrome \(version)", path: clone.path,
                                          bytes: measurement.bytes, modified: LocalFiles.modified(clone), kind: .chromeClone, privateBytes: measurement.privateBytes))
            }
            if includeCaches {
                for profile in try LocalFiles.children(cacheRoot) {
                    try LocalFiles.validate(profile, within: cacheRoot)
                    for name in ["Cache", "Code Cache"] {
                        let folder = profile.appendingPathComponent(name)
                        guard FileManager.default.fileExists(atPath: folder.path) else { continue }
                        try LocalFiles.validate(folder, within: cacheRoot)
                        let measurement = try LocalFiles.measurement(folder)
                        entries.append(LocalEntry(id: folder.path, name: "\(profile.lastPathComponent) · \(name)", path: folder.path,
                                                  bytes: measurement.bytes, modified: LocalFiles.modified(folder), kind: .chromeCache,
                                                  eligibility: .inspectOnly, privateBytes: measurement.privateBytes))
                    }
                }
            }
            return entries
        }.value
        let evidence = entries.contains { $0.kind == .chromeClone } ? await usage.inspect(cloneRoot) : UsageEvidence()
        let assessed = entries.map { entry in
            guard entry.kind == .chromeClone else { return entry }
            let decision = evidence.eligibility(for: URL(fileURLWithPath: entry.path))
            if !decision.canClean { return entry.assessed(decision) }
            if now.timeIntervalSince(entry.modified) < Self.minimumAge { return entry.assessed(.protected("Keep for 24 hours")) }
            return entry.assessed(.candidate)
        }
        return LocalReport(entries: assessed.sorted { $0.bytes > $1.bytes },
                           notice: "Signing copies must be older than 24 hours with no executable, mapped-file or open-file references. Failed checks keep the copy. Sizes may share APFS blocks.")
    }

    public static func validCloneName(_ name: String) -> Bool {
        guard let range = name.range(of: #"^code_sign_clone\.[A-Za-z0-9]{6}$"#, options: .regularExpression) else { return false }
        return range == name.startIndex..<name.endIndex
    }

    private func validateClone(_ clone: URL) throws {
        guard Self.validCloneName(clone.lastPathComponent) else { throw CleanupError.unsafePath }
        try LocalFiles.validate(clone, within: cloneRoot)
        let children = try LocalFiles.children(clone)
        guard children.count == 1, let bundle = children.first, bundle.lastPathComponent == "Google Chrome.app.bundle" else { throw CleanupError.unsafePath }
        try LocalFiles.validate(bundle, within: cloneRoot)
        let info = try LocalFiles.plist(bundle.appendingPathComponent("Contents/Info.plist"))
        guard info["CFBundleIdentifier"] as? String == "com.google.Chrome" else { throw CleanupError.unsafePath }
    }

    public func clean(ids: [String], now: Date = .now) async throws -> String {
        guard !ids.isEmpty, ids.allSatisfy(Self.validCloneName) else { throw CleanupError.unsafePath }
        let current = try await load(includeCaches: false, now: now)
        guard Set(ids).isSubset(of: Set(current.entries.filter(\.eligible).map(\.id))) else { throw CleanupError.stale }
        for id in Set(ids).sorted() {
            let clone = cloneRoot.appendingPathComponent(id)
            try validateClone(clone)
            guard now.timeIntervalSince(LocalFiles.modified(clone)) >= Self.minimumAge else { throw CleanupError.stale }
            let evidence = await usage.inspect(clone)
            guard evidence.eligibility(for: clone).canClean else { throw CleanupError.stale }
            try await Task.detached {
                try validateClone(clone)
                guard now.timeIntervalSince(LocalFiles.modified(clone)) >= Self.minimumAge else { throw CleanupError.stale }
                try LocalFiles.removeGeneratedDirectory(clone, within: cloneRoot)
            }.value
        }
        return "Removed \(Set(ids).count) unused Chrome signing copies older than 24 hours. Browser profiles and the installed app were preserved."
    }
}
