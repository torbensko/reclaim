import AppKit
import Combine
import Sparkle
import SwiftUI

struct UpdatePolicy {
    static let feed = "https://github.com/torbensko/reclaim/releases/latest/download/appcast.xml"
    static let downloads = URL(string: "https://github.com/torbensko/reclaim/releases/latest")!

    static func permitsUpdates(identifier: String?, channel: String?, feed: String?, publicKey: String?, isDemo: Bool) -> Bool {
        !isDemo && identifier == "local.timemachinexray.app" && channel == "Release"
            && feed == Self.feed && publicKey.flatMap { Data(base64Encoded: $0) }?.count == 32
    }
}

@MainActor final class UpdateRelaunchGate {
    private let isBusy: () -> Bool
    private var pending: (() -> Void)?
    init(isBusy: @escaping () -> Bool) { self.isBusy = isBusy }

    func postponeIfBusy(_ install: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        pending = install
        return true
    }

    func resumeIfIdle() {
        guard !isBusy(), let install = pending else { return }
        pending = nil
        install()
    }
}

/// Development and preview bundles never start Sparkle or consult its feed.
@MainActor final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    let enabled: Bool
    private let store: ReclaimStore
    private var controller: SPUStandardUpdaterController?
    private var busyObserver: AnyCancellable?
    private let relaunchGate: UpdateRelaunchGate

    init(store: ReclaimStore, bundle: Bundle = .main) {
        self.store = store
        relaunchGate = UpdateRelaunchGate(isBusy: { store.isBusy })
        enabled = UpdatePolicy.permitsUpdates(
            identifier: bundle.bundleIdentifier,
            channel: bundle.object(forInfoDictionaryKey: "ReclaimBuildChannel") as? String,
            feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            isDemo: store.isDemo)
        super.init()
        guard enabled else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticChecks)
        // Sparkle can finish downloading while a purge is in progress. Let the
        // operation and its refresh finish before allowing the requested restart.
        busyObserver = store.$busyMessage.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.relaunchGate.resumeIfIdle()
        }
        controller.startUpdater()
    }

    func check() {
        guard !store.isBusy else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !store.isBusy else {
            throw NSError(domain: "Reclaim.Updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Wait for the current storage operation to finish, then check for updates again."])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        relaunchGate.postponeIfBusy(installHandler)
    }
}

struct UpdateCommands: Commands {
    @ObservedObject var updates: UpdateController
    @ObservedObject var store: ReclaimStore

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updates.enabled {
                Button("Check for Updates…") { updates.check() }
                    .disabled(!updates.canCheck || store.isBusy)
                Toggle("Automatically Check for Updates", isOn: Binding(
                    get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
            } else {
                Button("Updates Disabled in Development Builds") {}.disabled(true)
                Button("Open Reclaim in Applications") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Reclaim.app"))
                }.disabled(!FileManager.default.fileExists(atPath: "/Applications/Reclaim.app"))
            }
            Button("Download Latest Release…") { NSWorkspace.shared.open(UpdatePolicy.downloads) }
        }
    }
}
