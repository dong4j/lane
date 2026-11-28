import AppKit
import SwiftUI
import LaneCore

/// Keeps the native status-item window in sync with the app's appearance and content size.
struct LaneMenuPanel: View {
    let model: LaneModel
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let scheme: ColorScheme = switch model.preferences.appearance {
        case .system: systemScheme
        case .light: .light
        case .dark: .dark
        }
        LaneMenuBar(model: model)
            .environment(\.colorScheme, scheme)
            .background(LaneMenuWindowFit())
    }
}

/// A compact window-style menu extra keeps connection and clipboard actions in place.
struct LaneMenuBar: View {
    let model: LaneModel
    @State private var expandedManaged: Set<UUID> = []
    @State private var expandedExternal: Set<Int32> = []
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var style: LaneStyle { LaneStyle(scheme: scheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                groups
                    .padding(.bottom, 8)
            }
            .frame(maxHeight: 388)
            .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(width: 362)
        .background(style.surface)
        .foregroundStyle(style.text)
        .tint(style.accent)
        .onAppear { model.refreshDiscovery() }
    }

    /// The panel hugs the visible groups and scrolls only when they exceed the available height.
    private var groups: some View {
        let tunnels = model.store.tunnels
        let sessions = model.externalSessions
        return VStack(spacing: 10) {
            if !model.agents.active.isEmpty {
                agentGroup
            }
            if !tunnels.isEmpty {
                VStack(spacing: 2) {
                    section(L10n.text("Managed by Lane", "Lane 管理"),
                            value: L10n.text("\(model.manager.connectedCount) connected", "\(model.manager.connectedCount) 条已连接"))
                    ForEach(tunnels) { tunnel in managedRow(tunnel) }
                }
            }
            if !sessions.isEmpty || model.discoveryError != nil {
                VStack(spacing: 2) {
                    section(L10n.text("Local discovery", "本机发现"), value: L10n.text("Read only", "只读"), readOnly: true)
                    ForEach(sessions) { session in externalRow(session) }
                    if let error = model.discoveryError {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(style.warning)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(7)
                    }
                }
            }
            if tunnels.isEmpty, sessions.isEmpty, model.discoveryError == nil {
                emptyLibrary
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            LaneGlyph(size: 25)
            Text("Lane").font(.system(size: 16, weight: .semibold)).foregroundStyle(style.text)
            Spacer()
            Button {
                model.refreshDiscovery()
            } label: {
                ZStack {
                    Image(systemName: "arrow.clockwise").opacity(model.refreshing ? 0 : 1)
                    if model.refreshing {
                        ProgressView().controlSize(.mini).transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : LaneMotion.crossfade, value: model.refreshing)
                .frame(width: 29, height: 29)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(LaneHoverHighlight())
            .disabled(model.refreshing)
            .help(L10n.text("Refresh local discovery", "刷新本机发现"))
            .accessibilityLabel(L10n.text("Refresh local discovery", "刷新本机发现"))
            Menu {
                Button(L10n.text("New Tunnel…", "新建隧道…")) {
                    showMainWindow()
                    model.newTunnel()
                }
                Button(L10n.text("Settings…", "设置…")) {
                    NSApp.activate()
                    openSettings()
                }
                if !model.agents.ledger.clients.isEmpty || model.agents.hasLeases {
                    Button(L10n.text("Agent Activity…", "Agent 活动…"), action: showAgentActivity)
                }
                Divider()
                Button(L10n.text("Quit Lane", "退出 Lane")) { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .modifier(LaneHoverHighlight())
            .help(L10n.text("More actions", "更多操作"))
            .accessibilityLabel(L10n.text("More actions", "更多操作"))
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(style.secondary)
        .padding(.horizontal, 7)
        .frame(height: 51)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Divider().overlay(style.edge)
            Button {
                showMainWindow()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "macwindow").foregroundStyle(style.secondary)
                    Text(L10n.text("Open Main Window…", "打开主窗口…")).fontWeight(.semibold)
                    Spacer()
                    Text("⌘O")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(style.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 7)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(LaneHoverHighlight())
            .keyboardShortcut("o")
        }
        .padding(.bottom, 5)
    }

    private var emptyLibrary: some View {
        Button {
            showMainWindow()
            model.newTunnel()
        } label: {
            HStack(spacing: 9) {
                tile(icon: "plus", color: style.accent, fill: style.selected)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("New Tunnel…", "新建隧道…")).fontWeight(.semibold)
                    Text(L10n.text("No saved tunnels", "还没有已保存的隧道"))
                        .font(.system(size: 11)).foregroundStyle(style.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(style.secondary)
            }
            .padding(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(LaneHoverHighlight())
    }

    private func section(_ title: String, value: String, readOnly: Bool = false) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, readOnly ? 6 : 0)
                .padding(.vertical, 3)
                .background(readOnly ? style.control : .clear, in: Capsule())
        }
        .foregroundStyle(style.secondary)
        .padding(.horizontal, 7)
        .frame(height: 21)
    }

    private var agentGroup: some View {
        let leases = model.agents.active
        return VStack(spacing: 3) {
            section(L10n.text("Agent Activity", "Agent 活动"), value: L10n.text("\(leases.count) active", "\(leases.count) 条使用中"))
            ForEach(leases) { lease in
                HStack(spacing: 5) {
                    Button(action: showAgentActivity) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lease.route.name).font(.system(size: 13, weight: .semibold))
                            HStack(spacing: 4) {
                                Text(lease.clientName)
                                    .lineLimit(1).truncationMode(.middle)
                                Text("·").accessibilityHidden(true)
                                if lease.state == .ready, let expires = lease.expiresAt {
                                    Text(expires, style: .timer).monospacedDigit().fixedSize()
                                        .accessibilityLabel(L10n.text("Time remaining", "剩余时间"))
                                } else {
                                    Text(lease.state.displayLabel)
                                }
                            }
                            .font(.caption).foregroundStyle(style.secondary)
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(LaneHoverHighlight())
                    if lease.state == .ready {
                        CopyAction(model: model, value: lease.route.listenAddress, key: "agent-menu-\(lease.id)",
                                   title: L10n.text("Copy Agent Address", "复制 Agent 隧道地址"), iconOnly: true)
                    }
                    Button(L10n.text("End", "结束")) {
                        do { try model.agents.end(lease.id) }
                        catch {
                            model.errorMessage = error.localizedDescription
                            showMainWindow()
                        }
                    }
                    .buttonStyle(LaneButtonStyle())
                    .accessibilityLabel(L10n.text("End lease for \(lease.clientName)", "结束 \(lease.clientName) 的使用"))
                }
                .padding(.horizontal, 7)
            }
        }
    }

    private func managedRow(_ tunnel: Tunnel) -> some View {
        let current = model.manager.state(tunnel.id)
        let keeping = model.manager.keepsConnected(tunnel.id)
        let shared = model.manager.agentRuleCount(tunnel)
        let rules = tunnel.enabledForwardings
        let kind = rules.first?.kind ?? .local
        let subtitle = switch (rules.count, kind) {
        case (1, .remote): L10n.text("Server entry", "服务器入口")
        case (1, .dynamic): "SOCKS5"
        default: L10n.text("\(rules.count) rules", "\(rules.count) 条规则")
        }
        let icon = current.isFailure ? "exclamationmark.triangle" :
            kind == .local ? "square.3.layers.3d" : kind == .remote ? "macwindow" : kind.routeIcon
        let label = model.manager.connectionLabel(tunnel, state: current)
        let detail = label + (label == current.displayLabel && (current.isConnected || rules.count == 1 && kind != .local)
                              ? " · \(subtitle)" : "")
        let expandable = (current.isConnected || shared > 0) && rules.count > 1
        let expanded = expansion(of: tunnel.id, in: $expandedManaged)
        let title = rowLabel(tunnel.displayName, detail: detail, icon: icon,
                             ink: current.isFailure ? style.warning : style.ink(kind),
                             fill: current.isFailure ? style.warningFill : style.tile(kind),
                             status: current.isFailure ? style.warning : current.isConnected ? style.positive : style.secondary)
        return VStack(spacing: 3) {
            ZStack {
                if expandable {
                    // Behind the controls, this button also receives clicks in the gaps around Disconnect.
                    LaneDisclosureButton(isExpanded: expanded) { Color.clear }
                        .accessibilityLabel("\(tunnel.displayName), \(detail)")
                }
                HStack(spacing: 6) {
                    title
                        .allowsHitTesting(false)
                        .accessibilityHidden(expandable)
                    if rules.count == 1, let rule = rules.first, model.manager.ruleStatus(rule, in: tunnel) == .active {
                        CopyAction(model: model, value: model.manager.ruleAddress(rule, in: tunnel), key: rule.id.uuidString,
                                   title: rule.copyTitle, iconOnly: true)
                    }
                    Button(current.isFailure ? L10n.text("View", "查看") : keeping ? L10n.text("Disconnect", "断开") :
                           shared > 0 ? L10n.text("Keep Connected", "保持连接") : L10n.text("Connect", "连接")) {
                        if current.isFailure {
                            model.selection = .managed(tunnel.id)
                            showMainWindow()
                        } else {
                            model.manager.toggle(tunnel.id)
                        }
                    }
                    .buttonStyle(LaneButtonStyle())
                    .disabled(current == .disconnecting)
                    if expandable {
                        LaneDisclosureChevron(expanded: expanded.wrappedValue)
                    }
                }
                .padding(.horizontal, 7)
            }
            .frame(height: 44)
            if expandable, expanded.wrappedValue {
                expandedEntries {
                    ForEach(rules) { rule in
                        let status = model.manager.ruleStatus(rule, in: tunnel)
                        entry(rule.displayName,
                              subtitle: rule.kind == .remote ? L10n.text("Server entry", "服务器入口") : nil,
                              value: status == .active ? model.manager.ruleAddress(rule, in: tunnel) : status.displayLabel,
                              key: rule.id.uuidString, title: rule.copyTitle, enabled: status == .active)
                    }
                }
            }
        }
    }

    private func externalRow(_ session: ExternalSession) -> some View {
        let listeners = session.rules.filter { $0.listener != nil }
        let detail = listeners.isEmpty ? L10n.text("Remote unverified", "远端未核实")
            : L10n.text("Listening · \(listeners.count) entries", "本机监听 · \(listeners.count) 个入口")
        let title = rowLabel(session.host ?? "OpenSSH", detail: detail, icon: "terminal",
                             ink: style.ink(.local), fill: style.tile(.local),
                             status: listeners.isEmpty ? style.warning : style.positive)
        let expanded = expansion(of: session.id, in: $expandedExternal)
        let openDetails = {
            model.selection = .external(session.id)
            showMainWindow()
        }
        return VStack(spacing: 3) {
            if session.rules.count > 1 {
                LaneDisclosureRow(isExpanded: expanded, minHeight: 44, inset: 7) { title }
                    .contextMenu {
                        Button(L10n.text("Open in Main Window", "在主窗口中打开"), action: openDetails)
                    }
            } else {
                HStack(spacing: 6) {
                    Button(action: openDetails) {
                        title
                            .padding(.horizontal, 7)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(LaneHoverHighlight())
                    if let rule = listeners.first, let address = rule.copyAddress {
                        CopyAction(model: model, value: address, key: "external-\(session.id)-\(rule.id)",
                                   title: L10n.text("Copy local address", "复制本机地址"), iconOnly: true)
                            .padding(.trailing, 7)
                    }
                }
            }
            if session.rules.count > 1, expanded.wrappedValue {
                expandedEntries {
                    ForEach(session.rules) { rule in
                        if let value = rule.copyAddress {
                            entry("", value: value, key: "external-\(session.id)-\(rule.id)",
                                  title: L10n.text("Copy local address", "复制本机地址"), enabled: true)
                        } else {
                            Label(L10n.text("Remote unverified", "远端未核实") + " · " + (rule.forward?.listenDisplayAddress ?? ""),
                                  systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(style.secondary).lineLimit(2)
                                .frame(maxWidth: .infinity, minHeight: 29, alignment: .leading)
                                .padding(.horizontal, 11)
                        }
                    }
                }
            }
        }
    }

    private func rowLabel(_ title: String, detail: String, icon: String, ink: Color, fill: Color, status: Color) -> some View {
        HStack(spacing: 9) {
            tile(icon: icon, color: ink, fill: fill)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(status).frame(width: 4, height: 4).accessibilityHidden(true)
                    Text(detail).font(.system(size: 11)).foregroundStyle(style.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func expandedEntries<Entries: View>(@ViewBuilder content: () -> Entries) -> some View {
        VStack(spacing: 0, content: content)
            .padding(.vertical, 3)
            .background(style.control.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
            .padding(.leading, 42)
            .padding(.trailing, 7)
            .transition(.opacity.combined(with: .offset(y: -4)))
    }

    private func entry(_ name: String, subtitle: String? = nil, value: String, key: String, title: String, enabled: Bool) -> some View {
        HStack(spacing: 8) {
            if name.isEmpty { Image(systemName: "arrow.turn.down.right").foregroundStyle(style.accent) }
            else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).fontWeight(.medium).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(style.secondary).lineLimit(1) }
                }
                Spacer(minLength: 2)
            }
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(2).layoutPriority(1)
            if name.isEmpty { Spacer(minLength: 2) }
            CopyAction(model: model, value: value, key: key, title: title, iconOnly: true).disabled(!enabled)
        }
        .padding(.leading, 11).padding(.trailing, 5)
    }

    /// Each menu group keeps its expansion when another row is opened or refreshed.
    private func expansion<ID: Hashable>(of id: ID, in rows: Binding<Set<ID>>) -> Binding<Bool> {
        Binding(
            get: { rows.wrappedValue.contains(id) },
            set: { expanded in
                if expanded { rows.wrappedValue.insert(id) }
                else { rows.wrappedValue.remove(id) }
            }
        )
    }

    private func tile(icon: String, color: Color, fill: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .medium)).foregroundStyle(color)
            .frame(width: 26, height: 26).background(fill, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }

    private func showMainWindow() {
        NSApp.activate()
        openWindow(id: "main")
    }

    private func showAgentActivity() {
        showMainWindow()
        model.showingAgentActivity = true
    }
}

/// Keeps an open MenuBarExtra fitted to the content while its top edge stays anchored to the status item.
private struct LaneMenuWindowFit: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FitView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FitView: NSView {
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            // Resize after SwiftUI finishes laying out the disclosure transition.
            Task { @MainActor [weak self] in self?.fitWindow() }
        }

        private func fitWindow() {
            guard let window, window.isVisible, bounds.height > 0 else { return }
            let delta = ceil(bounds.height) - window.contentLayoutRect.height
            guard abs(delta) >= 1 else { return }

            var frame = window.frame
            frame.size.height += delta
            frame.origin.y -= delta
            window.setFrame(frame, display: true)
        }
    }
}

#if DEBUG
extension LaneMenuBar {
    /// Captures the same open state that the disclosure button produces in the menu extra.
    init(model: LaneModel, previewExpandedSession: Int32) {
        self.init(model: model)
        _expandedExternal = State(initialValue: [previewExpandedSession])
    }
}
#endif
