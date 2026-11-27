import SwiftUI
import PortlaneCore

/// Shows the concrete aliases and TCP entries before writing any imported configuration.
struct ImportSheet: View {
    let preview: PortlaneModel.ImportPreview
    let model: PortlaneModel
    @State private var selected: Set<UUID>
    @Environment(\.dismiss) private var dismiss

    init(preview: PortlaneModel.ImportPreview, model: PortlaneModel) {
        self.preview = preview
        self.model = model
        _selected = State(initialValue: Set(preview.tunnels.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Import SSH Configuration", "导入 SSH 配置")).font(.title2.weight(.semibold))
            Text("~/.ssh/config").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(preview.tunnels) { tunnel in
                        Toggle(isOn: Binding(
                            get: { selected.contains(tunnel.id) },
                            set: { value in if value { selected.insert(tunnel.id) } else { selected.remove(tunnel.id) } }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tunnel.host).fontWeight(.semibold)
                                ForEach(tunnel.forwardings) { rule in
                                    Text(rule.commandString).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(L10n.text("Cancel", "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction).buttonStyle(LaneButtonStyle())
                Button(L10n.text("Import Selected", "导入所选")) {
                    model.importSelected(preview.tunnels.filter { selected.contains($0.id) })
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
    let model: PortlaneModel
    @Environment(\.dismiss) private var dismiss
    private var logs: [LogEntry] { model.manager.runtimes[tunnel.id]?.logs ?? [] }

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
