import SwiftUI

/// Offers one access switch and ready-to-copy setup for local MCP clients.
struct AgentSettings: View {
    private enum Client {
        case codex, claude, generic

        var name: String {
            switch self {
            case .codex: "Codex"
            case .claude: "Claude Code"
            case .generic: "Generic"
            }
        }
    }

    let model: LaneModel
    @State private var manualFields = false
    @State private var genericConfiguration: AgentMCPConfiguration?
    @State private var feedback: String?
    @State private var failed = false

    private var access: AgentAccess { model.agents }
    private var enabled: Bool { access.available && access.ledger.requestsEnabled }

    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("Allow Agent access", "允许 Agent 接入"), isOn: Binding(
                    get: { access.ledger.requestsEnabled },
                    set: { value in perform { try access.setRequestsEnabled(value) } }
                ))
                .disabled(!access.available)
                if access.storageError || access.serviceError {
                    Label(access.statusMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(L10n.text("Agent Access", "Agent 接入"))
            } footer: {
                Text(L10n.text(
                    "Saved loopback forwards are available. Temporary and external routes need approval. Switching off ends Agent leases.",
                    "已保存的环回转发可直接申请。临时目标和外部入口需审批。关闭后结束 Agent 的申请。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                recipeRow("Codex", client: .codex)
                recipeRow("Claude Code", client: .claude)
                recipeRow(L10n.text("Generic MCP", "通用 MCP"), client: .generic)

                DisclosureGroup(L10n.text("Manual MCP fields", "手动填写 MCP 参数"), isExpanded: $manualFields) {
                    VStack(alignment: .leading, spacing: 9) {
                        LabeledContent(L10n.text("Transport", "传输方式"), value: "stdio")
                        manualField("command", value: genericConfiguration?.executable)
                        manualField("args", value: genericConfiguration?.argsJSON)
                        LabeledContent("env", value: L10n.text("Leave empty", "留空"))
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                }
                .disclosureGroupStyle(LaneDisclosureStyle(minHeight: 38, inset: 10))
                .listRowInsets(EdgeInsets())
                .onChange(of: manualFields) { _, expanded in
                    if expanded, enabled { prepareGeneric() }
                }
                .onChange(of: enabled) { _, active in
                    if active, manualFields { prepareGeneric() }
                }

                if let feedback {
                    Label(feedback, systemImage: failed ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(failed ? Color.orange : Color.secondary)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            } header: {
                Text(L10n.text("Connect a Client", "接入方式"))
            }
        }
    }

    private func recipeRow(_ title: String, client: Client) -> some View {
        LabeledContent(title) {
            SettingsActionButton(client == .generic ? L10n.text("Copy Configuration", "复制配置") :
                                 L10n.text("Copy Command", "复制命令")) {
                guard let config = configuration(for: client) else { return }
                let value = switch client {
                case .codex: config.codexCommand
                case .claude: config.claudeCommand
                case .generic: config.json
                }
                copy(value, key: "agent-setup-\(client.name)")
            }
            .disabled(!enabled)
            .accessibilityLabel(L10n.text("Copy \(title) setup", "复制 \(title) 接入配置"))
        }
    }

    private func manualField(_ title: String, value: String?) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 4) {
                if let value {
                    Text(value.replacingOccurrences(of: "\n", with: " "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                SettingsActionButton(L10n.text("Copy", "复制")) {
                    guard let config = configuration(for: .generic) else { return }
                    copy(title == "command" ? config.executable : config.argsJSON, key: "agent-field-\(title)")
                }
                .disabled(!enabled)
                .accessibilityLabel(L10n.text("Copy \(title)", "复制 \(title)"))
            }
        }
    }

    /// A client identity is prepared only when its setup is requested.
    private func configuration(for client: Client) -> AgentMCPConfiguration? {
        do {
            let config = try access.configuration(forClientNamed: client.name)
            if client == .generic { genericConfiguration = config }
            failed = false
            feedback = nil
            return config
        } catch {
            failed = true
            feedback = error.localizedDescription
            return nil
        }
    }

    private func prepareGeneric() {
        _ = configuration(for: .generic)
    }

    private func copy(_ value: String, key: String) {
        model.copy(value, key: key)
        failed = false
        feedback = L10n.text("Copied", "已复制")
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            failed = false
            feedback = nil
        } catch {
            failed = true
            feedback = error.localizedDescription
        }
    }
}
