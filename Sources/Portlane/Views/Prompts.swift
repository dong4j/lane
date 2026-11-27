import AppKit
import PortlaneCore
import SwiftUI

struct PromptRequest: Identifiable {
    struct HostKeyDetail {
        var host: String
        var keyType: String
        var fingerprint: String
    }

    enum Kind {
        case password
        case passphrase
        case proxyPassword
        case secret
        case hostKey(HostKeyDetail)
        case confirm
    }

    let id = UUID()
    let tunnelID: UUID
    let tunnelName: String
    let kind: Kind
    let message: String
    /// Keychain account to save the answer to when "Remember" is checked.
    let rememberAccount: String?
}

/// Shows ssh's questions as small native panels, one at a time.
@MainActor
final class PromptPresenter {
    private struct Pending {
        let request: PromptRequest
        let continuation: CheckedContinuation<AskpassReply, Never>
    }

    private var queue: [Pending] = []
    private var current: (pending: Pending, panel: NSPanel)?
    private var closeObserver: NSObjectProtocol?

    func ask(_ request: PromptRequest) async -> AskpassReply {
        await withCheckedContinuation { continuation in
            queue.append(Pending(request: request, continuation: continuation))
            showNextIfIdle()
        }
    }

    func cancel(tunnelID: UUID) {
        let (drop, keep) = (queue.filter { $0.request.tunnelID == tunnelID }, queue.filter { $0.request.tunnelID != tunnelID })
        queue = keep
        for p in drop { p.continuation.resume(returning: .cancelled) }
        if let current, current.pending.request.tunnelID == tunnelID {
            finish(.cancelled)
        }
    }

    private func showNextIfIdle() {
        guard current == nil, !queue.isEmpty else { return }
        let pending = queue.removeFirst()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let view = PromptView(request: pending.request) { [weak self] reply, remember in
            if reply.ok, remember, let account = pending.request.rememberAccount {
                Keychain.set(reply.answer, for: account)
            }
            self?.finish(reply)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center()
        current = (pending, panel)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self, weak panel] _ in
            Task { @MainActor in
                if let current = self?.current, current.panel === panel { self?.finish(.cancelled) }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func finish(_ reply: AskpassReply) {
        guard let current else { return }
        self.current = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        current.panel.orderOut(nil)
        current.pending.continuation.resume(returning: reply)
        showNextIfIdle()
    }
}

struct PromptView: View {
    var request: PromptRequest
    var onFinish: (AskpassReply, Bool) -> Void

    @State private var answer = ""
    @State private var remember = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(iconColor.gradient)
                    .frame(width: 44, height: 44)
                    .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(request.tunnelName).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            switch request.kind {
            case .hostKey(let detail):
                hostKeyBody(detail)
            case .confirm:
                Text(request.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            default:
                Text(request.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("", text: $answer, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focused)
                    .onSubmit(submit)
                if request.rememberAccount != nil {
                    Toggle(L10n.text("Remember in my Keychain", "记入钥匙串"), isOn: $remember)
                        .toggleStyle(.checkbox)
                }
            }

            HStack {
                Spacer()
                Button(L10n.text("Cancel", "取消"), role: .cancel) { onFinish(.cancelled, false) }
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .padding(.top, 8)
        .frame(width: 440)
        .onAppear { focused = true }
    }

    func submit() {
        switch request.kind {
        case .hostKey, .confirm:
            onFinish(AskpassReply(ok: true, answer: "yes"), false)
        default:
            onFinish(AskpassReply(ok: true, answer: answer), remember)
        }
    }

    @ViewBuilder
    func hostKeyBody(_ detail: PromptRequest.HostKeyDetail) -> some View {
        Text(L10n.text("Compare this fingerprint with the one provided by the server administrator before trusting the host.",
                       "请先核对主机指纹与服务器管理员提供的值，再选择信任。"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(L10n.text("Server", "服务器"), value: detail.host)
            if !detail.keyType.isEmpty { LabeledContent(L10n.text("Key type", "密钥类型"), value: detail.keyType) }
            LabeledContent(L10n.text("Fingerprint", "指纹")) {
                Text(detail.fingerprint.isEmpty ? "—" : detail.fingerprint)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        if detail.fingerprint.isEmpty {
            Text(request.message).font(.caption.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var title: String {
        switch request.kind {
        case .password: return L10n.text("Enter password", "输入密码")
        case .passphrase: return L10n.text("Unlock private key", "解锁私钥")
        case .proxyPassword: return L10n.text("Proxy password", "代理密码")
        case .secret: return L10n.text("The server is asking for more information", "服务器请求进一步验证")
        case .hostKey: return L10n.text("Trust this server?", "信任这台服务器？")
        case .confirm: return L10n.text("Confirm", "确认")
        }
    }

    var placeholder: String {
        switch request.kind {
        case .passphrase: return L10n.text("Passphrase", "私钥口令")
        case .secret: return L10n.text("Response", "验证码或回答")
        default: return L10n.text("Password", "密码")
        }
    }

    var primaryTitle: String {
        switch request.kind {
        case .hostKey: return L10n.text("Trust and Connect", "信任并连接")
        case .confirm: return L10n.text("Yes", "继续")
        default: return L10n.text("Connect", "连接")
        }
    }

    var icon: String {
        switch request.kind {
        case .hostKey: return "checkmark.shield.fill"
        case .passphrase: return "key.fill"
        case .confirm: return "questionmark.circle.fill"
        default: return "lock.fill"
        }
    }

    var iconColor: Color {
        switch request.kind {
        case .hostKey: return .orange
        default: return .blue
        }
    }
}
