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
                perform(successMessage: L10n.text("Copied", "已复制")) {
                    let config = try access.configuration(forClientNamed: client.name)
                    let value = switch client {
                    case .codex: config.codexCommand
                    case .claude: config.claudeCommand
                    case .generic: config.json
                    }
                    model.copy(value, key: "agent-setup-\(client.name)")
                }
            }
            .disabled(!enabled)
            .accessibilityLabel(L10n.text("Copy \(title) setup", "复制 \(title) 接入配置"))
        }
    }

    private func perform(successMessage: String? = nil, _ action: () throws -> Void) {
        do {
            try action()
            failed = false
            feedback = successMessage
        } catch {
            failed = true
            feedback = error.localizedDescription
        }
    }
}
