import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Presents native file pickers and the shared import preview within the settings window.
struct DataSettings: View {
    let model: PortlaneModel
    @State private var preview: PortlaneModel.ImportPreview?
    @State private var feedback: String?
    @State private var error: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Form {
            Section(L10n.text("Import", "导入")) {
                LabeledContent("~/.ssh/config") {
                    Button(L10n.text("Preview Hosts…", "预览主机…")) {
                        finish { preview = try model.sshConfigImport() }
                    }
                }
                LabeledContent(L10n.text("Portlane, Porthole or Codinn", "Portlane、Porthole 或 Codinn")) {
                    Button(L10n.text("Choose File…", "选择文件…"), action: chooseBackup)
                }
            }

            Section {
                LabeledContent(L10n.text("Tunnel configurations", "隧道配置")) {
                    Button(L10n.text("Export Backup…", "导出备份…"), action: exportBackup)
                }
            } header: {
                Text(L10n.text("Export", "导出"))
            } footer: {
                Text(L10n.text("The backup contains tunnels and forwarding rules. Saved passwords and passphrases stay in Keychain.",
                               "备份包含隧道与转发规则。已保存的密码和口令留在钥匙串。"))
                    .font(.caption).foregroundStyle(PortlaneStyle(scheme: scheme).secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let fileURL = model.store.fileURL {
                Section(L10n.text("Storage", "存储")) {
                    LabeledContent {
                        Button(L10n.text("Show in Finder", "在 Finder 中显示")) { reveal(fileURL) }
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
                let count = try model.importSelected(tunnels, kind: preview.kind)
                feedback = L10n.text("Imported \(count) tunnels.", "已导入 \(count) 条隧道。")
            }
        }
        .alert("Portlane", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.text("OK", "好"), role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// Selecting a file reads it into a preview first. The library is written only from the preview.
    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Import Tunnels", "导入隧道")
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        finish { preview = try model.backupImport(from: file) }
    }

    private func exportBackup() {
        finish {
            let backup = try model.store.exportData()
            let panel = NSSavePanel()
            panel.title = L10n.text("Export Tunnel Backup", "导出隧道备份")
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Portlane Tunnels.json"
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
