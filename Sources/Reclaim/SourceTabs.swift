import AppKit
import SwiftUI

/// Use native tab sizing so the selection fits the toolbar's glass container.
struct SourceTabs: NSViewRepresentable {
    @Binding var selection: Source

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: Source.allCases.map(\.rawValue), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.selectSource(_:)))
        control.segmentStyle = .automatic
        control.controlSize = .large
        control.segmentDistribution = .fit
        if #available(macOS 26.0, *) { control.borderShape = .capsule }
        if #available(macOS 27.0, *) { control.role = .tabs }
        control.setAccessibilityLabel("Source")
        control.selectedSegment = Source.allCases.firstIndex(of: selection) ?? 0
        control.sizeToFit()
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = Source.allCases.firstIndex(of: selection) ?? 0
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<Source>
        init(selection: Binding<Source>) { self.selection = selection }
        @objc func selectSource(_ sender: NSSegmentedControl) {
            guard Source.allCases.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = Source.allCases[sender.selectedSegment]
        }
    }
}
