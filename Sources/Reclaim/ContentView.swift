import AppKit
import SwiftUI
import ReclaimCore

private struct SummaryRow: Identifiable {
    let source: Source
    let detail: String
    let size: String
    let status: String
    var privateSize: String = "—"
    var id: Source { source }
}

struct ContentView: View {
    @ObservedObject var store: ReclaimStore
    @State private var search = ""
    @State private var overviewSelection: Source?
    @State private var action: CleanupAction?
    @State private var showSchedule = false
    @State private var showHelp = false
    @State private var showDetails = false
    @State private var amount = 25
    @State private var urgent = false
    @State private var dockerKind = DockerItem.Kind.image
    @State private var candidatesOnly = true
    @State private var showSnapshotSizes = false

    var body: some View {
        VStack(spacing: 0) {
            storageHeader
            Divider()
            if let error = store.errors[store.source] {
                unavailable(error)
            } else {
                sourceContent
            }
            Divider()
            footer
            if let message = store.errorMessage ?? store.resultMessage {
                HStack(spacing: 8) {
                    Image(systemName: store.errorMessage == nil ? "info.circle" : "exclamationmark.triangle")
                    Text(message).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button("Details") { showDetails = true }.buttonStyle(.link)
                }
                .font(.callout)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(store.errorMessage == nil ? Color.accentColor.opacity(0.06) : Color.orange.opacity(0.08))
            }
        }
        .toolbar {
            sourceToolbar
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.isBusy).help("Refresh storage").accessibilityLabel("Refresh storage")
                Button { showSchedule = true } label: { Image(systemName: "clock.badge.checkmark") }
                    .help("Cleanup schedule").accessibilityLabel("Cleanup schedule")
                Button { showHelp = true } label: { Image(systemName: "info.circle") }
                    .help("About storage figures").accessibilityLabel("About storage figures")
                    .popover(isPresented: $showHelp) { helpContent }
            }
        }
        .onChange(of: store.source) { _, _ in store.selection = []; search = "" }
        .onChange(of: dockerKind) { _, _ in store.selection = [] }
        .onChange(of: candidatesOnly) { _, _ in store.selection = [] }
        .sheet(item: $action) { pending in
            VStack(alignment: .leading, spacing: 18) {
                Text(pending.title).font(.title3.bold())
                Text(pending.explanation).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { action = nil }.keyboardShortcut(.cancelAction)
                    Button(pending.confirmLabel, role: .destructive) {
                        action = nil
                        Task { await store.perform(pending) }
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 460)
        }
        .sheet(isPresented: $showSchedule) { ScheduleView(store: store) }
        .sheet(isPresented: $showDetails) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Last operation").font(.headline)
                ScrollView { Text([store.errorMessage, store.resultDetails].compactMap { $0 }.joined(separator: "\n\n")).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("Done") { showDetails = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 600, height: 340)
        }
    }

    @ToolbarContentBuilder private var sourceToolbar: some ToolbarContent {
        // AppKit sizes the tab selection; the toolbar supplies the single glass
        // container. Do not add glassEffect or a second custom capsule here.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) { sourcePicker }
                .sharedBackgroundVisibility(.visible)
        } else {
            ToolbarItem(placement: .principal) { sourcePicker }
        }
    }

    private var sourcePicker: some View {
        SourceTabs(selection: $store.source).fixedSize()
    }

    private var storageHeader: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(store.report?.storage.map { formatBytes($0.freeBytes) } ?? "—")
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("free now").font(.callout).foregroundStyle(.secondary)
                }
                Text(store.report?.storage?.availableBytes.map { "\(formatBytes($0)) available including reclaimable space" } ?? "Reading internal SSD storage")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isBusy {
                ProgressView().controlSize(.small)
                Text(store.busyMessage ?? "").font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Internal SSD", systemImage: "internaldrive").font(.callout).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }

    @ViewBuilder private var sourceContent: some View {
        switch store.source {
        case .overview: overview
        case .timeMachine: snapshots
        case .xcode, .browser: localTable
        case .docker: dockerTable
        }
    }

    private var rows: [SummaryRow] {
        [
            SummaryRow(source: .timeMachine, detail: "\(store.snapshots.count) local restore points", size: "Unavailable here", status: "Manual · restore history"),
            SummaryRow(source: .xcode, detail: "\(store.xcode?.entries.count ?? 0) projects · build & index", size: store.xcode.map { formatBytes($0.bytes) } ?? "—", status: store.xcode.map { "\($0.candidateCount) candidates · \($0.entries.count - $0.candidateCount) kept" } ?? "—", privateSize: store.xcode?.privateBytes.map(formatBytes) ?? "—"),
            SummaryRow(source: .docker, detail: "Images / build cache", size: store.docker.map { "\(formatBytes($0.imageBytes)) / \(formatBytes($0.cacheBytes))" } ?? "—", status: store.docker.map { "\($0.candidateCount) candidates · cache kept" } ?? "—"),
            SummaryRow(source: .browser, detail: "Chrome signing copies & caches", size: store.browser.map { formatBytes($0.bytes) } ?? "—", status: store.browser.map { "\($0.candidateCount) candidates · \($0.entries.count - $0.candidateCount) kept" } ?? "—", privateSize: store.browser?.privateBytes.map(formatBytes) ?? "—")
        ]
    }

    private var overview: some View {
        Table(rows, selection: $overviewSelection) {
            TableColumn("Source") { row in
                HStack(spacing: 10) {
                    Image(systemName: row.source.symbol).foregroundStyle(.secondary).frame(width: 20)
                    Button(row.source.rawValue) { store.source = row.source }.buttonStyle(.plain).fontWeight(.medium)
                }.padding(.vertical, 8)
            }.width(min: 130, ideal: 170)
            TableColumn("Contents") { row in Text(store.loading.contains(row.source) ? "Reading…" : store.errors[row.source] == nil ? row.detail : "Unavailable").foregroundStyle(.secondary) }
            TableColumn("Footprint¹") { row in
                Text(store.loading.contains(row.source) ? "Measuring…" : store.errors[row.source] == nil ? row.size : "—").monospacedDigit()
            }.width(min: 150, ideal: 180)
            TableColumn("Private bytes²") { Text($0.privateSize).monospacedDigit().help(privateSizeExplanation) }.width(110)
            TableColumn("Status") { row in
                Text(store.errors[row.source] == nil ? row.status : "Open for details").foregroundStyle(.secondary)
            }.width(min: 160, ideal: 220)
        }
        .contextMenu(forSelectionType: Source.self) { selected in
            if let source = selected.first { Button("Show \(source.rawValue)") { store.source = source } }
        } primaryAction: { selected in
            if let source = selected.first { store.source = source }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter \(store.source.rawValue.lowercased())", text: $search).textFieldStyle(.plain)
            if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
        }.padding(7).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7)).frame(width: 240)
    }

    private func matches(_ value: String) -> Bool { search.isEmpty || value.localizedCaseInsensitiveContains(search) }

    private var snapshots: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                tableHeading("Local snapshots", count: store.snapshots.count)
                Table(store.snapshots.filter { matches($0.name) }, selection: $store.selection) {
                    TableColumn("Created") { item in
                        Text(item.date?.formatted(date: .abbreviated, time: .standard) ?? item.name)
                    }
                    TableColumn("Private size") { _ in Text("—").foregroundStyle(.secondary).help("This snapshot reader does not expose private or cumulative size. See Snapshot sizes below.") }.width(90)
                    TableColumn("Purgeable") { item in Text(item.purgeable.map { $0 ? "Yes" : "No" } ?? "Unknown").foregroundStyle(.secondary) }.width(90)
                }.overlay { if store.snapshots.isEmpty && !store.loading.contains(.timeMachine) { empty("No local snapshots", detail: "There are no Time Machine restore points to remove.") } }
            }
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text("Reclaim space").font(.headline)
                Picker("Request", selection: $amount) {
                    ForEach([5, 10, 25, 50, 100, 250], id: \.self) { Text("\($0) GB").tag($0) }
                }
                Toggle("Urgent", isOn: $urgent).toggleStyle(.checkbox)
                Button("Reclaim \(amount) GB…") { action = .snapshot(.reclaim(gigabytes: amount, urgency: urgent ? 4 : 1)) }
                    .buttonStyle(.borderedProminent).disabled(!store.canAct || store.snapshots.isEmpty)
                Text("macOS chooses which local restore points to remove.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(18).frame(width: 210)
        }
    }

    private func tableHeading(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.headline)
            Text("\(count)").foregroundStyle(.tertiary)
            Spacer()
            if store.source == .xcode || store.source == .browser {
                Toggle("Candidates only", isOn: $candidatesOnly).toggleStyle(.checkbox)
            }
            searchField
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var visibleLocal: [LocalEntry] {
        store.localEntries.filter { (!candidatesOnly || $0.eligible) && matches($0.name + " " + $0.path + " " + ($0.ownerPath ?? "")) }
    }
    private var localTable: some View {
        VStack(spacing: 0) {
            tableHeading(store.source == .xcode ? "Build & index data" : "Chrome data", count: store.localEntries.count)
            Table(visibleLocal, selection: $store.selection) {
                TableColumn("Name") { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1)
                        Text(URL(fileURLWithPath: item.path).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(.vertical, 3).help([item.path, item.ownerPath].compactMap { $0 }.joined(separator: "\nSource: "))
                }.width(min: 220, ideal: 340)
                TableColumn("Kind") { Text($0.kind.rawValue).foregroundStyle(.secondary) }.width(120)
                TableColumn("File blocks") { Text(formatBytes($0.bytes)).monospacedDigit().help("Allocated file blocks; APFS clones may share them with other rows. Not uniquely recoverable space.") }.width(110)
                TableColumn("Private bytes²") { Text($0.privateBytes.map(formatBytes) ?? "—").monospacedDigit().help(privateSizeExplanation) }.width(100)
                TableColumn("Last activity") { Text($0.modified.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }.width(min: 160, ideal: 170)
                TableColumn("Cleanup") { item in
                    Text(item.eligibility.label).foregroundStyle(item.eligible ? .primary : .secondary).lineLimit(1).help(item.eligibility.explanation)
                }.width(min: 180, ideal: 230)
            }.overlay {
                if visibleLocal.isEmpty && !store.loading.contains(store.source) {
                    VStack(spacing: 10) {
                        Text(candidatesOnly ? "No safe cleanup candidates" : "No matching data").font(.headline)
                        Text(candidatesOnly ? "Active, recent and unverified items are kept." : "Try a different filter.").foregroundStyle(.secondary)
                        if candidatesOnly { Button("Show All Data") { candidatesOnly = false } }
                    }.padding(24).background(.background.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var dockerItems: [DockerItem] { (store.docker?.items ?? []).filter { $0.kind == dockerKind && (dockerKind == .buildCache || !candidatesOnly || $0.eligibility.canClean) && matches($0.name) } }
    private var dockerTable: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Docker data", selection: $dockerKind) {
                    Text("Images").tag(DockerItem.Kind.image)
                    Text("Build cache").tag(DockerItem.Kind.buildCache)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
                Spacer()
                if dockerKind == .image { Toggle("Candidates only", isOn: $candidatesOnly).toggleStyle(.checkbox) }
                searchField
            }.padding(.horizontal, 18).padding(.vertical, 10)
            Table(dockerItems, selection: $store.selection) {
                TableColumn("Name") { Text($0.name).lineLimit(1).help($0.name) }.width(min: 230, ideal: 360)
                TableColumn("Size") { Text(formatBytes($0.bytes)).monospacedDigit() }.width(90)
                TableColumn("Unique / shared") { item in
                    Text(item.uniqueBytes.map { formatBytes($0) } ?? "—") + Text(" / ") + Text(item.sharedBytes.map { formatBytes($0) } ?? "—")
                }.width(160)
                TableColumn("Docker usage") { item in
                    Text(item.inUse ? "In use" : "Unused").foregroundStyle(.secondary)
                        .help(item.containerCount.map { "\($0) running or stopped containers reference this image. This is Docker's usage definition; unused does not mean abandoned." } ?? "Docker's build cache usage flag does not identify whether the owning project is active.")
                }.width(110)
                TableColumn("Cleanup") { Text($0.eligibility.label).lineLimit(1).help($0.eligibility.explanation) }.width(min: 170, ideal: 200)
            }.overlay {
                if dockerItems.isEmpty && !store.loading.contains(.docker) {
                    VStack(spacing: 10) {
                        Text(candidatesOnly ? "No safe cleanup candidates" : "No matching items").font(.headline)
                        Text("Tagged images, container references and active builds are protected.").font(.callout).foregroundStyle(.secondary)
                        if candidatesOnly { Button("Show All Data") { candidatesOnly = false } }
                    }.padding(24).background(.background.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var eligibleLocal: [LocalEntry] {
        store.localEntries.filter { store.selection.contains($0.id) && $0.eligible }
    }
    private var selectedImages: [String] {
        dockerItems.filter { store.selection.contains($0.id) && $0.eligibility.canClean && $0.kind == .image }.map(\.id)
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 12) {
            switch store.source {
            case .overview:
                Text("¹ Shared blocks can overlap.  ² Private bytes exclude shared blocks; not a purge guarantee.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(store.scheduleLabel + "…") { showSchedule = true }
                Button("Show Source") { if let overviewSelection { store.source = overviewSelection } }.disabled(overviewSelection == nil)
            case .timeMachine:
                Button("Snapshot sizes…") { showSnapshotSizes = true }.popover(isPresented: $showSnapshotSizes) { snapshotSizeHelp }
                Text("\(store.selection.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Delete Selected…") { action = .snapshot(.delete(names: store.selection.sorted())) }
                    .disabled(!store.canAct || store.selection.isEmpty)
            case .xcode, .browser:
                Text("\(store.selection.count) selected").font(.caption).foregroundStyle(.secondary)
                if let item = store.localEntries.first(where: { store.selection.contains($0.id) }) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                }
                Spacer()
                Text(store.source == .xcode ? "Existing repositories and worktrees are protected." : "24-hour minimum · process and open-file checks")
                    .font(.caption).foregroundStyle(.secondary)
                Button(store.source == .xcode ? "Clear Selected…" : "Remove Selected Copies…") {
                    action = store.source == .xcode ? .xcode(eligibleLocal.map(\.id)) : .chrome(eligibleLocal.map(\.id))
                }.disabled(!store.canAct || eligibleLocal.isEmpty || eligibleLocal.count != store.selection.count)
            case .docker:
                Text("Unused: no running or stopped containers. Tagged images are kept.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if dockerKind == .image {
                    Button("Remove Selected…") { action = .images(selectedImages) }
                        .disabled(!store.canAct || selectedImages.isEmpty || selectedImages.count != store.selection.count)
                } else {
                    Text("Build cache is managed by your build tools.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func empty(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }.padding(20).background(.background.opacity(0.94), in: RoundedRectangle(cornerRadius: 10)).allowsHitTesting(false)
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.secondary)
            Text("\(store.source.rawValue) unavailable").font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).multilineTextAlignment(.center).frame(maxWidth: 600)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private var privateSizeExplanation: String {
        "macOS's private-size attribute counts file bytes not held by another clone or snapshot. This is a conservative sum of individually private file data, excluding multiply linked files and directory metadata. Deleting several copies together can recover additional shared blocks. Unknown is shown as —."
    }

    private var snapshotSizeHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snapshot size is unavailable in Reclaim").font(.headline)
            Text("The earlier free/available figures describe the whole SSD. They are not a measurement of Time Machine storage.")
            Text("Disk Utility can show Private Size and Cumulative Size. The supported listing command used here does not provide those values on this Mac. Adding file sizes or using the available-space gap would misattribute shared blocks.")
            Text("For Apple's measurements, open Disk Utility, select the internal Data volume, and choose View → Show APFS Snapshots. Enable its Private Size and Cumulative Size columns. Do not add cumulative figures together.")
            Button("Open Disk Utility") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app")) }
        }.font(.callout).padding(20).frame(width: 410)
    }

    private var helpContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Space for the next build").font(.headline)
            Text("Build tools can stop when physically free space is low, even when Finder reports plenty available. Reclaim shows free APFS container space separately from macOS’s estimate, which includes reclaimable data.")
            Text("File footprints can share blocks. Private bytes come from macOS and exclude blocks retained by other clones or snapshots; unknown values stay blank. Private-byte sums exclude directory metadata and can underestimate group cleanup. Docker's unique/shared layer sizes are shown separately. None is a guaranteed purge result.")
            Text("Reclaim is a safety net. Existing repositories and worktrees are protected, and uncertain usage keeps the data. Project tools remain responsible for their own worktree and cache lifecycle. Schedules apply the same checks as manual cleanup.")
            Button("Time Machine Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")!)
            }
        }.font(.callout).padding(20).frame(width: 380)
    }
}
