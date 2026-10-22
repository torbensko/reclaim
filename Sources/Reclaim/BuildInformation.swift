import AppKit

/// Build provenance is stamped into the bundle before signing, for every channel.
struct BuildInformation {
    static let current = BuildInformation()

    private let bundle = Bundle.main
    var version: String { value("CFBundleShortVersionString") ?? "Unpackaged" }
    var number: String { value("CFBundleVersion") ?? "—" }
    var name: String { value("CFBundleDisplayName") ?? "Reclaim Dev" }
    var channel: String { value("ReclaimBuildChannel") ?? "Unidentified build" }
    var title: String { "\(name) \(version) · \(channel)" }
    var source: String {
        guard let revision = value("ReclaimSourceRevision") else { return "Source revision unavailable" }
        let modified = bundle.object(forInfoDictionaryKey: "ReclaimSourceModified") as? Bool == true
        return "Source \(revision.prefix(8))\(modified ? " + local changes" : "")"
    }
    var date: String {
        guard let stamp = value("ReclaimBuildDate"), let date = ISO8601DateFormatter().date(from: stamp) else {
            return "Build time unavailable"
        }
        return "Built \(date.formatted(date: .abbreviated, time: .standard))"
    }
    var location: String { "Running from \(bundle.bundleURL.path)" }

    @MainActor func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: "\(version) · \(channel)",
            .version: number,
            .credits: NSAttributedString(string: "\(date)\n\(source)\n\n\(location)")
        ])
    }

    private func value(_ key: String) -> String? { bundle.object(forInfoDictionaryKey: key) as? String }
}
