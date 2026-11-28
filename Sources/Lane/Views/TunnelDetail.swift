import SwiftUI
import LaneCore

/// Managed route inspection and recovery actions for the selected tunnel.
struct TunnelDetail: View {
    let tunnel: Tunnel
    let model: LaneModel
    @Environment(\.colorScheme) private var scheme
    @State private var selectedRuleID: UUID?
    @State private var showLogs = false
    @State private var confirmDelete = false

    private var style: LaneStyle { LaneStyle(scheme: scheme) }
    private var runtime: TunnelRuntime? { model.manager.displayRuntime(tunnel.id) }
    private var state: TunnelState { model.manager.state(tunnel.id) }
    private var selectedRule: Forwarding? { tunnel.forwardings.first { $0.id == selectedRuleID } ?? tunnel.enabledForwardings.first ?? tunnel.forwardings.first }
    private var failedRule: Forwarding? {
        tunnel.forwardings.first { rule in
            if case .failed = model.manager.ruleStatus(rule, in: tunnel) { return true }
            return false
        }
    }
    private var portConflict: Bool { runtime?.failureKind == .portInUse }
    private var canCopySelected: Bool {
        guard let selectedRule else { return false }
        return model.manager.ruleStatus(selectedRule, in: tunnel) == .active
    }
    private var copyCommandTitle: String {
        if model.manager.commandBuilder.proxyCommand(for: tunnel) != nil {
            return L10n.text("Copy SSH Command (Uses Lane)", "复制 SSH 命令（需要 Lane）")
        }
        return L10n.text("Copy SSH Command", "复制 SSH 命令")
    }

