import AppKit
import SwiftUI
import ReclaimCore

struct BackupSettingsView: View {
    @ObservedObject var store: ReclaimStore
    @State private var requestedMode: BackupMode?
    @State private var showHelp = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: store.backupMode == .automatic ? "clock.badge.exclamationmark" : "clock.arrow.circlepath")
                .foregroundStyle(store.backupMode == .automatic ? Color.orange : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("About Time Machine backup mode")
                .popover(isPresented: $showHelp) { help }
            Spacer(minLength: 12)
            if store.checkingBackupMode || store.changingBackupMode {
                ProgressView().controlSize(.small).accessibilityLabel("Checking macOS backup mode")
            }
            if let mode = store.backupMode {
                Toggle("Manual backups", isOn: Binding(
                    get: { mode == .manual },
                    set: { requestedMode = $0 ? .manual : .automatic }
                ))
                .toggleStyle(.switch).controlSize(.small)
                .disabled(!store.canChangeBackupMode)
                .help("Shortcut to macOS’s Time Machine setting. Changes require confirmation and administrator authorization.")
            } else if !store.checkingBackupMode {
                Button("Check Again") { Task { await store.refreshBackupMode() } }
                    .disabled(store.changingBackupMode)
            }
            Button("System Settings…") { Self.openSystemSettings() }
                .help("Open Time Machine. Choose Options → Backup Frequency to view the macOS setting.")
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(store.backupMode == .automatic ? Color.orange.opacity(0.05) : Color.clear)
        .sheet(item: $requestedMode) { mode in
            VStack(alignment: .leading, spacing: 16) {
                Text(mode == .manual ? "Turn on manual backups?" : "Turn on automatic backups?").font(.title3.bold())
                Text("This changes macOS’s Time Machine setting for this Mac. It is the same automatic-backup setting found under System Settings → General → Time Machine → Options.")
                if mode == .manual {
                    Text("Automatic backups will stop. To back up, connect your backup disk and choose Back Up Now from the Time Machine menu. Connecting the disk alone will not start a backup.")
                    Text("macOS may remove existing local restore points after this change. Routine hourly local snapshots stop, but space release can take several minutes and macOS update snapshots can still exist. Existing backups on your backup disk are kept.")
                } else {
                    Text("Time Machine will back up automatically again and can keep hourly local snapshots on the internal SSD. Review the backup frequency in System Settings.")
                }
                Text("macOS will ask for administrator authorization.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { requestedMode = nil }.keyboardShortcut(.cancelAction)
                    Button(mode == .manual ? "Turn On Manual Backups" : "Turn On Automatic Backups") {
                        requestedMode = nil
                        Task { await store.changeBackupMode(to: mode) }
                    }.keyboardShortcut(.defaultAction)
                        .disabled(!store.canChangeBackupMode)
                }
            }.fixedSize(horizontal: false, vertical: true).padding(24).frame(width: 480)
        }
    }

    private var title: String {
        if store.changingBackupMode { return "Changing macOS backup mode…" }
        if store.checkingBackupMode { return "Checking macOS backup mode…" }
        switch store.backupMode {
        case .manual: return "Manual backups are on"
        case .automatic: return "Automatic backups are on"
        case nil: return "Backup mode unavailable"
        }
    }

    private var detail: String {
        switch store.backupMode {
        case .manual: "macOS setting · Connect your backup disk, then choose Back Up Now."
        case .automatic: "macOS setting · Manual backups avoid routine hourly local snapshots."
        case nil: "Check Options → Backup Frequency in Time Machine settings."
        }
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A shortcut to the macOS setting").font(.headline)
            Text("This switch reads and changes Time Machine’s automatic-backup setting. It is not a separate Reclaim schedule. Reclaim checks again when you return from System Settings.")
            Text("Manual mode turns off automatic backups and routine hourly local snapshots. Choose Back Up Now when your backup disk is connected. You lose automatic backup protection and the local history between backups.")
            Text("Existing local snapshots may take several minutes to disappear. macOS update snapshots can still exist. This is not a storage cap or a guarantee of immediate free space.")
            if let error = store.backupModeError {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Link("Apple: About local snapshots", destination: URL(string: "https://support.apple.com/en-au/102154")!)
            Button("Open Time Machine Settings") { Self.openSystemSettings() }
        }.font(.callout).padding(20).frame(width: 390)
    }

    static func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")!)
    }
}
