import SwiftUI

/// A single activity surface handles approvals, live leases, and persisted history.
struct AgentActivity: View {
    private enum Page { case current, history }

    let model: LaneModel
    @State private var page = Page.current
    @State private var query = ""
    @State private var approving: UUID?
    @State private var error: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var access: AgentAccess { model.agents }
    private var style: LaneStyle { LaneStyle(scheme: scheme) }
    private var filteredHistory: [AgentLease] {
        guard !query.isEmpty else { return access.history }
        return access.history.filter { lease in
            [lease.id.uuidString, lease.clientName, lease.route.name, lease.route.listenAddress,
             lease.input.project ?? "", lease.input.purpose].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.headline).frame(width: 38, height: 38)
                    .foregroundStyle(style.accent).background(style.selected, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                Text(L10n.text("Agent Activity", "Agent 活动")).font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text("Done", "完成")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(LaneButtonStyle())
            }
            Picker(L10n.text("Agent activity", "Agent 活动"), selection: $page) {
                Text(L10n.text("Requests and Active", "待审批与进行中")).tag(Page.current)
                Text(L10n.text("History", "历史")).tag(Page.history)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(style.warning)
            } else if access.storageError || access.serviceError {
                Label(access.statusMessage, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(style.warning)
            }

            if page == .history {
                TextField(L10n.text("Search by client, project, address, or ID", "按客户端、项目、地址或编号查找"), text: $query)
                    .textFieldStyle(.roundedBorder)
            }
            ZStack(alignment: .topLeading) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        switch page {
                        case .current: current
                        case .history: history
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 3)
                }
                .id(page)
                .transition(.opacity)
            }
            .animation(reduceMotion ? nil : LaneMotion.crossfade, value: page)
        }
        .padding(22)
        .frame(width: 620, height: 510)
        .background(style.window)
        .foregroundStyle(style.text)
        .tint(style.accent)
    }

    @ViewBuilder
    private var current: some View {
        if access.pending.isEmpty, access.active.isEmpty {
            empty(L10n.text("No Agent requests or live leases", "暂无待审批或进行中的申请"), symbol: "tray")
        }
        if !access.pending.isEmpty {
            sectionTitle(L10n.text("Awaiting Approval", "待审批"))
            ForEach(access.pending) { lease in
                card(lease) {
                    HStack {
                        if lease.external != nil {
                            Text(L10n.text("External SSH · reference only", "外部 SSH · 仅引用"))
                                .font(.caption).foregroundStyle(style.secondary)
                        }
                        Spacer()
                        if approving == lease.id { ProgressView().controlSize(.small) }
                        Button(L10n.text("Deny", "拒绝")) { perform { try access.deny(lease.id) } }
                            .buttonStyle(LaneButtonStyle())
                        Button(L10n.text("Approve", "批准")) { approve(lease.id) }
                            .buttonStyle(LaneButtonStyle(kind: .primary))
                    }
                    .disabled(approving != nil)
                }
            }
        }
        if !access.active.isEmpty {
            sectionTitle(L10n.text("Active Leases", "进行中"))
            ForEach(access.active) { lease in
                card(lease) {
                    HStack {
                        if let expiry = lease.expiresAt {
                            Label {
                                Text(expiry, style: .timer).monospacedDigit()
                            } icon: {
                                Image(systemName: "clock")
                            }
                            .font(.caption).foregroundStyle(style.secondary)
                            .accessibilityLabel(L10n.text("Time remaining", "剩余时间"))
                        }
                        if access.borrowed(lease) || lease.external != nil {
                            Text(lease.external != nil
                                 ? L10n.text("External SSH · reference only", "外部 SSH · 仅引用")
                                 : L10n.text("Reusing a manual tunnel", "复用手动连接"))
                                .font(.caption).foregroundStyle(style.secondary)
                        }
                        Spacer()
                        if lease.state == .ready {
                            CopyAction(model: model, value: lease.route.listenAddress, key: "agent-address-\(lease.id)",
                                       title: L10n.text("Copy Address", "复制地址"))
                        }
                        Button(L10n.text("End Lease", "结束申请")) { perform { try access.end(lease.id) } }
                            .buttonStyle(LaneButtonStyle())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var history: some View {
        if filteredHistory.isEmpty {
            empty(query.isEmpty ? L10n.text("No Agent history", "暂无历史记录")
                  : L10n.text("No matching records", "没有匹配的记录"), symbol: "clock.arrow.circlepath")
        }
        ForEach(filteredHistory) { lease in
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    metadata(lease)
                    ForEach(lease.events) { event in
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.at.formatted(date: .abbreviated, time: .standard))
                                .font(.caption.monospacedDigit()).foregroundStyle(style.secondary)
                            Text(event.action.displayLabel)
                            if let reason = event.reason {
                                Text(reason.displayLabel).font(.caption).foregroundStyle(style.secondary)
                            }
                        }
                    }
                    CopyAction(model: model, value: lease.id.uuidString, key: "agent-id-\(lease.id)",
                               title: L10n.text("Copy Lease ID", "复制申请编号"))
                }
                .padding(.top, 10)
            } label: {
                leaseTitle(lease)
            }
            .padding(12)
            .background(style.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(style.edge).allowsHitTesting(false) }
        }
    }

    private func card<Actions: View>(_ lease: AgentLease, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            leaseTitle(lease)
            metadata(lease)
            actions()
        }
        .padding(12)
        .background(style.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(style.edge).allowsHitTesting(false) }
    }

    private func leaseTitle(_ lease: AgentLease) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(lease.route.name).font(.callout.weight(.semibold))
                Text(lease.clientName).font(.caption).foregroundStyle(style.secondary)
            }
            Spacer()
            Text(lease.state.displayLabel).font(.caption.weight(.semibold))
                .foregroundStyle(lease.state == .ready ? style.positive : lease.state == .pendingApproval ? style.warning : style.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(lease.state == .ready ? style.positiveFill : lease.state == .pendingApproval ? style.warningFill : style.control,
                            in: Capsule())
        }
    }

    private func metadata(_ lease: AgentLease) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
            routeRow(L10n.text("Entry on this Mac", "本机入口"), lease.route.listenAddress)
            routeRow(L10n.text("SSH host", "SSH 主机"), lease.route.sshHost ?? L10n.text("Unknown", "未知"))
            routeRow(L10n.text("Destination from SSH host", "SSH 主机访问的目标"),
                     lease.route.destination ?? L10n.text("Unknown", "未知"))
            if let project = lease.input.project {
                routeRow(L10n.text("Project · from client", "项目 · 客户端提供"), project, monospaced: false)
            }
            routeRow(L10n.text("Purpose · from client", "用途 · 客户端提供"), lease.input.purpose, monospaced: false)
        }
        .font(.caption)
        .textSelection(.enabled)
    }

    private func routeRow(_ label: String, _ value: String, monospaced: Bool = true) -> some View {
        GridRow {
            Text(label).foregroundStyle(style.secondary)
            Text(value).font(monospaced ? .caption.monospaced() : .caption).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.callout.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }

    private func empty(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .frame(maxWidth: .infinity, minHeight: 120)
            .foregroundStyle(style.secondary)
    }

    private func approve(_ id: UUID) {
        approving = id
        error = nil
        Task {
            defer { approving = nil }
            do { try await access.approve(id) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func perform(_ action: () throws -> Void) {
        error = nil
        do { try action() }
        catch { self.error = error.localizedDescription }
    }
}

extension AgentAccess {
    var statusMessage: String {
        if storageError {
            L10n.text("The local Agent audit is unavailable.", "无法访问本机 Agent 审计记录。")
        } else {
            L10n.text("The local Agent service could not start.", "本机 Agent 服务无法启动。")
        }
    }
}

extension AgentLease.State {
    var displayLabel: String {
        switch self {
        case .pendingApproval: L10n.text("Awaiting approval", "待审批")
        case .connecting: L10n.text("Connecting", "连接中")
        case .ready: L10n.text("Ready", "已就绪")
        case .reconnecting: L10n.text("Reconnecting", "重连中")
        case .denied: L10n.text("Denied", "已拒绝")
        case .failed: L10n.text("Failed", "失败")
        case .released: L10n.text("Released", "已释放")
        case .expired: L10n.text("Expired", "已到期")
        case .ended: L10n.text("Ended", "已结束")
        }
    }
}

private extension AgentLease.Action {
    var displayLabel: String {
        switch self {
        case .requested: L10n.text("Requested", "提交申请")
        case .authorized: L10n.text("Authorized by rule", "共享规则已授权")
        case .approved: L10n.text("Approved", "人工批准")
        case .denied: AgentLease.State.denied.displayLabel
        case .connected: L10n.text("Listener opened", "监听已就绪")
        case .reused: L10n.text("Reused listener", "复用监听")
        case .reconnecting: AgentLease.State.reconnecting.displayLabel
        case .reconnected: L10n.text("Reconnected", "已重连")
        case .released: AgentLease.State.released.displayLabel
        case .expired: AgentLease.State.expired.displayLabel
        case .failed: AgentLease.State.failed.displayLabel
        case .ended: AgentLease.State.ended.displayLabel
        }
    }
}

private extension AgentLease.Reason {
    var displayLabel: String {
        switch self {
        case .userDenied: L10n.text("Denied by you", "人工拒绝")
        case .userEnded: L10n.text("Ended by you", "人工结束")
        case .accessDisabled: L10n.text("Request permission disabled", "申请权限已关闭")
        case .clientRevoked: L10n.text("Pairing revoked", "配对已撤销")
        case .routeChanged: L10n.text("Shared rule or SSH profile changed", "共享规则或 SSH 配置已变更")
        case .externalGone: L10n.text("External listener disappeared", "外部监听已消失")
        case .sshFailed: L10n.text("SSH could not start or maintain the forwarding", "SSH 未能建立或维持转发")
        case .startupTimedOut: L10n.text("SSH startup timed out", "SSH 启动超时")
        case .approvalTimedOut: L10n.text("Approval timed out", "等待审批超时")
        case .appQuit: L10n.text("Lane quit", "Lane 已退出")
        case .appRestarted: L10n.text("Lane restarted", "Lane 已重启")
        }
    }
}