    var body: some View {
        let route = portConflict ? failedRule : selectedRule
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    heading
                    if state.isFailure { failureBanner }
                    RouteDiagram(forwarding: route, sshHost: tunnel.hostNotation,
                                 mode: portConflict ? .blocked : canCopySelected ? .live : .idle,
                                 ruleID: route?.id.uuidString)
                    ruleList
                }
                .padding(.top, 3)
            }
            .scrollIndicators(.hidden)
            diagnostics
        }
        .confirmationDialog(L10n.text("Remove this tunnel?", "移除此隧道？"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L10n.text("Remove Tunnel", "移除隧道"), role: .destructive) { model.remove(tunnel) }
            Button(L10n.text("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("The saved configuration and its active connection will be removed.",
                           "将移除已保存的配置并结束这条连接。"))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(L10n.text("Tunnels", "隧道")).foregroundStyle(style.secondary)
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(style.secondary)
            Text(tunnel.displayName).lineLimit(1)
            Spacer()
            Button { model.edit(tunnel) } label: { Image(systemName: "pencil") }
                .buttonStyle(LaneButtonStyle())
                .help(L10n.text("Edit tunnel", "编辑隧道"))
                .accessibilityLabel(L10n.text("Edit tunnel", "编辑隧道"))
            Menu {
                Button(copyCommandTitle) { copyCommand() }
                Button(L10n.text("Import SSH Configuration…", "导入 SSH 配置…")) { model.previewSSHConfig() }
                Divider()
                Button(L10n.text("Remove Tunnel…", "移除隧道…"), role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 32, height: 30)
            .background(style.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(style.edge).allowsHitTesting(false) }
            .accessibilityLabel(L10n.text("More actions", "更多操作"))
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(height: 35)
    }

    private var heading: some View {
        let keeping = model.manager.keepsConnected(tunnel.id)
        let shared = model.manager.agentRuleCount(tunnel)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                Text(tunnel.displayName).font(.system(size: 34, weight: .semibold)).lineLimit(1).accessibilityAddTraits(.isHeader)
                status
                Spacer(minLength: 5)
                Button {
                    model.manager.toggle(tunnel.id)
                } label: {
                    Label(keeping ? L10n.text("Disconnect", "断开") : shared > 0
                          ? L10n.text("Keep Connected", "保持连接") : L10n.text("Connect", "连接"),
                          systemImage: keeping ? "stop" : "play")
                }
                .buttonStyle(LaneButtonStyle(kind: keeping ? .neutral : .primary))
                .disabled(state == .disconnecting)
            }
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                Text(tunnel.hostNotation).font(.system(size: 13, weight: .medium, design: .monospaced)).lineLimit(1)
                Text("·").accessibilityHidden(true)
                Text(L10n.text("\(tunnel.enabledForwardings.count) forwards", "\(tunnel.enabledForwardings.count) 条转发"))
                if case .reconnecting(_, let date) = state {
                    Text(date, style: .timer).monospacedDigit()
                }
            }
            .font(.system(size: 12)).foregroundStyle(style.secondary)
        }
    }

    private var status: some View {
        let color = state.isConnected ? style.positive : state.isFailure ? style.warning : style.secondary
        let fill = state.isConnected ? style.positiveFill : state.isFailure ? style.warningFill : style.control
        return Label(portConflict ? L10n.text("Port in use", "端口占用") : model.manager.connectionLabel(tunnel, state: state),
                     systemImage: state.isConnected ? "checkmark.circle" : state.isFailure ? "exclamationmark.triangle" : "circle")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .foregroundStyle(color).background(fill, in: RoundedRectangle(cornerRadius: 7))
            .fixedSize()
    }

    private var failureBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text(portConflict ? L10n.text("Local port in use", "本机端口已被占用") : state.displayLabel)
                    .font(.system(size: 13, weight: .semibold))
                if let message = runtime?.lastError {
                    Text(message).font(.system(size: 11)).textSelection(.enabled)
                }
            }
            Spacer()
            if let failedRule {
                Button(L10n.text("Edit port", "编辑端口")) { model.edit(tunnel, focusRule: failedRule.id) }
                    .buttonStyle(LaneButtonStyle()).fixedSize()
            }
            Button(L10n.text("Retry", "重试")) { model.manager.connect(tunnel.id) }
                .buttonStyle(LaneButtonStyle()).fixedSize()
        }
        .foregroundStyle(style.warning)
        .padding(11)
        .background(style.warningFill, in: RoundedRectangle(cornerRadius: 10))
    }

    private var ruleList: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(L10n.text("Forwarding rules", "转发规则")).font(.system(size: 16, weight: .semibold))
                Text(tunnel.forwardings.count.formatted()).font(.system(size: 11, weight: .medium)).foregroundStyle(style.secondary)
                Spacer()
                Button { model.edit(tunnel, addRule: true) } label: {
                    Label(L10n.text("Add Rule", "添加规则"), systemImage: "plus")
                }
                .buttonStyle(LaneButtonStyle(kind: .subtle))
            }
            ForEach(tunnel.forwardings) { rule in ruleRow(rule) }
            Divider().overlay(style.edge)
        }
        .padding(.top, 4)
    }

    private func ruleRow(_ rule: Forwarding) -> some View {
        let selected = selectedRule?.id == rule.id
        let status = model.manager.ruleStatus(rule, in: tunnel)
        let enabled = rule.enabled && status == .active
        let label = rule.enabled ? status.displayLabel : L10n.text("Disabled", "已停用")
        let address = model.manager.ruleAddress(rule, in: tunnel)
        return HStack(spacing: 10) {
            Button { selectedRuleID = rule.id } label: {
                HStack(spacing: 9) {
                    Image(systemName: rule.kind == .local ? "shippingbox" : rule.kind.routeIcon)
                        .frame(width: 28, height: 28)
                        .foregroundStyle(style.ink(rule.kind))
                        .background(style.tile(rule.kind), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(rule.kind.displayLabel + " · " + label + (rule.note.isEmpty ? "" : " · \(rule.note)"))
                            .font(.system(size: 11)).foregroundStyle(style.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            Text(address)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(2)
                .textSelection(.enabled)
                .layoutPriority(1)
            CopyAction(model: model, value: address, key: rule.id.uuidString,
                       title: rule.copyTitle, prominent: selected, iconOnly: !selected)
                .disabled(!enabled)
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 51)
        .background(selected ? style.selected : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button(L10n.text("Edit Rule", "编辑规则")) { model.edit(tunnel, focusRule: rule.id) }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showLogs {
                Divider().overlay(style.edge)
                HStack(spacing: 8) {
                    Text(L10n.text("Recent events", "最近事件"))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(style.secondary)
                    Spacer()
                    Button(model.copied == "command-\(tunnel.id)" ? L10n.text("Copied", "已复制") :
                            copyCommandTitle) { copyCommand() }
                        .buttonStyle(LaneButtonStyle())
                    Button(L10n.text("Full log", "完整日志")) { model.logID = tunnel.id }
                        .buttonStyle(LaneButtonStyle())
                }
                let recent = runtime?.logs.filter { $0.level != .debug }.suffix(3) ?? []
                if recent.isEmpty {
                    Text(L10n.text("No connection events yet.", "还没有连接事件。")).foregroundStyle(style.secondary).font(.caption)
                }
                ForEach(recent.reversed()) { entry in
                    HStack(alignment: .top, spacing: 9) {
                        Text(entry.date, style: .time).font(.system(.caption, design: .monospaced))
                        Text(entry.message).font(.caption).lineLimit(2).textSelection(.enabled)
                    }
                    .foregroundStyle(entry.level == .error ? style.warning : style.secondary)
                }
            }
            LaneDisclosureRow(isExpanded: $showLogs, minHeight: 31) {
                Label(L10n.text("Diagnostics & Logs", "诊断与日志"), systemImage: "waveform.path")
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(style.secondary)
        }
    }

    private func copyCommand() {
        model.copy(model.manager.commandBuilder.displayCommand(for: tunnel), key: "command-\(tunnel.id)")
    }
}
