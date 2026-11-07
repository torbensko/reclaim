import Foundation
import ReclaimCore

struct CleanupOpportunity: Identifiable {
    let source: Source
    let itemID: String
    let name: String
    let path: String?
    let ownerPath: String?
    let bytes: Int64?
    let privateBytes: Int64?
    let changed: Date?
    let eligibility: CleanupEligibility
    let evidence: String
    let action: CleanupAction?
    var id: String { source.rawValue + ":" + itemID }
    var searchable: String { [name, source.rawValue, path ?? "", ownerPath ?? "", eligibility.explanation, evidence].joined(separator: " ") }
    var reason: String {
        guard eligibility.isRecommended else { return eligibility.explanation }
        switch source {
        case .projects, .xcode: return "Unchanged for 7 days · no use detected"
        case .browser: return "Signing copy older than 24 hours · no use detected"
        case .docker: return "Unused image older than 24 hours"
        default: return eligibility.explanation
        }
    }
    var confirmation: String {
        [name, path, ownerPath.map { "Project: \($0)" },
         changed.map { "Last changed: \($0.formatted(date: .abbreviated, time: .shortened))" },
         eligibility.needsReview ? "Review first: \(eligibility.explanation)" : nil, evidence].compactMap { $0 }.joined(separator: "\n")
    }
}

/// Private file measurements can be combined only for disjoint cleanup paths.
/// Docker's virtual store and snapshot sizes are deliberately reported separately.
struct OverviewReclaimEstimate {
    let recommendedBytes: Int64?
    let allOptionsBytes: Int64?

    init(items: [CleanupOpportunity], fileInventoryComplete: Bool) {
        let files = items.filter { $0.action != nil && $0.eligibility.canClean && $0.source != .docker && $0.source != .timeMachine }
        recommendedBytes = fileInventoryComplete ? Self.total(files.filter { $0.eligibility.isRecommended }) : nil
        allOptionsBytes = fileInventoryComplete ? Self.total(files) : nil
    }

    private static func total(_ items: [CleanupOpportunity]) -> Int64? {
        guard items.allSatisfy({ $0.path?.hasPrefix("/") == true }) else { return nil }
        let byPath = Dictionary(grouping: items) { URL(fileURLWithPath: $0.path!).standardizedFileURL.path }
        let paths = byPath.keys.sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
        var included: [String] = []
        var total: Int64 = 0
        for path in paths {
            // An outer directory's measurement already includes its descendants.
            if included.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            let measurements = byPath[path]!.map(\.privateBytes)
            guard let bytes = measurements.first!, bytes >= 0,
                  measurements.allSatisfy({ $0 == bytes }) else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { return nil }
            total = sum
            included.append(path)
        }
        return total
    }
}

@MainActor extension ReclaimStore {
    var overviewReclaimEstimate: OverviewReclaimEstimate {
        let sources: [Source] = [.projects, .xcode, .browser, .agents]
        let complete = sources.allSatisfy { localReport(for: $0) != nil && !loading.contains($0) && errors[$0] == nil }
        return OverviewReclaimEstimate(items: opportunities, fileInventoryComplete: complete)
    }

    var opportunities: [CleanupOpportunity] {
        var rows: [CleanupOpportunity] = []
        for source in [Source.projects, .xcode, .browser, .agents] where errors[source] == nil && !loading.contains(source) {
            for entry in localReport(for: source)?.entries ?? [] {
                let removal: CleanupAction?
                if !entry.eligible { removal = nil }
                else {
                    switch source {
                    case .projects: removal = .projects([entry.id])
                    case .xcode: removal = .xcode([entry.id])
                    case .browser: removal = .chrome([entry.id])
                    case .agents: removal = .agentLogs([entry.id])
                    default: removal = nil
                    }
                }
                rows.append(CleanupOpportunity(source: source, itemID: entry.id, name: entry.name,
                    path: entry.path, ownerPath: entry.ownerPath, bytes: entry.footprintKnown ? entry.bytes : nil,
                    privateBytes: entry.privateBytes, changed: entry.modified == .distantFuture ? nil : entry.modified,
                    eligibility: entry.eligibility, evidence: entry.evidence.isEmpty ? entry.eligibility.explanation : entry.evidence, action: removal))
            }
        }
        if errors[.docker] == nil && !loading.contains(.docker) {
            for item in docker?.items ?? [] {
                rows.append(CleanupOpportunity(source: .docker, itemID: item.id, name: item.name,
                    path: nil, ownerPath: nil, bytes: item.bytes, privateBytes: nil, changed: nil,
                    eligibility: item.eligibility,
                    evidence: item.kind == .image
                        ? "Image \(item.id). All local tags: \(item.references.tags.joined(separator: ", ")). Age: \(item.lastUsed). Docker checks running AND stopped container references. Image layers can overlap; the footprint is not SSD recovery."
                        : "Docker build cache is inspection-only: project ownership is not established.",
                    action: item.kind == .image && item.eligibility.canClean ? .images([item.id]) : nil))
            }
        }
        if errors[.timeMachine] == nil && !loading.contains(.timeMachine), !snapshots.isEmpty {
            rows.append(CleanupOpportunity(source: .timeMachine, itemID: "thin-local-snapshots",
                name: "\(snapshots.count) local Time Machine snapshots", path: SnapshotCommands.localVolume,
                ownerPath: nil, bytes: nil, privateBytes: nil, changed: nil,
                eligibility: .review("Local restore history cannot be rebuilt. Ask macOS to thin it; the amount recovered is not guaranteed."),
                evidence: "Request 25 GB from local snapshots on the internal Data volume. macOS chooses which restore points to remove. Removed restore history is lost; current files and external backups stay. Choose a different target in the Time Machine tab.",
                action: .snapshot(.reclaim(gigabytes: 25, urgency: 1))))
        }
        return rows.sorted {
            if $0.eligibility.group != $1.eligibility.group { return $0.eligibility.group < $1.eligibility.group }
            if $0.bytes != $1.bytes { return ($0.bytes ?? -1) > ($1.bytes ?? -1) }
            return $0.id < $1.id
        }
    }

    /// Consume visible selections, exclude protected data and group actions so each
    /// source revalidates one exact batch. Snapshot authorization comes last.
    func cleanupPlan(for rows: [CleanupOpportunity]) -> CleanupAction? {
        let selected = rows.filter { $0.eligibility.canClean && $0.action != nil }
        guard !selected.isEmpty else { return nil }
        var actions: [CleanupAction] = []
        for source in Source.allCases {
            let items = selected.filter { $0.source == source }
            guard !items.isEmpty else { continue }
            let ids = Array(Set(items.map(\.itemID))).sorted()
            switch source {
            case .projects: actions.append(.projects(ids))
            case .xcode: actions.append(.xcode(ids))
            case .agents: actions.append(.agentLogs(ids))
            case .browser: actions.append(.chrome(ids))
            case .docker: actions.append(.images(ids))
            case .timeMachine: if let action = items.first?.action { actions.append(action) }
            case .overview: break
            }
        }
        return .batch(actions: actions, items: selected.map(\.confirmation))
    }
}
