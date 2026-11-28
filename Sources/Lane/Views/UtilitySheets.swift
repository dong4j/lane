import SwiftUI
import LaneCore

/// Shows the concrete tunnels and forwarding rules before writing any imported configuration.
struct ImportSheet: View {
    let preview: LaneModel.ImportPreview
    let onImport: ([Tunnel]) throws -> Void
    @State private var selected: Set<UUID>
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(preview: LaneModel.ImportPreview, onImport: @escaping ([Tunnel]) throws -> Void) {
        self.preview = preview
        self.onImport = onImport
        _selected = State(initialValue: Set(preview.tunnels.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Import Tunnels", "导入隧道")).font(.title2.weight(.semibold))
            Text(preview.source).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(preview.tunnels) { tunnel in
                        Toggle(isOn: Binding(
                            get: { selected.contains(tunnel.id) },
                            set: { value in if value { selected.insert(tunnel.id) } else { selected.remove(tunnel.id) } }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tunnel.displayName).fontWeight(.semibold)
                                if tunnel.displayName != tunnel.hostNotation {
                                    Text(tunnel.hostNotation).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                ForEach(tunnel.forwardings) { rule in
                                    Text(rule.commandString).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                if tunnel.autoConnect {
                                    Text(L10n.text("Connects when Lane opens", "启动 Lane 时连接"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if preview.skippedCount > 0 {
                Text(L10n.text("Skipped \(preview.skippedCount) duplicate or invalid entries.",
                               "已跳过 \(preview.skippedCount) 条重复或无效的记录。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L10n.text("Cancel", "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction).buttonStyle(LaneButtonStyle())
                Button(L10n.text("Import Selected", "导入所选")) {
                    do {
                        try onImport(preview.tunnels.filter { selected.contains($0.id) })
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(LaneButtonStyle(kind: .primary))
                .disabled(selected.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 510, height: 390)
    }
}

/// The full log is an explicit drill-down and is copyable as plain text.
struct FullLogSheet: View {
    let tunnel: Tunnel
    let model: LaneModel
    @Environment(\.dismiss) private var dismiss
    private var logs: [LogEntry] { model.manager.displayRuntime(tunnel.id)?.logs ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("SSH Log", "SSH 日志")).font(.title2.weight(.semibold))
            Text(tunnel.displayName).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(logs) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Text(entry.date, style: .time).foregroundStyle(.secondary)
                            Text(entry.message).textSelection(.enabled)
                        }
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                CopyAction(model: model, value: logs.map { "\($0.date.ISO8601Format()) [\($0.level)] \($0.message)" }.joined(separator: "\n"),
                           key: "log-\(tunnel.id)", title: L10n.text("Copy log", "复制日志"))
                    .disabled(logs.isEmpty)
                Button(L10n.text("Done", "完成")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(LaneButtonStyle(kind: .primary))
            }
        }
        .padding(22)
        .frame(width: 680, height: 445)
    }
}
