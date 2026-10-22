import Foundation
import Testing
@testable import Reclaim

@Test func updatesRequireAConfiguredProductionBundle() {
    let key = Data(repeating: 1, count: 32).base64EncodedString()
    func allows(_ id: String? = "local.timemachinexray.app", _ channel: String? = "Release",
                _ feed: String? = UpdatePolicy.feed, _ publicKey: String? = key, demo: Bool = false) -> Bool {
        UpdatePolicy.permitsUpdates(identifier: id, channel: channel, feed: feed, publicKey: publicKey, isDemo: demo)
    }
    #expect(allows())
    #expect(!allows("local.timemachinexray.app.dev"))
    #expect(!allows(nil))
    #expect(!allows("local.timemachinexray.app", "Development"))
    #expect(!allows("local.timemachinexray.app", "Preview"))
    #expect(!allows("local.timemachinexray.app", nil))
    #expect(!allows("local.timemachinexray.app", "Release", "https://example.com/beta.xml"))
    #expect(!allows("local.timemachinexray.app", "Release", UpdatePolicy.feed, "bad-key"))
    #expect(!allows("local.timemachinexray.app", "Release", UpdatePolicy.feed, nil))
    #expect(!allows(demo: true))
}

@Test @MainActor func updateRelaunchWaitsForStorageWorkAndRunsOnlyOnce() {
    var busy = true
    var installs = 0
    let gate = UpdateRelaunchGate(isBusy: { busy })
    #expect(gate.postponeIfBusy { installs += 1 })
    gate.resumeIfIdle()
    #expect(installs == 0)
    busy = false
    gate.resumeIfIdle()
    gate.resumeIfIdle()
    #expect(installs == 1)
}

@Test @MainActor func staleIdleNotificationCannotRestartDuringNewWork() {
    var busy = true
    var installs = 0
    let gate = UpdateRelaunchGate(isBusy: { busy })
    #expect(gate.postponeIfBusy { installs += 1 })
    busy = false // An idle notification was queued, but another operation started.
    busy = true
    gate.resumeIfIdle()
    #expect(installs == 0)
    busy = false
    gate.resumeIfIdle()
    #expect(installs == 1)
}

@Test @MainActor func idleAppLeavesRelaunchToSparkle() {
    var installs = 0
    let gate = UpdateRelaunchGate(isBusy: { false })
    #expect(!gate.postponeIfBusy { installs += 1 })
    gate.resumeIfIdle()
    #expect(installs == 0)
}
