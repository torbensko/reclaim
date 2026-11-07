import Foundation
import Testing
@testable import Reclaim
@testable import ReclaimCore

@Test @MainActor func overviewCombinesSourcesWithoutMixingIDsOrSelectingProtectedData() {
    let store = ReclaimStore(isDemo: true)
    let old = Date.now.addingTimeInterval(-10 * 86400)
    store.projects = LocalReport(entries: [
        LocalEntry(id: "same-id", name: "Build", path: "/fixture/.build/out", bytes: 100, modified: old,
                   kind: .swiftBuild, eligibility: .candidate, privateBytes: 50),
        LocalEntry(id: "deps", name: "Dependencies", path: "/fixture/node_modules", bytes: 200, modified: old,
                   kind: .nodeDependencies, eligibility: .review("Downloads required"), privateBytes: nil),
        LocalEntry(id: "active", name: "Active", path: "/fixture/active/.build/out", bytes: 300, modified: old,
                   kind: .swiftBuild, eligibility: .protected("In use · PID 42"))
    ], notice: nil)
    store.browser = LocalReport(entries: [LocalEntry(id: "same-id", name: "Chrome copy", path: "/fixture/clone", bytes: 80,
        modified: old, kind: .chromeClone, eligibility: .candidate, privateBytes: 40)], notice: nil)
    let rows = store.opportunities
    #expect(rows.count == 4)
    #expect(Set(rows.map(\.id)).count == 4)
    #expect(rows.map { $0.eligibility.group } == [0, 0, 1, 2])
    #expect(rows.first { $0.itemID == "deps" }?.privateBytes == nil)
    guard case let .batch(actions, descriptions) = store.cleanupPlan(for: rows) else { Issue.record("Missing cleanup plan"); return }
    #expect(actions.count == 2)
    #expect(descriptions.count == 3)
    #expect(descriptions.contains { $0.contains("Downloads required") })
    #expect(!descriptions.contains { $0.contains("/fixture/active") })
    if case let .projects(ids) = actions.first { #expect(Set(ids) == ["same-id", "deps"]) }
    else { Issue.record("Expected grouped project action") }
}

@Test @MainActor func overviewHidesStaleInventoriesDuringRefreshOrAfterFailure() {
    let store = ReclaimStore(isDemo: true)
    store.projects = LocalReport(entries: [LocalEntry(id: "old", name: "Old", path: "/fixture", bytes: 1,
        modified: .distantPast, kind: .swiftBuild, eligibility: .candidate)], notice: nil)
    #expect(store.opportunities.count == 1)
    store.loading = [.projects]
    #expect(store.opportunities.isEmpty)
    store.loading = []
    store.errors[.projects] = "Inspection failed"
    #expect(store.opportunities.isEmpty)
}

@Test @MainActor func timeMachineIsAReviewDecisionWithUnknownSize() {
    let store = ReclaimStore(isDemo: true)
    store.report = SnapshotReport(snapshots: [Snapshot(name: "com.apple.TimeMachine.2026-10-20-210000.local", purgeable: true)], storage: nil)
    let row = store.opportunities.first
    #expect(row?.eligibility.needsReview == true)
    #expect(row?.bytes == nil)
    #expect(row?.privateBytes == nil)
    #expect(row?.evidence.contains("25 GB") == true)
    #expect(row?.evidence.contains("restore history is lost") == true)
}

@Test @MainActor func selectingOnlyProtectedDataCannotCreateACleanupPlan() {
    let store = ReclaimStore(isDemo: true)
    store.agents = LocalReport(entries: [LocalEntry(id: "history", name: "Conversations", path: "/fixture/sessions", bytes: 1,
        modified: .distantPast, kind: .agentHistory, eligibility: .protected("Cannot be rebuilt"))], notice: nil)
    #expect(store.cleanupPlan(for: store.opportunities) == nil)
}

private actor BatchRecording {
    private(set) var calls = 0
    func run(_ action: CleanupAction) throws -> String {
        calls += 1
        if calls == 2 { throw SnapshotError.cancelled }
        return "Removed fixture project output"
    }
}

@Test func batchCancellationReportsEarlierCompletedWorkAndStopsRemainingActions() async {
    let recording = BatchRecording()
    do {
        _ = try await CleanupExecutor.runBatch([.projects(["fixture"]), .snapshot(.reclaim(gigabytes: 5, urgency: 1)), .chrome(["fixture"])]) {
            try await recording.run($0)
        }
        Issue.record("Expected cancellation")
    } catch let error as CleanupExecutor.BatchFailure {
        #expect(error.completed == ["Removed fixture project output"])
        #expect(error.reason.contains("cancelled"))
        #expect(await recording.calls == 2)
    } catch { Issue.record("Unexpected error: \(error)") }
}

private func estimateItem(_ path: String, privateBytes: Int64?, eligibility: CleanupEligibility = .candidate,
                          source: Source = .projects) -> CleanupOpportunity {
    CleanupOpportunity(source: source, itemID: path, name: path, path: path, ownerPath: nil,
                       bytes: 999_999, privateBytes: privateBytes, changed: nil,
                       eligibility: eligibility, evidence: "Fixture", action: eligibility.canClean ? .projects([path]) : nil)
}

@Test func overviewEstimatesSeparateRecommendedReviewAndUnrelatedStorageMeasures() {
    let items = [estimateItem("/fixture/build", privateBytes: 50),
                 estimateItem("/fixture/deps", privateBytes: 200, eligibility: .review("Reinstall")),
                 estimateItem("/fixture/active", privateBytes: 900, eligibility: .protected("In use")),
                 estimateItem("/fixture/docker", privateBytes: nil, source: .docker),
                 estimateItem("/fixture/snapshots", privateBytes: nil, eligibility: .review("History"), source: .timeMachine)]
    let result = OverviewReclaimEstimate(items: items, fileInventoryComplete: true)
    #expect(result.recommendedBytes == 50)
    #expect(result.allOptionsBytes == 250)
    let unknown = OverviewReclaimEstimate(items: items + [estimateItem("/fixture/unknown", privateBytes: nil, eligibility: .review("Reinstall"))], fileInventoryComplete: true)
    #expect(unknown.recommendedBytes == 50)
    #expect(unknown.allOptionsBytes == nil)
    #expect(OverviewReclaimEstimate(items: items, fileInventoryComplete: false).recommendedBytes == nil)
    #expect(OverviewReclaimEstimate(items: [], fileInventoryComplete: true).allOptionsBytes == 0)
}

@Test func overviewEstimatesDoNotDoubleCountOverlappingPathsOrAliases() {
    let items = [estimateItem("/fixture/output/nested", privateBytes: 40),
                 estimateItem("/fixture/output", privateBytes: 100),
                 estimateItem("/fixture/output/./", privateBytes: 100, source: .xcode),
                 estimateItem("/fixture/output-other", privateBytes: 20)]
    #expect(OverviewReclaimEstimate(items: items, fileInventoryComplete: true).recommendedBytes == 120)
    let conflict = items + [estimateItem("/fixture/output", privateBytes: nil, source: .browser)]
    #expect(OverviewReclaimEstimate(items: conflict, fileInventoryComplete: true).recommendedBytes == nil)
}

@Test @MainActor func overviewEstimatesStayUnknownUntilFileSourcesFinishAndIgnoreSelection() {
    let store = ReclaimStore(isDemo: true)
    for source in [Source.projects, .xcode, .browser] {
        let empty = LocalReport(entries: [], notice: nil)
        switch source { case .projects: store.projects = empty; case .xcode: store.xcode = empty; default: store.browser = empty }
    }
    #expect(store.overviewReclaimEstimate.allOptionsBytes == nil)
    store.agents = LocalReport(entries: [], notice: nil)
    #expect(store.overviewReclaimEstimate.allOptionsBytes == 0)
    store.projects = LocalReport(entries: [LocalEntry(id: "build", name: "Build", path: "/fixture/build", bytes: 1000,
        modified: .distantPast, kind: .swiftBuild, eligibility: .candidate, privateBytes: 100)], notice: nil)
    store.selection = ["unrelated"]
    store.source = .docker
    #expect(store.overviewReclaimEstimate.recommendedBytes == 100)
    store.loading = [.projects]
    #expect(store.overviewReclaimEstimate.recommendedBytes == nil)
    store.loading = []
    store.errors[.projects] = "Failed"
    #expect(store.overviewReclaimEstimate.allOptionsBytes == nil)
}
