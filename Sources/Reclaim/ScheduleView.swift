import SwiftUI
import ReclaimCore

struct ScheduleView: View {
    @ObservedObject var store: ReclaimStore
    @Environment(\.dismiss) private var dismiss
    @State private var config = ScheduleConfiguration()
    @State private var replaceLegacy = false
    @State private var confirming = false
    private var hasLegacy: Bool { store.schedule.map { $0.legacyPresent || $0.legacyLoaded } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Cleanup schedule").font(.title2.bold())
                Spacer()
                Text(store.schedule?.loaded == true && store.schedule?.configuration.enabled == true ? "On" : "Off")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Toggle("Enable scheduled cleanup", isOn: $config.enabled)
            Picker("Check every", selection: $config.intervalHours) {
                Text("Hour").tag(1)
                Text("6 hours").tag(6)
                Text("Day").tag(24)
            }.pickerStyle(.segmented).disabled(!config.enabled)
            VStack(alignment: .leading, spacing: 14) {
                rule("Chrome signing copies", detail: "Older than 24 hours · no matching processes or open files", value: $config.chrome)
                rule("Xcode build & index data", detail: "Source gone · inactive for 7 days · no active worktree or build", value: $config.xcode)
                Text("Docker build cache is protected; project ownership cannot be verified.").font(.caption).foregroundStyle(.secondary)
            }.disabled(!config.enabled)
            Text("Runs while you are logged in, even with Reclaim closed. No cleanup runs when you save. Time Machine, Docker images and browser profiles stay manual or untouched.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if hasLegacy {
                Divider()
                Text("Existing Chrome cleanup job").font(.headline)
                Text("The detected job runs hourly with a 12-hour threshold. Reclaim can replace it with a 24-hour minimum and process/open-file checks, keeping a backup of the old settings.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Replace the existing job", isOn: $replaceLegacy).disabled(!config.enabled || !config.chrome)
            }
            if let last = store.schedule?.lastRun {
                Divider()
                DisclosureGroup("Last run · \(last.date.formatted(date: .abbreviated, time: .shortened))") {
                    ScrollView { Text(last.outcomes.joined(separator: "\n\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
                }
            }
            if let error = store.scheduleError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.isBusy)
                Button(config.enabled ? "Save Schedule…" : "Save") {
                    if config.enabled { confirming = true } else { save() }
                }.keyboardShortcut(.defaultAction)
                    .disabled(store.isBusy || store.isDemo || (config.enabled && (!config.chrome && !config.xcode || hasLegacy && config.chrome && !replaceLegacy)))
            }
        }
        .padding(24).frame(width: 510)
        .onAppear { config = store.schedule?.configuration ?? ScheduleConfiguration(); config.docker = false }
        .confirmationDialog("Enable these recurring cleanup rules?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Enable Schedule", role: .destructive) { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reclaim will permanently remove eligible data using the selected rules every \(config.intervalHours) hour\(config.intervalHours == 1 ? "" : "s"). Rebuilds may take longer. \(hasLegacy && config.chrome ? "The existing Chrome job will be backed up and replaced." : "")")
        }
    }
    private func rule(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: value)
            Text(detail).font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
        }
    }
    private func save() {
        Task { if await store.saveSchedule(config, replaceLegacy: replaceLegacy) { dismiss() } }
    }
}
