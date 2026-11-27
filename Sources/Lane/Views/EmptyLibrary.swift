import SwiftUI
import LaneCore

/// First-run mode examples lead directly to a real, empty editor of the selected type.
struct EmptyLibrary: View {
    let model: LaneModel
    @State private var kind: ForwardingKind = .local
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let style = LaneStyle(scheme: scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                Text(L10n.text("Tunnels", "隧道")).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(style.secondary).frame(height: 32)
                LaneGlyph(size: 42, tinted: false)
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.text("Choose a forwarding type", "选择一种转发方式"))
                        .font(.system(size: 28, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text(L10n.text("See where the connection starts and what address the client should use.",
                                   "先看连接从哪里发起，以及客户端要填写哪个地址。"))
                        .font(.callout).foregroundStyle(style.secondary)
                }
                ForwardingModePicker(kind: $kind)
                RouteDiagram(forwarding: DemoContent.rule(kind), sshHost: "dev-gateway", mode: .example)
                HStack {
                    Button {
                        model.newTunnel(kind: kind)
                    } label: {
                        Label(L10n.text("New Tunnel", "新建隧道"), systemImage: "plus")
                    }
                    .buttonStyle(LaneButtonStyle(kind: .primary))
                    Button(L10n.text("Import SSH Configuration…", "导入 SSH 配置…")) { model.previewSSHConfig() }
                        .buttonStyle(LaneButtonStyle())
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }
}
