import SwiftUI
import LaneCore

/// Each rule keeps its per-mode fields while its name and note belong to the rule itself.
private struct RuleDraft: Identifiable {
    struct Fields {
        var listenPort: String
        var targetHost: String
        var targetPort: String
        var bind: String

        init(_ rule: Forwarding) {
            listenPort = rule.port > 0 ? String(rule.port) : ""
            targetHost = rule.targetHost
            targetPort = rule.targetPort > 0 ? String(rule.targetPort) : ""
            bind = rule.bindAddress
        }
    }

    let id: UUID
    var kind: ForwardingKind
    var name: String
    var note: String
    var enabled: Bool
    private var byMode: [ForwardingKind: Fields]

    init(_ rule: Forwarding) {
        id = rule.id
        kind = rule.kind
        name = rule.name
        note = rule.note
        enabled = rule.enabled
        byMode = [rule.kind: Fields(rule)]
    }

    var fields: Fields {
        get {
            byMode[kind] ?? Fields(Forwarding(kind: kind, bindAddress: "127.0.0.1",
                                              port: kind == .dynamic ? 1080 : 0,
                                              targetHost: "127.0.0.1", targetPort: 0))
        }
        set { byMode[kind] = newValue }
    }

    var resolved: Forwarding {
        Forwarding(id: id, kind: kind, bindAddress: fields.bind.trimmingCharacters(in: .whitespaces),
                   port: Int(fields.listenPort) ?? 0, targetHost: fields.targetHost.trimmingCharacters(in: .whitespaces),
                   targetPort: Int(fields.targetPort) ?? 0, enabled: enabled,
                   note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                   name: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The native v2 sheet updates fields, guidance and the animated path in the same place.
struct TunnelEditor: View {
    private enum Field: Hashable { case sshHost, sshPort, identity, listenPort, target, targetPort, bind, ruleName, note }

    let request: LaneModel.EditorRequest
    let model: LaneModel
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var identity: String
    @State private var autoConnect: Bool
    @State private var reconnect: Bool
    @State private var useConfig: Bool
    @State private var rules: [RuleDraft]
    @State private var selectedID: UUID
    @State private var advanced = false
    @State private var error: String?
    @State private var pendingSave: Tunnel?
    @State private var pendingConnect = false
    @FocusState private var focus: Field?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    private var style: LaneStyle { LaneStyle(scheme: scheme) }
    private var isNew: Bool { model.store.tunnel(request.tunnel.id) == nil }

    init(request: LaneModel.EditorRequest, model: LaneModel) {
        self.request = request
        self.model = model
        let tunnel = request.tunnel
        _name = State(initialValue: tunnel.name)
        _host = State(initialValue: tunnel.user.isEmpty ? tunnel.host : "\(tunnel.user)@\(tunnel.host)")
        _port = State(initialValue: tunnel.port == 22 ? "" : String(tunnel.port))
        _identity = State(initialValue: tunnel.identityFile)
        _autoConnect = State(initialValue: tunnel.autoConnect)
        _reconnect = State(initialValue: tunnel.autoReconnect)
        _useConfig = State(initialValue: tunnel.useSSHConfig)
        var drafts = tunnel.forwardings.map(RuleDraft.init)
        if drafts.isEmpty || request.addRule {
            drafts.append(RuleDraft(LaneModel.newRule()))
        }
        _rules = State(initialValue: drafts)
        _selectedID = State(initialValue: request.addRule ? drafts[drafts.count - 1].id : request.focusRule ?? drafts[0].id)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().overlay(style.edge)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        input(L10n.text("Name · Optional", "名称 · 可选"), text: $name,
                              placeholder: L10n.text("Development", "开发环境"))
                        input(L10n.text("SSH Host", "SSH 主机"), text: $host,
                              placeholder: "alias / user@host", field: .sshHost, mono: true)
                    }
                    rulesHeader
                    if let index = rules.firstIndex(where: { $0.id == selectedID }) {
                        ruleForm($rules[index])
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12)).foregroundStyle(style.warning)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 15)
            }
            Divider().overlay(style.edge)
            footer
        }
        .frame(minWidth: 620, idealWidth: 758, maxWidth: 758, minHeight: 460, idealHeight: 646, maxHeight: 646)
        .background(style.surface)
        .foregroundStyle(style.text)
        .tint(style.accent)
        .task {
            if request.focusRule != nil || request.addRule { focus = .listenPort }
            else if isNew { focus = .sshHost }
        }
        .confirmationDialog(L10n.text("Reconnect with these changes?", "保存后重新连接？"), isPresented: Binding(
            get: { pendingSave != nil }, set: { if !$0 { pendingSave = nil } }
        ), titleVisibility: .visible, presenting: pendingSave) { tunnel in
            Button(L10n.text("Save and Reconnect", "保存并重连")) {
                commit(tunnel, connect: pendingConnect)
                pendingSave = nil
            }
            Button(L10n.text("Cancel", "取消"), role: .cancel) { pendingSave = nil }
        } message: { _ in
            Text(L10n.text("Changing the endpoint or rules briefly interrupts this connection.",
                           "修改主机或规则会让当前连接短暂中断。"))
        }
    }

    private var titleBar: some View {
        HStack(spacing: 11) {
            LaneGlyph(size: 32, tinted: false)
            Text(isNew ? L10n.text("New Tunnel", "新建隧道") : L10n.text("Edit Tunnel", "编辑隧道"))
                .font(.system(size: 22, weight: .medium))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if isNew { Text("⌘N").font(.system(size: 10, weight: .medium)).foregroundStyle(style.secondary).accessibilityHidden(true) }
        }
        .padding(.horizontal, 28)
        .frame(height: 68)
    }

    private var rulesHeader: some View {
        HStack(spacing: 8) {
            Text(L10n.text("Forwarding rules", "转发规则")).font(.system(size: 14, weight: .semibold))
            if rules.count > 1 {
                Picker(L10n.text("Rule", "规则"), selection: $selectedID) {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        Text(rule.name.isEmpty ? "\(index + 1) · \(rule.kind.displayLabel)" : rule.name).tag(rule.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    rules.removeAll { $0.id == selectedID }
                    if let first = rules.first { selectedID = first.id }
                } label: {
                    Image(systemName: "minus.circle").foregroundStyle(style.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Remove rule", "移除此规则"))
            }
            Spacer()
            Button {
                let rule = RuleDraft(LaneModel.newRule())
                rules.append(rule)
                selectedID = rule.id
                focus = .listenPort
            } label: {
                Label(L10n.text("Add Rule", "添加规则"), systemImage: "plus")
            }
            .buttonStyle(LaneButtonStyle(kind: .subtle))
        }
    }

    private func ruleForm(_ rule: Binding<RuleDraft>) -> some View {
        let draft = rule.wrappedValue
        let fields = rule.fields
        let kind = draft.kind
        return VStack(alignment: .leading, spacing: 12) {
            ForwardingModePicker(kind: rule.kind)
            HStack(alignment: .top, spacing: 12) {
                input(listenLabel(kind), text: fields.listenPort, placeholder: kind == .dynamic ? "1080" : "15432", field: .listenPort, mono: true)
                    .frame(width: kind == .dynamic ? 210 : 152)
                if kind == .dynamic {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.text("The client chooses each destination", "每个请求由客户端选择目标"))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(style.ink(.dynamic))
                        Text(L10n.text("Set the browser or app to SOCKS5 and enter the local address and port.",
                                       "在浏览器或应用中选 SOCKS5，填本机地址和端口。"))
                            .font(.system(size: 11)).foregroundStyle(style.secondary)
                    }
                    .padding(.leading, 4).padding(.top, 7)
                    Spacer(minLength: 0)
                } else {
                    input(kind == .remote ? L10n.text("Mac target host", "本机目标主机") : L10n.text("Target host", "目标主机"),
                          text: fields.targetHost, placeholder: "127.0.0.1", field: .target, mono: true)
                    input(L10n.text("Target port", "目标端口"), text: fields.targetPort,
                          placeholder: "5432", field: .targetPort, mono: true)
                        .frame(width: 140)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                Text(L10n.text("Note", "备注")).fontWeight(.semibold)
                TextField(L10n.text("Optional note", "填写备注"), text: rule.note)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .note)
                Button { focus = .note } label: { Image(systemName: "pencil").foregroundStyle(style.accent) }
                    .buttonStyle(.plain).accessibilityLabel(L10n.text("Edit note", "编辑备注"))
            }
            .font(.system(size: 12)).foregroundStyle(style.secondary).frame(height: 29)
            RouteDiagram(forwarding: draft.resolved, sshHost: host, mode: .preview)
            advancedFields(rule)
        }
    }

    private func advancedFields(_ rule: Binding<RuleDraft>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            LaneDisclosureRow(isExpanded: $advanced, minHeight: 25) {
                HStack {
                    Text(L10n.text("Advanced options", "高级选项")).fontWeight(.semibold)
                    Spacer()
                    Text(useConfig ? L10n.text("Uses existing SSH configuration", "使用现有 SSH 配置") :
                            L10n.text("Direct configuration", "独立 SSH 配置")).foregroundStyle(style.secondary)
                }
            }
            .font(.system(size: 12))
            if advanced {
                HStack(spacing: 12) {
                    input(L10n.text("SSH Port", "SSH 端口"), text: $port, placeholder: "22", field: .sshPort, mono: true)
                    input(L10n.text("Listening address", "监听地址"), text: rule.fields.bind,
                          placeholder: "127.0.0.1", field: .bind, mono: true)
                }
                HStack(spacing: 12) {
                    input(L10n.text("Private key path", "私钥路径"), text: $identity, placeholder: "~/.ssh/id_ed25519",
                          field: .identity, mono: true)
                    input(L10n.text("Rule name", "规则名称"), text: rule.name, placeholder: "PostgreSQL", field: .ruleName)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 18) {
                        Toggle(L10n.text("Connect when Lane opens", "启动 Lane 时连接"), isOn: $autoConnect)
                        Toggle(L10n.text("Reconnect automatically", "自动重连"), isOn: $reconnect)
                    }
                    HStack(spacing: 18) {
                        Toggle(L10n.text("Use SSH configuration", "使用 SSH 配置"), isOn: $useConfig)
                        Toggle(L10n.text("Enable rule", "启用规则"), isOn: rule.enabled)
                    }
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(L10n.text("Cancel", "取消")) { dismiss() }
                .keyboardShortcut(.cancelAction).buttonStyle(LaneButtonStyle())
            Spacer()
            Button(L10n.text("Save Only", "仅保存")) { save(connect: false) }.buttonStyle(LaneButtonStyle())
            Button {
                save(connect: true)
            } label: {
                Label(L10n.text("Save and Connect", "保存并连接"), systemImage: "arrow.right")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(LaneButtonStyle(kind: .primary))
        }
        .padding(.horizontal, 28)
        .frame(height: 59)
    }

    private func input(_ label: String, text: Binding<String>, placeholder: String, field: Field? = nil, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(style.secondary)
            TextField(label, text: text, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: mono ? .monospaced : .default))
                .focused($focus, equals: field)
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(style.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(field != nil && focus == field ? style.accent : style.edge)
                        .allowsHitTesting(false)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listenLabel(_ kind: ForwardingKind) -> String {
        switch kind {
        case .local: L10n.text("Local listening port", "本机监听端口")
        case .remote: L10n.text("Server listening port", "服务器监听端口")
        case .dynamic: L10n.text("Local proxy port", "本机代理端口")
        }
    }

    /// Validate the actual serialized configuration and focus the first field that needs attention.
    private func save(connect: Bool) {
        error = nil
        var tunnel = request.tunnel
        tunnel.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = destination.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        tunnel.user = parts.count == 2 ? String(parts[0]) : ""
        tunnel.host = String(parts.last ?? "")
        tunnel.port = port.isEmpty ? 22 : Int(port) ?? 0
        tunnel.identityFile = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tunnel.identityFile.isEmpty { tunnel.authMethod = .publicKey }
        else if tunnel.authMethod == .publicKey { tunnel.authMethod = .automatic }
        tunnel.useSSHConfig = useConfig
        tunnel.autoConnect = autoConnect
        tunnel.autoReconnect = reconnect
        tunnel.forwardings = rules.map(\.resolved)

        if let issue = TunnelValidator.validate(tunnel).first(where: { $0.severity == .error }) {
            show(issue, tunnel: tunnel)
            return
        }
        if let old = model.store.tunnel(tunnel.id), model.manager.runtimes[tunnel.id]?.desiredOn == true,
           model.manager.requiresRestart(for: tunnel, replacing: old) {
            pendingConnect = connect
            pendingSave = tunnel
            return
        }
        commit(tunnel, connect: connect)
    }

    private func show(_ issue: ValidationIssue, tunnel: Tunnel) {
        switch issue.field {
        case .host, .user:
            focus = .sshHost
            error = L10n.text("Enter a valid alias or user@host.", "请输入有效的 SSH 别名或 user@host。")
        case .port:
            advanced = true
            focus = .sshPort
            error = L10n.text("SSH port must be between 1 and 65535.", "SSH 端口必须介于 1 和 65535。")
        case .identityFile:
            advanced = true
            focus = .identity
            error = L10n.text("Choose a private key file.", "请选择有效的私钥文件。")
        case .forwarding(let id):
            selectedID = id
            guard let rule = tunnel.forwardings.first(where: { $0.id == id }) else { return }
            if !TunnelValidator.isValidPort(rule.port) {
                focus = .listenPort
                error = L10n.text("Listening port must be between 1 and 65535.", "监听端口必须介于 1 和 65535。")
            } else if rule.kind != .dynamic && !TunnelValidator.isValidHostToken(rule.targetHost) {
                focus = .target
                error = L10n.text("Enter a valid target host.", "请输入有效的目标主机。")
            } else if rule.kind != .dynamic && !TunnelValidator.isValidPort(rule.targetPort) {
                focus = .targetPort
                error = L10n.text("Target port must be between 1 and 65535.", "目标端口必须介于 1 和 65535。")
            } else {
                focus = .listenPort
                error = issue.message
            }
        default:
            error = issue.message
        }
    }

    private func commit(_ tunnel: Tunnel, connect: Bool) {
        do { try model.save(tunnel, connect: connect) }
        catch { self.error = error.localizedDescription }
    }
}
