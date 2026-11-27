import SwiftUI

/// Keeps the editable SSH path separate from the client used by live connections.
struct ConnectionSettings: View {
    @Bindable var preferences: PortlanePreferences
    @State private var draft: String
    @State private var version: String?
    @State private var checking = false
    @State private var error: String?
    @Environment(\.colorScheme) private var scheme

    init(preferences: PortlanePreferences) {
        self.preferences = preferences
        _draft = State(initialValue: preferences.customSSHPath)
    }

    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("Restore tunnels after Mac wakes", "Mac 唤醒后恢复隧道"), isOn: $preferences.reconnectOnWake)
            } header: {
                Text(L10n.text("Recovery", "连接恢复"))
            } footer: {
                Text(L10n.text("Applies to active tunnels with automatic reconnection enabled. Set connect at launch in each tunnel’s advanced options.",
                               "适用于已开启自动重连的活动隧道。启动时连接可在单条隧道的高级选项中设置。"))
                    .font(.caption).foregroundStyle(PortlaneStyle(scheme: scheme).secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                LabeledContent(L10n.text("Current client", "当前客户端")) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(preferences.sshPath).font(.callout.monospaced()).textSelection(.enabled)
                        if let version {
                            Text(version).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                LabeledContent(L10n.text("Custom executable", "自定义可执行文件")) {
                    TextField(L10n.text("Custom executable", "自定义可执行文件"), text: $draft, prompt: Text("/opt/homebrew/bin/ssh"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .multilineTextAlignment(.leading)
                        .frame(idealWidth: 276, maxWidth: 308)
                        .disabled(checking)
                        .onSubmit { apply(draft) }
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        Button(L10n.text("Use System Client", "使用系统客户端")) { apply("") }
                            .disabled(checking || (preferences.customSSHPath.isEmpty && draft.isEmpty))
                        Button(L10n.text("Verify and Apply", "验证并应用")) { apply(draft) }
                            .disabled(checking || draft == preferences.customSSHPath)
                    }
                } label: {
                    if checking {
                        ProgressView(L10n.text("Checking OpenSSH…", "正在检查 OpenSSH…")).controlSize(.small)
                    }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("OpenSSH")
            } footer: {
                Text(L10n.text("The selected client is used for the next connection or reconnection.",
                               "所选客户端会在下一次连接或重连时生效。"))
                    .font(.caption).foregroundStyle(PortlaneStyle(scheme: scheme).secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            let path = preferences.sshPath
            let detected = (try? await OpenSSHClient.version(at: path))
            guard !Task.isCancelled, preferences.sshPath == path else { return }
            version = detected ?? L10n.text("Version unavailable", "无法读取版本")
        }
    }

    /// Commit only after the selected executable responds as OpenSSH.
    private func apply(_ input: String) {
        guard !checking else { return }
        let path = OpenSSHClient.expandedPath(input)
        let custom = path == OpenSSHClient.systemPath ? "" : path
        checking = true
        error = nil
        Task {
            defer { checking = false }
            do {
                version = try await OpenSSHClient.version(at: custom.isEmpty ? OpenSSHClient.systemPath : custom)
                preferences.customSSHPath = custom
                draft = custom
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
