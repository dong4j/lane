import SwiftUI
import PortlaneCore

/// Clipboard feedback occupies the existing button, including in the menu panel.
struct CopyAction: View {
    let model: PortlaneModel
    let value: String
    let key: String
    let title: String
    var prominent = false
    var iconOnly = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let copied = model.copied == key
        Button {
            model.copy(value, key: key)
        } label: {
            ZStack {
                if iconOnly {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 14)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                } else {
                    Label(title, systemImage: "doc.on.doc").opacity(copied ? 0 : 1)
                    if copied { Label(L10n.text("Copied", "已复制"), systemImage: "checkmark") }
                }
            }
            .animation(reduceMotion ? nil : LaneMotion.crossfade, value: copied)
        }
        .buttonStyle(LaneButtonStyle(kind: prominent ? .primary : iconOnly ? .subtle : .neutral))
        .fixedSize()
        .help("\(title) · \(value)")
        .accessibilityLabel(copied ? L10n.text("Copied", "已复制") : "\(title), \(value)")
    }
}

/// The selector is shared by the editor and onboarding, keeping labels and arrows consistent.
struct ForwardingModePicker: View {
    @Binding var kind: ForwardingKind
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let style = PortlaneStyle(scheme: scheme)
        HStack(spacing: 3) {
            ForEach(ForwardingKind.allCases) { option in
                Button {
                    kind = option
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: option.routeIcon).font(.system(size: 12, weight: .medium))
                        Text(option.displayLabel).font(.system(size: 12, weight: kind == option ? .semibold : .medium))
                            .lineLimit(1)
                        Text(option.flag).font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundStyle(kind == option ? style.ink(option) : style.secondary)
                    .frame(maxWidth: .infinity, minHeight: 31)
                    .background(kind == option ? style.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        if kind == option { RoundedRectangle(cornerRadius: 7).strokeBorder(style.edge) }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.displayLabel) \(option.flag)")
                .accessibilityAddTraits(kind == option ? .isSelected : [])
            }
        }
        .padding(3)
        .background(style.control, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Forwarding type", "转发类型"))
    }
}
