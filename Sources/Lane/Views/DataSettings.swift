import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Presents native file pickers and the shared import preview within the settings window.
struct DataSettings: View {
    let model: LaneModel
    @State private var preview: LaneModel.ImportPreview?
    @State private var feedback: String?
    @State private var error: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Form {
            Section(L10n.text("Import", "导入")) {
                LabeledContent("~/.ssh/config") {
                    SettingsActionButton(L10n.text("Preview Hosts…", "预览主机…")) {
                        finish { preview = try model.sshConfigImport() }
                    }
                }
                LabeledContent(L10n.text("Lane, Porthole or Codinn", "Lane、Porthole 或 Codinn")) {
                    SettingsActionButton(L10n.text("Merge File…", "合并文件…")) { chooseBackup(restoring: false) }
                }
            }
            .disabled(model.store.loadError != nil)

            Section {
                LabeledContent(L10n.text("Tunnel configurations", "隧道配置")) {
                    SettingsActionButton(L10n.text("Export Backup…", "导出备份…"), action: exportBackup)
                }
            } header: {
                Text(L10n.text("Export", "导出"))
            } footer: {
                Text(L10n.text("The backup contains tunnels and forwarding rules. Saved passwords and passphrases stay in Keychain.",
                               "备份包含隧道与转发规则。已保存的密码和口令留在钥匙串。"))
                    .font(.caption).foregroundStyle(LaneStyle(scheme: scheme).secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section(L10n.text("Restore", "恢复")) {
                LabeledContent(L10n.text("Lane or Porthole backup", "Lane 或 Porthole 备份")) {
                    SettingsActionButton(L10n.text("Restore Backup…", "从备份恢复…")) { chooseBackup(restoring: true) }
                        .disabled(!model.store.canRestore)
                }
                if let loadError = model.store.loadError {
                    Text(loadError).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let fileURL = model.store.fileURL {
                Section(L10n.text("Storage", "存储")) {
                    LabeledContent {
                        SettingsActionButton(L10n.text("Show in Finder", "在 Finder 中显示")) { reveal(fileURL) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("Configuration file", "配置文件"))
                            Text((fileURL.path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if let feedback {
                Text(feedback).font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $preview) { preview in
            ImportSheet(preview: preview) { tunnels in
                if preview.kind == .restore {
                    let preserved = try model.restoreBackup(preview)
                    feedback = preserved.map {
                        L10n.text("Restored. Previous file: \($0.lastPathComponent)",
                                  "已恢复。原文件：\($0.lastPathComponent)")
                    } ?? L10n.text("Restored tunnel library.", "已恢复隧道库。")
                } else {
                    let count = try model.importSelected(tunnels, kind: preview.kind)
                    feedback = L10n.text("Imported \(count) tunnels.", "已导入 \(count) 条隧道。")
                }
            }
        }
        .alert("Lane", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.text("OK", "好"), role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// Selecting a file reads it into a preview first. The library is written only from the preview.
    private func chooseBackup(restoring: Bool) {
        let panel = NSOpenPanel()
        panel.title = restoring ? L10n.text("Restore Backup", "从备份恢复") : L10n.text("Import Tunnels", "导入隧道")
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        finish { preview = try model.backupImport(from: file, restoring: restoring) }
    }

    private func exportBackup() {
        finish {
            let backup = try model.store.exportData()
            let panel = NSSavePanel()
            panel.title = L10n.text("Export Tunnel Backup", "导出隧道备份")
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Lane Tunnels.json"
            guard panel.runModal() == .OK, let file = panel.url else { return }
            try backup.write(to: file, options: .atomic)
            feedback = L10n.text("Exported “\(file.lastPathComponent)”.", "已导出「\(file.lastPathComponent)」。")
        }
    }

    /// An empty library has no file yet, so reveal its containing directory.
    private func reveal(_ file: URL) {
        finish {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([
                FileManager.default.fileExists(atPath: file.path) ? file : directory
            ])
        }
    }

    private func finish(_ action: () throws -> Void) {
        feedback = nil
        do { try action() }
        catch { self.error = error.localizedDescription }
    }
}
