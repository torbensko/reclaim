import AppKit
import SwiftUI
import ReclaimCore

/// The same inventory and decisions drive Overview and the new source details.
struct OpportunitiesView: View {
    @ObservedObject var store: ReclaimStore
    @Binding var search: String
    @Binding var recommendedOnly: Bool
    @Binding var action: CleanupAction?
    @State private var detail: CleanupOpportunity?

    var rows: [CleanupOpportunity] { store.opportunities.filter { store.source == .overview || $0.source == store.source } }
    var matching: [CleanupOpportunity] {
        rows.filter { (search.isEmpty || $0.searchable.localizedCaseInsensitiveContains(search)) && (!recommendedOnly || $0.eligibility.isRecommended) }
    }
    private var selected: [CleanupOpportunity] { matching.filter { store.selection.contains($0.id) } }
    private var removable: [CleanupOpportunity] { selected.filter { $0.action != nil && $0.eligibility.canClean } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.source == .overview ? "Cleanup suggestions" : store.source.rawValue).font(.headline)
                Text("\(rows.count) found · \(rows.filter { $0.eligibility.isRecommended }.count) recommended · \(rows.filter { $0.eligibility.needsReview }.count) review")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Toggle("Recommended only", isOn: $recommendedOnly).toggleStyle(.checkbox)
                TextField("Filter items", text: $search).textFieldStyle(.roundedBorder).frame(width: 170)
            }.padding(.horizontal, 18).padding(.vertical, 10)
            if store.source == .overview {
                let unavailable = Source.allCases.filter { store.errors[$0] != nil }
                if !unavailable.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        ForEach(unavailable) { source in
                            Button("\(source.rawValue) unavailable…") { store.source = source }.buttonStyle(.link)
                        }
                        Spacer()
                    }.font(.caption).padding(.horizontal, 18).padding(.bottom, 8)
                }
            }
            Table(of: CleanupOpportunity.self, selection: $store.selection) {
                TableColumn("") { item in
                    Toggle("Select \(item.name)", isOn: Binding(
                        get: { store.selection.contains(item.id) },
                        set: { if $0 { store.selection.insert(item.id) } else { store.selection.remove(item.id) } }
                    )).labelsHidden().toggleStyle(.checkbox).disabled(store.isBusy)
                }.width(24)
                TableColumn("Item") { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).lineLimit(1)
                        Text(item.source.rawValue + (item.path.map { " · " + ($0 as NSString).abbreviatingWithTildeInPath } ?? ""))
                            .font(.caption).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    }.padding(.vertical, 4).foregroundStyle(item.eligibility.canClean ? .primary : .secondary)
                        .help(item.path ?? item.evidence)
                }.width(min: 180, ideal: 260)
                TableColumn("Private bytes") { Text($0.privateBytes.map(formatBytes) ?? "—").monospacedDigit().foregroundStyle(.secondary) }.width(95)
                TableColumn("Footprint") { Text($0.bytes.map(formatBytes) ?? "—").monospacedDigit().foregroundStyle(.secondary) }.width(90)
                TableColumn("Last changed") { Text($0.changed?.formatted(date: .abbreviated, time: .omitted) ?? "—").foregroundStyle(.secondary) }.width(100)
                TableColumn("Reason") { item in
                    Text(item.reason)
                        .lineLimit(2).font(.callout).foregroundStyle(item.eligibility.canClean ? .primary : .secondary)
                        .help(item.evidence + "\n" + item.eligibility.explanation)
                }.width(min: 180, ideal: 260)
                TableColumn("") { item in
                    Button(item.action == nil ? "Details" : "Review…") {
                        if item.action != nil { action = store.cleanupPlan(for: [item]) } else { detail = item }
                    }.disabled(item.action != nil && !store.canAct)
                }.width(80)
            } rows: {
                let recommended = matching.filter { $0.eligibility.isRecommended }
                let review = matching.filter { $0.eligibility.needsReview }
                let protected = matching.filter { !$0.eligibility.canClean }
                if !recommended.isEmpty {
                    Section("Recommended · \(recommended.count)") { ForEach(recommended) { TableRow($0) } }
                }
                if !review.isEmpty {
                    Section("Review first · \(review.count)") { ForEach(review) { TableRow($0) } }
                }
                if !protected.isEmpty {
                    Section("Protected · \(protected.count)") { ForEach(protected) { TableRow($0) } }
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let item = rows.first(where: { ids.contains($0.id) }) {
                    Button("Details") { detail = item }
                    Button("Show \(item.source.rawValue)") { store.source = item.source }
                    if let path = item.path {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    }
                }
            } primaryAction: { ids in detail = rows.first { ids.contains($0.id) } }
            .overlay {
                if matching.isEmpty && !store.isBusy {
                    VStack(spacing: 10) {
                        Text(rows.isEmpty ? "No supported items found" : "No items match this filter").font(.headline)
                        Text(rows.isEmpty ? "Source tabs show coverage and any inspection failures." : "\(rows.count) found in this inventory. Review and protected items may still be available.")
                            .foregroundStyle(.secondary)
                        if recommendedOnly { Button("Show review and protected items") { recommendedOnly = false } }
                    }.padding(20)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Toggle("Select all", isOn: Binding(
                    get: { !matching.isEmpty && Set(matching.map(\.id)).isSubset(of: store.selection) },
                    set: { if $0 { store.selection.formUnion(matching.map(\.id)) } else { store.selection.subtract(matching.map(\.id)) } }
                )).toggleStyle(.checkbox).disabled(store.isBusy || matching.isEmpty)
                Text("\(selected.count) selected · \(removable.count) removable (\(removable.filter { $0.eligibility.needsReview }.count) review)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Select recommended") { store.selection = Set(matching.filter { $0.eligibility.isRecommended }.map(\.id)) }
                    .disabled(store.isBusy || !matching.contains { $0.eligibility.isRecommended })
                Button("Remove selected…") { action = store.cleanupPlan(for: selected) }
                    .disabled(!store.canAct || removable.isEmpty)
                    .help(store.actionBlockReason ?? "Confirm the exact items and consequences. Protected selections are excluded.")
            }.padding(.horizontal, 18).padding(.vertical, 12)
        }
        .sheet(item: $detail) { item in
            VStack(alignment: .leading, spacing: 14) {
                Text(item.name).font(.headline)
                ScrollView { Text(item.confirmation + "\n\n" + item.eligibility.explanation).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    if let path = item.path { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
                    Button("Show \(item.source.rawValue)") { detail = nil; store.source = item.source }
                    Spacer()
                    Button("Done") { detail = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 580, height: 350)
        }
    }
}
