import SwiftUI
import LaneCore

/// v2's inset library and persistent detail area. Native window controls remain AppKit-owned.
struct MainWindow: View {
    @Bindable var model: LaneModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @FocusState private var searchFocused: Bool
    @State private var sidebarVisible = true
    private var style: LaneStyle { LaneStyle(scheme: scheme) }

    var body: some View {
        HStack(spacing: 20) {
            if sidebarVisible {
                sidebar.transition(.opacity.combined(with: .offset(x: -12)))
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.leading, sidebarVisible ? 8 : 22)
        .padding(.trailing, 26)
        .padding(.vertical, 8)
        .animation(reduceMotion ? nil : LaneMotion.disclosure, value: sidebarVisible)
        .frame(minWidth: 720, minHeight: 460)
        .foregroundStyle(style.text)
        .background(style.window)
        .tint(style.accent)
        .sheet(item: $model.editor) { request in
            TunnelEditor(request: request, model: model)
        }
        .sheet(item: $model.importPreview) { preview in
            ImportSheet(preview: preview) { try model.importSelected($0, kind: preview.kind) }
        }
        .sheet(isPresented: Binding(get: { model.logID != nil }, set: { if !$0 { model.logID = nil } })) {
            if let id = model.logID, let tunnel = model.store.tunnel(id) {
                FullLogSheet(tunnel: tunnel, model: model)
            }
        }
        .sheet(isPresented: $model.showingAgentActivity) {
            AgentActivity(model: model)
        }
        .alert("Lane", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.refreshDiscovery() }
        .onAppear {
            model.openMainWindow = { [openWindow] in openWindow(id: "main") }
            if let error = model.store.loadError { model.errorMessage = error }
            model.refreshDiscovery()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            sidebarHeader
            search
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    sectionTitle(L10n.text("Managed by Lane", "Lane 管理"))
                    ForEach(model.matchingTunnels) { tunnel in managedRow(tunnel) }
                    if model.store.tunnels.isEmpty, !model.externalSessions.isEmpty, model.query.isEmpty {
                        Button { model.previewSSHConfig() } label: {
                            Label(L10n.text("Import SSH Configuration…", "导入 SSH 配置…"), systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(LaneButtonStyle(kind: .subtle))
                        .padding(.leading, 3)
                    } else if model.matchingTunnels.isEmpty, !model.query.isEmpty {
                        Text(L10n.text("No matching tunnels", "没有匹配的隧道"))
                            .font(.caption).foregroundStyle(style.secondary).padding(.horizontal, 8).padding(.vertical, 6)
                    }
                    HStack {
                        sectionTitle(L10n.text("Local discovery", "本机发现"))
                        Spacer()
                        if model.refreshing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Button { model.refreshDiscovery() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.plain)
                                .foregroundStyle(style.secondary)
                                .help(L10n.text("Refresh local discovery", "刷新本机发现"))
                                .accessibilityLabel(L10n.text("Refresh local discovery", "刷新本机发现"))
                        }
                    }
                    .padding(.top, 14)
                    .padding(.trailing, 8)
                    ForEach(model.matchingExternal) { session in externalRow(session) }
                    if let error = model.discoveryError {
                        Text(error).font(.caption).foregroundStyle(style.warning).padding(.horizontal, 8).padding(.top, 4)
                    }
                }
            }
            .scrollIndicators(.hidden)
            Divider().overlay(style.edge)
            if !model.agents.ledger.clients.isEmpty || model.agents.hasLeases {
                agentActivityButton
            }
            HStack {
                Button { model.newTunnel() } label: {
                    Label(L10n.text("New tunnel", "新建隧道"), systemImage: "plus")
                }
                .buttonStyle(LaneButtonStyle(kind: .subtle))
                Spacer()
                SettingsLink { Image(systemName: "gearshape").font(.system(size: 14)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(style.secondary)
                    .help(L10n.text("Settings", "设置"))
                    .accessibilityLabel(L10n.text("Settings", "设置"))
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 5)
        }
        .padding(10)
        .frame(width: 208)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(style.sidebar, in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(style.edge) }
    }

    private var agentActivityButton: some View {
        Button { model.showingAgentActivity = true } label: {
            Label(L10n.text("Agent Activity", "Agent 活动"), systemImage: "point.3.connected.trianglepath.dotted")
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(LaneHoverHighlight())
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            LaneGlyph(size: 25)
            Text("Lane").font(.system(size: 17, weight: .semibold))
            Spacer()
            sidebarToggle(hiding: true)
        }
        .frame(height: 33)
        .padding(.horizontal, 5)
    }

    private func sidebarToggle(hiding: Bool) -> some View {
        let title = hiding ? L10n.text("Hide sidebar", "隐藏侧栏") : L10n.text("Show sidebar", "显示侧栏")
        return Button { sidebarVisible = !hiding } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(style.secondary)
                .frame(width: 29, height: 29)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(LaneHoverHighlight())
        .help(title)
        .accessibilityLabel(title)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Button { searchFocused = true } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain)
                .keyboardShortcut("f")
                .accessibilityLabel(L10n.text("Search", "搜索"))
            TextField(L10n.text("Search tunnels", "搜索隧道"), text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onKeyPress(.downArrow) { moveSelection(1) }
                .onKeyPress(.upArrow) { moveSelection(-1) }
                .onSubmit { _ = moveSelection(0) }
            if model.query.isEmpty {
                Text("⌘F").font(.system(size: 10, weight: .medium)).accessibilityHidden(true)
            } else {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("Clear Search", "清空搜索"))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(style.secondary)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(style.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(searchFocused ? style.accent : style.edge) }
    }

    private func moveSelection(_ stride: Int) -> KeyPress.Result {
        let results: [LaneModel.Selection] = model.matchingTunnels.map { .managed($0.id) } +
            model.matchingExternal.map { .external($0.id) }
        guard !results.isEmpty else { return .ignored }
        let current = model.selection.flatMap { results.firstIndex(of: $0) }
        model.selection = results[current.map { min(max($0 + stride, 0), results.count - 1) } ?? 0]
        return .handled
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(style.secondary)
            .padding(.leading, 7).padding(.top, 6).padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    private func managedRow(_ tunnel: Tunnel) -> some View {
        let state = model.manager.state(tunnel.id)
        let kind = tunnel.enabledForwardings.first?.kind ?? .local
        let count = tunnel.enabledForwardings.count
        let label = model.manager.connectionLabel(tunnel, state: state)
        let subtitle = state.isConnected && label == state.displayLabel ? label + " · " +
            (kind == .dynamic && count == 1 ? "SOCKS5" : L10n.text("\(count) rules", "\(count) 条规则")) : label
        return sidebarRow(title: tunnel.displayName, subtitle: subtitle,
                          icon: state.isFailure ? "exclamationmark.triangle" : kind == .local ? "square.3.layers.3d" :
                            kind == .remote ? "macwindow" : kind.routeIcon,
                          ink: state.isFailure ? style.warning : style.ink(kind),
                          tile: state.isFailure ? style.warningFill : style.tile(kind),
                          status: state.isFailure ? style.warning : state.isConnected ? style.positive : style.secondary,
                          selection: .managed(tunnel.id))
    }

    private func externalRow(_ session: ExternalSession) -> some View {
        let count = session.rules.filter { $0.listener != nil }.count
        let subtitle = count > 0 ? L10n.text("Listening · \(count) entries", "本机监听 · \(count) 个入口")
            : L10n.text("Remote unverified", "远端未核实")
        return sidebarRow(title: session.host ?? "OpenSSH", subtitle: subtitle, icon: "terminal",
                          ink: style.ink(.local), tile: style.tile(.local), status: count > 0 ? style.positive : style.secondary,
                          selection: .external(session.id))
    }

    private func sidebarRow(title: String, subtitle: String, icon: String, ink: Color, tile: Color, status: Color,
                            selection: LaneModel.Selection) -> some View {
        let selected = model.selection == selection
        return Button { model.selection = selection } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 29, height: 29)
                    .foregroundStyle(ink)
                    .background(tile, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(selected ? style.accent : style.text)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(style.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 2)
                Circle().fill(status).frame(width: 5, height: 5)
            }
            .padding(.horizontal, 7)
            .frame(height: 45)
            .background(selected ? style.selected : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !sidebarVisible {
                HStack {
                    sidebarToggle(hiding: false)
                    Spacer()
                }
                .frame(height: 33)
                .transition(.opacity)
            }
            ZStack(alignment: .topLeading) {
                detailContent
                    .id(model.selection)
                    .transition(.opacity)
            }
            .animation(reduceMotion ? nil : LaneMotion.crossfade, value: model.selection)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch model.selection {
        case .managed(let id):
            if let tunnel = model.store.tunnel(id) { TunnelDetail(tunnel: tunnel, model: model) }
        case .external(let pid):
            if let session = model.externalSessions.first(where: { $0.id == pid }) {
                ExternalDetail(session: session, model: model)
            }
        case nil:
            EmptyLibrary(model: model)
        }
    }
}
