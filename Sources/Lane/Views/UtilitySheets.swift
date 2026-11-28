import SwiftUI
import LaneCore

/// Shows the concrete tunnels and forwarding rules before writing any imported configuration.
struct ImportSheet: View {
    let preview: LaneModel.ImportPreview
    let onImport: ([Tunnel]) throws -> Void
    @State private var selected: Set<UUID>
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var style: LaneStyle { LaneStyle(scheme: scheme) }
    private var isRestoring: Bool { preview.kind == .restore }

    init(preview: LaneModel.ImportPreview, onImport: @escaping ([Tunnel]) throws -> Void) {
        self.preview = preview
        self.onImport = onImport
        _selected = State(initialValue: Set(preview.tunnels.map(\.id)))
    }

    var body: some View {
        let notes = importNotes
        return VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if isRestoring { restoreSummary }
                    tunnelList
                    if !notes.isEmpty { notesSection(notes) }
                }
            }
            .frame(maxHeight: 270)
            .fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(style.warning)
            }
            Divider().overlay(style.edge)
            footer
        }
        .padding(20)
        .frame(width: 510)
        .background(style.window)
        .foregroundStyle(style.text)
        .tint(style.accent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isRestoring ? L10n.text("Restore Backup", "从备份恢复") :
                    L10n.text("Import Tunnels", "导入隧道"))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(preview.source)
                .font(.callout.monospaced())
                .foregroundStyle(style.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(preview.source)
        }
    }

    private var tunnelList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if preview.tunnels.isEmpty {
                Label(isRestoring ? L10n.text("This backup contains no tunnels.", "此备份没有隧道。") :
                        L10n.text("No new, valid forwards were found.", "没有找到可导入的新转发。"),
                      systemImage: "tray")
                    .font(.callout)
                    .foregroundStyle(style.secondary)
                    .padding(12)
            }
            ForEach(preview.tunnels) { tunnel in
                if tunnel.id != preview.tunnels.first?.id {
                    Divider().overlay(style.edge)
                }
                tunnelRow(tunnel)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(style.edge).allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func tunnelRow(_ tunnel: Tunnel) -> some View {
        if isRestoring {
            details(tunnel)
        } else {
            Toggle(isOn: Binding(
                get: { selected.contains(tunnel.id) },
                set: { isSelected in
                    if isSelected {
                        selected.insert(tunnel.id)
                    } else {
                        selected.remove(tunnel.id)
                    }
                }
            )) {
                details(tunnel)
            }
            .toggleStyle(.checkbox)
        }
    }

    private func details(_ tunnel: Tunnel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tunnel.displayName).font(.headline)
            if tunnel.displayName != tunnel.hostNotation {
                Text(tunnel.hostNotation).font(.caption.monospaced()).foregroundStyle(style.secondary)
            }
            if let source = preview.configSources[tunnel.id] {
                Text(source)
                    .font(.caption.monospaced())
                    .foregroundStyle(style.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(source)
            }
            ForEach(tunnel.forwardings) { rule in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(rule.kind.flag)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .foregroundStyle(style.ink(rule.kind))
                        .background(style.tile(rule.kind), in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel(rule.kind.displayLabel)
                    Text(route(rule))
                        .foregroundStyle(style.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption.monospaced())
                .help(rule.commandString)
            }
            if tunnel.autoConnect {
                Text(L10n.text("Connects when Lane opens", "启动 Lane 时连接"))
                    .font(.caption).foregroundStyle(style.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// An omitted bind address leaves the exact listener address up to OpenSSH.
    private func route(_ rule: Forwarding) -> String {
        let listener = rule.bindAddress.trimmingCharacters(in: .whitespaces).isEmpty
            ? ":\(rule.port)" : rule.listenDisplayAddress
        let target = rule.targetDisplayAddress
        return switch rule.kind {
        case .local: L10n.text("Mac \(listener) → SSH side \(target)", "本机 \(listener) → SSH 侧 \(target)")
        case .remote: L10n.text("SSH \(listener) → Mac side \(target)", "SSH 侧 \(listener) → 本机侧 \(target)")
        case .dynamic: L10n.text("SOCKS5 on this Mac \(listener)", "本机 SOCKS5 \(listener)")
        }
    }

    private var importNotes: [String] {
        var notes = preview.configWarnings
        if !preview.ignoredOptions.isEmpty {
            let options = preview.ignoredOptions.joined(separator: ", ")
            notes.append(L10n.text("Ignored extra SSH options · \(options)", "已忽略额外 SSH 选项 · \(options)"))
        }
        if preview.skippedCount > 0 {
            notes.append(L10n.text("Skipped \(preview.skippedCount) duplicate or invalid entries.",
                                   "已跳过 \(preview.skippedCount) 条重复或无效的记录。"))
        }
        return notes
    }

    private func notesSection(_ notes: [String]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notes.indices, id: \.self) { index in
                    Text(notes[index]).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        } label: {
            Label(L10n.text("Import notes · \(notes.count)", "导入提示 · \(notes.count) 条"), systemImage: "info.circle")
                .font(.callout)
        }
        .disclosureGroupStyle(LaneDisclosureStyle(minHeight: 32, inset: 12))
        .foregroundStyle(style.secondary)
        .background(style.control, in: RoundedRectangle(cornerRadius: 8))
    }

    private var restoreSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(L10n.text("Replace the library with \(preview.tunnels.count) tunnels. A copy of the current file is kept beside it.",
                            "将用备份中的 \(preview.tunnels.count) 条隧道替换当前库，原文件会保存在同一目录。"),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
            if !preview.removedNames.isEmpty {
                Text(L10n.text("Removed from the library", "将从当前库移除")).font(.subheadline.weight(.semibold))
                ForEach(preview.removedNames.indices, id: \.self) { index in
                    Text(preview.removedNames[index]).font(.caption)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(style.warning)
        .background(style.warningFill, in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !isRestoring {
                Text(L10n.text("\(selected.count) of \(preview.tunnels.count) selected",
                               "已选 \(selected.count) / \(preview.tunnels.count)"))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(style.secondary)
            }
            Spacer()
            Button(L10n.text("Cancel", "取消")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(LaneButtonStyle())
            Button(isRestoring ? L10n.text("Restore Library", "恢复隧道库") :
                       L10n.text("Import Selected", "导入所选")) {
                do {
                    try onImport(preview.tunnels.filter { selected.contains($0.id) })
                    dismiss()
                } catch {
                    self.error = error.localizedDescription
                }
            }
            .keyboardShortcut(isRestoring ? nil : .defaultAction)
            .buttonStyle(LaneButtonStyle(kind: .primary))
            .disabled(!isRestoring && selected.isEmpty)
        }
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
