import SwiftUI
import LaneCore

/// Shows exactly the observed endpoints of an external OpenSSH process.
struct ExternalDetail: View {
    let session: ExternalSession
    let model: LaneModel
    @Environment(\.colorScheme) private var scheme
    @State private var selectedRuleID: String?

    private var style: LaneStyle { LaneStyle(scheme: scheme) }
    private var selected: ExternalSession.Rule? { session.rules.first { $0.id == selectedRuleID } ?? session.rules.first }
    private var listeners: Int { session.rules.filter { $0.listener != nil }.count }
    private var name: String { session.host ?? "OpenSSH" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(L10n.text("Local discovery", "本机发现")).foregroundStyle(style.secondary)
                Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(style.secondary)
                Text(name).lineLimit(1)
                Spacer()
                Button { model.refreshDiscovery() } label: {
                    Label(L10n.text("Refresh", "刷新"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(LaneButtonStyle())
                .disabled(model.refreshing)
            }
            .font(.system(size: 12, weight: .semibold)).frame(height: 35)
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 10) {
                            Text(name).font(.system(size: 34, weight: .semibold)).accessibilityAddTraits(.isHeader)
                            Text(listeners > 0 ? L10n.text("Local listeners", "本机监听") : L10n.text("Remote unverified", "远端未核实"))
                                .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 5)
                                .foregroundStyle(listeners > 0 ? style.positive : style.warning)
                                .background(listeners > 0 ? style.positiveFill : style.warningFill, in: RoundedRectangle(cornerRadius: 7))
                            Spacer()
                        }
                        Label(L10n.text("OpenSSH · PID \(session.id) · Read only", "OpenSSH · PID \(session.id) · 只读"), systemImage: "terminal")
                            .font(.system(size: 12)).foregroundStyle(style.secondary)
                    }
                    RouteDiagram(forwarding: selected?.forward, sshHost: session.host ?? "", mode: .external,
                                 observedAddress: selected?.listener?.address, ruleID: selected?.id)
                    Text(L10n.text("Observed entries", "已发现入口")).font(.system(size: 16, weight: .semibold))
                    VStack(spacing: 4) {
                        ForEach(session.rules) { rule in row(rule) }
                    }
                    Label(L10n.text("Connect or disconnect from the tool that started this session.",
                                   "请在启动这条 SSH 会话的工具中连接或断开。"), systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(style.secondary)
                        .padding(.top, 4)
                }
                .padding(.top, 3)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func row(_ rule: ExternalSession.Rule) -> some View {
        let active = selected?.id == rule.id
        let kind = rule.forward?.kind
        let address = rule.listener?.address ?? rule.forward?.listenDisplayAddress ?? ""
        let label = kind?.displayLabel ?? L10n.text("Target unknown", "目标未知")
        let evidence = rule.listener == nil ? L10n.text("Remote unverified", "远端未核实")
            : kind == nil ? L10n.text("TCP listener observed", "已观测 TCP 监听")
            : L10n.text("Listener and launch options match", "监听与启动参数吻合")
        return HStack(spacing: 10) {
            Button { selectedRuleID = rule.id } label: {
                HStack(spacing: 9) {
                    Image(systemName: rule.listener == nil ? "server.rack" : "terminal")
                        .foregroundStyle(style.ink(kind ?? .local))
                        .frame(width: 28, height: 28)
                        .background(style.tile(kind ?? .local), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(address).font(.system(size: 13, weight: .medium, design: .monospaced)).lineLimit(2)
                        Text("\(label) · \(evidence)").font(.system(size: 11)).foregroundStyle(style.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(active ? .isSelected : [])
            if let value = rule.copyAddress {
                CopyAction(model: model, value: value, key: "external-\(session.id)-\(rule.id)",
                           title: L10n.text("Copy local address", "复制本机地址"), prominent: active, iconOnly: !active)
            }
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 50)
        .background(active ? style.selected : .clear, in: RoundedRectangle(cornerRadius: 10))
    }
}
