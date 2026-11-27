import SwiftUI

/// Disclosure headers share one hit target for the title, whitespace, and trailing indicator.
struct LaneDisclosureRow<Content: View>: View {
    @Binding var isExpanded: Bool
    var minHeight: CGFloat = 28
    var inset: CGFloat = 0
    @ViewBuilder let content: () -> Content

    var body: some View {
        LaneDisclosureButton(isExpanded: $isExpanded) {
            HStack(spacing: 8) {
                content().frame(maxWidth: .infinity, alignment: .leading)
                LaneDisclosureChevron(expanded: isExpanded)
            }
            .padding(.horizontal, inset)
            .frame(minHeight: minHeight)
        }
    }
}

/// The same native button can sit behind a menu row that has an independent connection action.
struct LaneDisclosureButton<Label: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder let label: () -> Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : LaneMotion.disclosure) { isExpanded.toggle() }
        } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(LaneHoverHighlight())
        .accessibilityValue(isExpanded ? L10n.text("Expanded", "已展开") : L10n.text("Collapsed", "已收起"))
    }
}

/// The indicator is visual only. Pointer and keyboard activation belong to the header button.
struct LaneDisclosureChevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .frame(width: 14)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Retains each DisclosureGroup's expansion binding and keeps its detail controls outside the header.
struct LaneDisclosureStyle: DisclosureGroupStyle {
    let minHeight: CGFloat
    let inset: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LaneDisclosureRow(isExpanded: configuration.$isExpanded, minHeight: minHeight, inset: inset) {
                configuration.label
            }
            if configuration.isExpanded { configuration.content }
        }
    }
}
