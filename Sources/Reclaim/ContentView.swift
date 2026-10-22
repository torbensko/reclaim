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
    @State private var safeOnly = false
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
            if let message = store.resultMessage ?? store.errorMessage {
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
        .onChange(of: safeOnly) { _, _ in store.selection = [] }
        .onChange(of: search) { _, _ in store.selection = [] }
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
            if store.source == .overview {
                headline(freeSpace, label: "free now", detail: availableSpace)
            } else {
                reclaimableHeadline
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if store.source != .overview {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(freeSpace).font(.title3.weight(.semibold)).monospacedDigit()
                        Text("free on Internal SSD").font(.callout).foregroundStyle(.secondary)
                    }
                    Text(availableSpace).font(.caption).foregroundStyle(.secondary)
                }
                if store.isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(store.busyMessage ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                } else if store.source == .overview {
                    Label("Internal SSD", systemImage: "internaldrive").font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if store.monitoringStorage && !store.isBusy { ProgressView().controlSize(.mini) }
                    Text(store.storageStatus).font(.caption).foregroundStyle(.secondary)
                }.help(store.storageError ?? "Free space is measured independently of the source inventories. After cleanup, readings repeat for about a minute to catch delayed release.")
            }
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var freeSpace: String { store.storage.map { formatBytes($0.freeBytes) } ?? "—" }
    private var availableSpace: String {
        store.storage?.availableBytes.map { "\(formatBytes($0)) available including reclaimable space" } ?? "SSD available-space estimate unavailable"
    }

    private func headline(_ value: String, label: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().fixedSize()
                Text(label).font(.callout).foregroundStyle(.secondary)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }

    @ViewBuilder private var reclaimableHeadline: some View {
        if store.loading.contains(store.source) {
            headline("—", label: "reclaimable", detail: "Measuring \(store.source.rawValue)…")
        } else if store.errors[store.source] != nil {
            headline("—", label: "reclaimable", detail: "\(store.source.rawValue) unavailable")
        } else {
            switch store.source {
            case .overview:
                EmptyView()
            case .timeMachine:
                headline(store.report != nil && store.snapshots.isEmpty ? formatBytes(0) : "—",
                         label: "reclaimable",
                         detail: store.report == nil ? "Snapshot data unavailable" : store.snapshots.isEmpty ? "No local snapshots" : "\(store.snapshots.count) local snapshots · size unavailable in Reclaim")
                    .help("This reader does not report snapshot sizes. The SSD's available-space estimate is not a snapshot measurement. Use Snapshot sizes below for Disk Utility's measurements.")
            case .xcode, .browser:
                let report = store.source == .xcode ? store.xcode : store.browser
                let bytes = report?.applicablePrivateBytes
                headline(bytes.map(formatBytes) ?? "—", label: "reclaimable · private bytes",
                         detail: report.map { value in
                             if value.candidateCount == 0 { return "None safe to clean · \(value.entries.count) found" }
                             return "\(value.candidateCount) safe to clean · " + (bytes == nil ? "private size unavailable" : "shared blocks may free more")
                         } ?? "Source data unavailable")
                    .help("Private file bytes across all items safe to clean, independent of selection and filters. Protected items are excluded. " + privateSizeExplanation)
            case .docker:
                let report = store.docker
                if dockerKind == .image {
                    let kept = report?.items.filter { $0.kind == .image && !$0.inUse && !$0.eligibility.canClean }.count ?? 0
                    headline(report?.reclaimableImageBytes.map(formatBytes) ?? "—", label: "potentially reclaimable",
                             detail: report?.reclaimableImageBytes == nil ? "Docker's reclaimable estimate unavailable" : kept > 0 ? "Docker estimate · all unused images (\(kept) kept)" : "Docker estimate · all unused images")
                        .help("Docker's whole-image-store reclaimable estimate, independent of selection and filters. It includes unused images held by Reclaim's age or builder checks. It is not a total for safe-to-clean items or a promise of SSD recovery. Shared layer sizes must not be summed.")
                } else {
                    headline(report.map { formatBytes($0.reclaimableCacheBytes) } ?? "—", label: "potentially reclaimable",
                             detail: "Docker estimate · build cache is inspection-only")
                        .help("Docker reports unused cache, but Reclaim cannot verify project ownership and does not remove it. Let your build tools manage cleanup. Image and cache totals can overlap.")
                }
            }
        }
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
            SummaryRow(source: .xcode, detail: "\(store.xcode?.entries.count ?? 0) projects · build & index", size: store.xcode.map { formatBytes($0.bytes) } ?? "—", status: store.xcode.map { "\($0.candidateCount) safe · \($0.entries.count - $0.candidateCount) protected" } ?? "—", privateSize: store.xcode?.privateBytes.map(formatBytes) ?? "—"),
            SummaryRow(source: .docker, detail: "Images / build cache", size: store.docker.map { "\(formatBytes($0.imageBytes)) / \(formatBytes($0.cacheBytes))" } ?? "—", status: store.docker.map { "\($0.candidateCount) safe · cache protected" } ?? "—"),
            SummaryRow(source: .browser, detail: "Chrome signing copies & caches", size: store.browser.map { formatBytes($0.bytes) } ?? "—", status: store.browser.map { "\($0.candidateCount) safe · \($0.entries.count - $0.candidateCount) protected" } ?? "—", privateSize: store.browser?.privateBytes.map(formatBytes) ?? "—")
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
                    .help(store.actionBlockReason ?? (store.snapshots.isEmpty ? "No local snapshots to reclaim." : "Ask macOS to release space from local snapshots. No row selection is required."))
                Text("macOS chooses which local restore points to remove.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(18).frame(width: 210)
        }
    }

    private var eligibilityFilter: some View {
        Toggle("Safe only", isOn: $safeOnly).toggleStyle(.checkbox)
            .help("Show only items that pass the current safety checks. Turn off to also see protected items and why they are kept.")
    }

    private func cleanupColor(_ eligible: Bool) -> Color {
        eligible ? .primary : .secondary
    }

    private func tableHeading(_ title: String, count: Int, eligible: Int? = nil) -> some View {
        HStack {
            Text(title).font(.headline)
            Text(eligible.map { "\(count) found · \($0) safe" } ?? "\(count)").foregroundStyle(.secondary)
            Spacer()
            if eligible != nil { eligibilityFilter }
            searchField
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var matchingLocal: [LocalEntry] {
        store.localEntries.filter {
            matches($0.name + " " + $0.path + " " + ($0.ownerPath ?? "") + " " + $0.eligibility.explanation)
        }.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.id < $1.id
        }
    }
    private var localTable: some View {
        VStack(spacing: 0) {
            tableHeading(store.source == .xcode ? "Build & index data" : "Chrome data", count: store.localEntries.count,
                         eligible: store.localEntries.filter(\.eligible).count)
            Table(of: LocalEntry.self, selection: $store.selection) {
                TableColumn("Name") { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1)
                        Text(URL(fileURLWithPath: item.path).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(.vertical, 3).foregroundStyle(cleanupColor(item.eligible))
                        .help([item.path, item.ownerPath].compactMap { $0 }.joined(separator: "\nSource: "))
                }.width(min: 170, ideal: 240)
                TableColumn(store.source == .xcode ? "Source project" : "Kind") { item in
                    Text(item.ownerPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? item.kind.rawValue)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(cleanupColor(item.eligible))
                        .help(item.ownerPath.map { "Source workspace: \($0)\nCross-checked against ~/repos and Git’s registered worktrees. A project match is an ownership safeguard, not evidence of a running build." } ?? item.kind.rawValue)
                }.width(min: 120, ideal: store.source == .xcode ? 190 : 120)
                TableColumn("File blocks") { Text(formatBytes($0.bytes)).monospacedDigit().foregroundStyle(cleanupColor($0.eligible)).help("Allocated file blocks; APFS clones may share them with other rows. Not uniquely recoverable space.") }.width(110)
                TableColumn("Private bytes²") { Text($0.privateBytes.map(formatBytes) ?? "—").monospacedDigit().foregroundStyle(cleanupColor($0.eligible)).help(privateSizeExplanation) }.width(100)
                TableColumn("Last activity") { Text($0.modified.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(cleanupColor($0.eligible)) }.width(min: 140, ideal: 150)
                TableColumn("Cleanup") { item in
                    Text(item.eligibility.label).foregroundStyle(cleanupColor(item.eligible)).lineLimit(1).help(item.eligibility.explanation)
                }.width(min: 180, ideal: 230)
            } rows: {
                cleanupRows(matchingLocal, eligible: \.eligible)
            }
            .contextMenu(forSelectionType: String.self) { selected in
                if selected.count == 1, let item = store.localEntries.first(where: { selected.contains($0.id) }) {
                    Button("Show Data in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                    if let source = item.ownerPath {
                        Button("Show Source Project in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source)]) }
                            .disabled(!FileManager.default.fileExists(atPath: source))
                    }
                }
            }
            .overlay {
                if !store.loading.contains(store.source) {
                    if matchingLocal.isEmpty {
                        empty(store.localEntries.isEmpty ? "No data found" : "No matching data",
                              detail: store.localEntries.isEmpty ? "No supported \(store.source == .xcode ? "build or index data" : "Chrome data") was found." : "Try a different text filter. \(store.localEntries.count) items were found in total.")
                    } else if safeOnly && !matchingLocal.contains(where: \.eligible) {
                        noSafeItems(count: matchingLocal.count)
                    }
                }
            }
        }
    }

    private var dockerEntries: [DockerItem] { (store.docker?.items ?? []).filter { $0.kind == dockerKind } }
    private var dockerItems: [DockerItem] {
        dockerEntries.filter { matches($0.name + " " + $0.eligibility.explanation + " " + ($0.inUse ? "In use" : "Unused")) }.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.id < $1.id
        }
    }
    private var dockerTable: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Docker data", selection: $dockerKind) {
                    Text("Images").tag(DockerItem.Kind.image)
                    Text("Build cache").tag(DockerItem.Kind.buildCache)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
                Text("\(dockerEntries.count) found · \(dockerEntries.filter { $0.eligibility.canClean }.count) safe").foregroundStyle(.secondary)
                Spacer()
                eligibilityFilter
                searchField
            }.padding(.horizontal, 18).padding(.vertical, 10)
            Table(of: DockerItem.self, selection: $store.selection) {
                TableColumn("Name") { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1)
                        if item.kind == .image {
                            Text("\(item.id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) · \(item.references.tags.count) \(item.references.tags.count == 1 ? "tag" : "tags")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 3).foregroundStyle(cleanupColor(item.eligibility.canClean))
                        .help(item.kind == .image ? ([item.id] + item.references.tags + item.references.digests).joined(separator: "\n") : item.name)
                }.width(min: 210, ideal: 320)
                TableColumn("Size") { Text(formatBytes($0.bytes)).monospacedDigit().foregroundStyle(cleanupColor($0.eligibility.canClean)) }.width(90)
                TableColumn("Unique / shared") { item in
                    Text("\(item.uniqueBytes.map(formatBytes) ?? "—") / \(item.sharedBytes.map(formatBytes) ?? "—")")
                        .foregroundStyle(cleanupColor(item.eligibility.canClean))
                }.width(160)
                TableColumn(dockerKind == .image ? "Created" : "Last used") {
                    Text($0.lastUsed).foregroundStyle(cleanupColor($0.eligibility.canClean))
                }.width(100)
                TableColumn("Docker usage") { item in
                    Text(item.inUse ? "In use" : "Unused").foregroundStyle(cleanupColor(item.eligibility.canClean))
                        .help(item.containerCount.map { "\($0) running or stopped containers reference this image. This is Docker's usage definition; unused does not mean abandoned." } ?? "Docker's build cache usage flag does not identify whether the owning project is active.")
                }.width(110)
                TableColumn("Cleanup") { Text($0.eligibility.label).lineLimit(1).foregroundStyle(cleanupColor($0.eligibility.canClean)).help($0.eligibility.explanation) }.width(min: 170, ideal: 200)
            } rows: {
                cleanupRows(dockerItems, eligible: \.eligibility.canClean)
            }
            .overlay {
                if !store.loading.contains(.docker) {
                    if dockerItems.isEmpty {
                        empty(dockerEntries.isEmpty ? "No \(dockerKind == .image ? "images" : "build cache") found" : "No matching items",
                              detail: dockerEntries.isEmpty ? "Docker reported no \(dockerKind == .image ? "images" : "build cache") in its local inventory." : "Try a different text filter. \(dockerEntries.count) items were found in total.")
                    } else if safeOnly && !dockerItems.contains(where: { $0.eligibility.canClean }) {
                        noSafeItems(count: dockerItems.count)
                    }
                }
            }
        }
    }

    @TableRowBuilder<Item> private func cleanupRows<Item: Identifiable>(
        _ items: [Item], eligible: KeyPath<Item, Bool>
    ) -> some TableRowContent<Item> {
        let safe = items.filter { $0[keyPath: eligible] }
        let protected = items.filter { !$0[keyPath: eligible] }
        if !safe.isEmpty {
            Section("Safe to clean · \(safe.count)") {
                ForEach(safe) { TableRow($0) }
            }
        }
        if !safeOnly && !protected.isEmpty {
            Section("Protected · \(protected.count)") {
                ForEach(protected) { TableRow($0) }
            }
        }
    }

    private func noSafeItems(count: Int) -> some View {
        VStack(spacing: 10) {
            Text(search.isEmpty ? "Nothing safe to clean right now" : "No safe items match this filter").font(.headline)
            Text("\(count) \(count == 1 ? "item was" : "items were") found, but \(count == 1 ? "it is" : "they are") protected.")
                .foregroundStyle(.secondary)
            Button("Show protected items") { safeOnly = false }
        }.padding(20).background(.background.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
    }

    private var eligibleLocal: [LocalEntry] {
        store.localEntries.filter { store.selection.contains($0.id) && $0.eligible }
    }
    private var selectedImages: [String] {
        dockerItems.filter { store.selection.contains($0.id) && $0.eligibility.canClean && $0.kind == .image }.map(\.id)
    }

    private var visibleIDs: Set<String> {
        switch store.source {
        case .overview: []
        case .timeMachine: Set(store.snapshots.filter { matches($0.name) }.map(\.id))
        case .xcode, .browser: Set(matchingLocal.filter { !safeOnly || $0.eligible }.map(\.id))
        case .docker: Set(dockerItems.filter { !safeOnly || $0.eligibility.canClean }.map(\.id))
        }
    }

    private var selectAll: some View {
        let ids = visibleIDs
        return Toggle("Select all", isOn: Binding(
            get: { !ids.isEmpty && ids.isSubset(of: store.selection) },
            set: { selected in
                if selected { store.selection.formUnion(ids) }
                else { store.selection.subtract(ids) }
            }
        )).toggleStyle(.checkbox)
            .disabled(ids.isEmpty || store.isBusy || store.errors[store.source] != nil)
            .help("Select or deselect every item shown by the current filters. Protected items can be inspected but will not be removed.")
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
                selectAll
                Text("\(store.selection.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Snapshot sizes…") { showSnapshotSizes = true }.popover(isPresented: $showSnapshotSizes) { snapshotSizeHelp }
                Button("Delete Selected…") { action = .snapshot(.delete(names: store.selection.sorted())) }
                    .disabled(!store.canAct || store.selection.isEmpty)
            case .xcode, .browser:
                selectAll
                Text("\(store.selection.count) selected · \(eligibleLocal.count) safe").font(.caption).foregroundStyle(.secondary)
                if let item = store.localEntries.first(where: { store.selection.contains($0.id) }) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                }
                Spacer()
                Text(store.source == .xcode ? "Existing repositories and worktrees are protected." : "24-hour minimum · process and open-file checks")
                    .font(.caption).foregroundStyle(.secondary)
                Button(store.source == .xcode ? "Clear Safe Items…" : "Remove Safe Copies…") {
                    action = store.source == .xcode ? .xcode(eligibleLocal.map(\.id)) : .chrome(eligibleLocal.map(\.id))
                }.disabled(!store.canAct || eligibleLocal.isEmpty)
                    .help("Only selected items that pass the safety checks are removed. Protected items remain untouched.")
            case .docker:
                selectAll
                Text("\(store.selection.count) selected · \(selectedImages.count) safe").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if dockerKind == .image {
                    Text("Shared layers mean image sizes cannot be added together.").font(.caption).foregroundStyle(.secondary)
                    Button("Remove Safe Images…") { action = .images(selectedImages) }
                        .disabled(!store.canAct || selectedImages.isEmpty)
                        .help("Only selected images that pass the safety checks are removed. Protected images remain untouched.")
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
            VStack(alignment: .leading, spacing: 3) {
                Text(BuildInformation.current.title)
                Text("Build \(BuildInformation.current.number) · \(BuildInformation.current.source)")
                Text(BuildInformation.current.date)
                Text(BuildInformation.current.location)
            }
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Build tools can stop when physically free space is low, even when Finder reports plenty available. Reclaim shows free APFS container space separately from macOS’s estimate, which includes reclaimable data.")
            Text("File footprints can share blocks. Private bytes come from macOS and exclude blocks retained by other clones or snapshots; unknown values stay blank. Private-byte sums exclude directory metadata and can underestimate group cleanup. Docker's unique/shared layer sizes are shown separately. None is a guaranteed purge result.")
            Text("Reclaim is a safety net. Existing repositories and worktrees are protected, and uncertain usage keeps the data. Project tools remain responsible for their own worktree and cache lifecycle. Schedules apply the same checks as manual cleanup.")
            Button("Time Machine Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")!)
            }
        }.font(.callout).padding(20).frame(width: 380)
    }
}
