import SwiftUI
import LaneCore

/// Issues per-client setup recipes and exposes every permission that can open a forwarding.
struct AgentSettings: View {
    private enum Recipe: String, CaseIterable, Identifiable {
        case generic, codex, claude, cursor

        var id: Self { self }
        var title: String {
            switch self {
            case .generic: L10n.text("Generic", "通用")
            case .codex: "Codex"
            case .claude: "Claude Code"
            case .cursor: "Cursor"
            }
        }
    }

    let model: LaneModel
    @State private var clientName = ""
    @State private var selectedClient: UUID?
    @State private var recipe: Recipe = .generic
    @State private var revoking: AgentClient?
    @State private var checking = false
    @State private var feedback: String?
    @State private var failed = false

    private var access: AgentAccess { model.agents }
    private var client: AgentClient? {
        access.ledger.clients.first { $0.id == selectedClient } ?? access.ledger.clients.first
    }

    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("Allow Agent requests", "允许 Agent 申请隧道"), isOn: Binding(
                    get: { access.ledger.requestsEnabled },
                    set: { enabled in perform { try access.setRequestsEnabled(enabled) } }
                ))
                .disabled(!access.available)
                if access.storageError || access.serviceError {
                    Label(access.statusMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(L10n.text("Agent Access", "Agent 接入"))
            } footer: {
                Text(L10n.text("This switch and the client's permission must both be on to request a tunnel. Turning either off ends its outstanding requests.",
                               "总开关和客户端的申请权限均开启后才可申请。关闭任一项会结束受影响的申请。"))
            }

            Section {
                HStack {
                    TextField(L10n.text("Client name", "客户端名称"), text: $clientName, prompt: Text("Codex · Dev Mac"))
                        .onSubmit(addClient)
                    Button(L10n.text("Pair Client", "配对客户端"), action: addClient)
                        .disabled(clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(!access.available)
                if let client {
                    pairing(client)
                }
                if let feedback {
                    Label(feedback, systemImage: failed ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.caption).foregroundStyle(failed ? Color.orange : Color.secondary)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            } header: {
                Text(L10n.text("Paired Clients", "已配对的客户端"))
            } footer: {
                Text(L10n.text("Create one pairing per client so its requests appear separately in Agent Activity.",
                               "为每个客户端单独配对，便于在 Agent 活动中查找它的申请。"))
            }

            Section {
                if model.store.tunnels.isEmpty {
                    Text(L10n.text("Save an SSH profile in the main window to share rules or approve a temporary destination.",
                                   "在主窗口保存 SSH 配置后，即可共享规则或审批临时目标。"))
                        .foregroundStyle(.secondary)
                }
                ForEach(model.store.tunnels) { profile in
                    shareChoices(profile)
                }
            } header: {
                Text(L10n.text("Shared Rules", "共享规则"))
            } footer: {
                Text(L10n.text("Paired clients can discover shared loopback rules. Temporary destinations and external listeners always need approval.",
                               "已配对的客户端可发现共享的环回规则。临时目标和外部入口每次都要审批。"))
            }
        }
        .confirmationDialog(L10n.text("Revoke this pairing?", "撤销此配对？"), isPresented: Binding(
            get: { revoking != nil }, set: { if !$0 { revoking = nil } }
        ), presenting: revoking) { client in
            Button(L10n.text("Revoke Pairing", "撤销配对"), role: .destructive) {
                perform { try access.revokeClient(client.id) }
                revoking = nil
            }
        } message: { client in
            Text(L10n.text("Active requests from \(client.name) will end.", "将结束 \(client.name) 尚未完成的申请。"))
        }
    }

    @ViewBuilder
    private func pairing(_ client: AgentClient) -> some View {
        Picker(L10n.text("Client", "客户端"), selection: Binding(
            get: { client.id },
            set: { selectedClient = $0; feedback = nil }
        )) {
            ForEach(access.ledger.clients) { item in Text(item.name).tag(item.id) }
        }
        Toggle(L10n.text("Allow this client to request tunnels", "允许此客户端申请隧道"), isOn: Binding(
            get: { client.canRequest },
            set: { enabled in perform { try access.setClientRequests(client.id, enabled: enabled) } }
        ))
        .disabled(!access.available)
        if let config = access.configuration(for: client.id) {
            Picker(L10n.text("Setup format", "接入方式"), selection: $recipe) {
                ForEach(Recipe.allCases) { item in Text(item.title).tag(item) }
            }
            .pickerStyle(.segmented)

            setupActions(config, clientID: client.id)
            HStack {
                let title = L10n.text("Copy Project Instructions", "复制项目约定")
                CopyAction(model: model, value: AgentMCP.projectInstructions, key: "agent-project-instructions", title: title)
                    .accessibilityLabel(title)
                Spacer()
                Button(L10n.text("Revoke…", "撤销配对…")) { revoking = client }
                    .disabled(!access.available)
            }
        }
    }

    private func setupActions(_ config: AgentMCPConfiguration, clientID: UUID) -> some View {
        let value = switch recipe {
        case .generic: config.json
        case .codex: config.codexCommand
        case .claude: config.claudeCommand
        case .cursor: config.cursorJSON
        }
        let copyTitle = switch recipe {
        case .generic: L10n.text("Copy MCP Configuration", "复制通用 MCP 配置")
        case .codex, .claude: L10n.text("Copy Command", "复制接入命令")
        case .cursor: L10n.text("Copy Cursor Configuration", "复制 Cursor 配置")
        }
        let detailsTitle = switch recipe {
        case .generic: L10n.text("View JSON and Manual Fields", "查看 JSON 和手填字段")
        case .codex, .claude: L10n.text("View Command", "查看接入命令")
        case .cursor: L10n.text("View Cursor Configuration", "查看 Cursor 配置")
        }
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                CopyAction(model: model, value: value, key: "agent-\(recipe.rawValue)", title: copyTitle, prominent: true)
                    .accessibilityLabel(copyTitle)
                Button(L10n.text("Test Connection", "接入自检")) { check(config, for: clientID) }
                    .disabled(checking)
                if checking { ProgressView().controlSize(.small) }
            }
            if recipe == .cursor {
                Text(L10n.text("Merge into ~/.cursor/mcp.json.", "合并到 ~/.cursor/mcp.json。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(detailsTitle) {
                VStack(alignment: .leading, spacing: 7) {
                    if recipe == .generic {
                        configField("transport", text: "stdio", copy: false)
                        configField("command", text: config.executable)
                        configField("args", text: config.argsJSON)
                        configField("env", text: L10n.text("Leave empty", "留空"), copy: false)
                    }
                    Text(value)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 7))
                }
                .padding(.top, 6)
            }
        }
    }

    private func shareChoices(_ profile: Tunnel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName).fontWeight(.semibold)
                    Text(profile.hostNotation).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                CopyAction(model: model, value: profile.id.uuidString, key: "agent-profile-\(profile.id)",
                           title: L10n.text("Copy SSH Profile ID", "复制 SSH 配置 ID"))
            }
            ForEach(profile.forwardings.filter { access.canShare($0, from: profile) }) { rule in
                Toggle(isOn: Binding(
                    get: { access.isShared(rule, from: profile) },
                    set: { enabled in perform { try access.setShared(rule, from: profile, enabled: enabled) } }
                )) {
                    HStack {
                        Text(rule.displayName)
                        Text(rule.targetDisplayAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .disabled(!access.available)
            }
        }
    }

    private func configField(_ label: String, text: String, copy: Bool = true) -> some View {
        HStack(spacing: 5) {
            Text(label).frame(minWidth: 66, alignment: .leading)
            Spacer(minLength: 0)
            Text(text.replacingOccurrences(of: "\n", with: " "))
                .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
            if copy {
                let title = L10n.text("Copy \(label)", "复制 \(label)")
                CopyAction(model: model, value: text, key: "agent-field-\(label)", title: title, iconOnly: true)
                    .accessibilityLabel(title)
            }
        }
    }

    private func addClient() {
        guard access.available, !clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        perform {
            let client = try access.pair(clientName)
            selectedClient = client.id
            clientName = ""
        }
    }

    private func perform(_ action: () throws -> Void) {
        feedback = nil
        do { try action() }
        catch {
            failed = true
            feedback = error.localizedDescription
        }
    }

    /// Test the same executable and arguments the selected client will use.
    private func check(_ config: AgentMCPConfiguration, for clientID: UUID) {
        checking = true
        feedback = nil
        Task {
            defer { checking = false }
            do {
                let canRequest = try await config.check()
                guard client?.id == clientID else { return }
                failed = false
                feedback = canRequest
                    ? L10n.text("Connected · Requests enabled", "接入成功 · 可申请隧道")
                    : L10n.text("Connected · Read-only", "接入成功 · 只读")
            } catch {
                guard client?.id == clientID else { return }
                failed = true
                feedback = error.localizedDescription
            }
        }
    }
}
