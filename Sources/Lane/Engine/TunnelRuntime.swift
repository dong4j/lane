import AppKit
import Foundation
import Observation
import LaneCore

/// Live state of one tunnel: owns the ssh process, parses its output and handles reconnects.
@MainActor
@Observable
final class TunnelRuntime {
    enum FailureKind { case portInUse, authentication }

    let tunnelID: UUID
    let agentRouteKey: AgentPreparedRoute.Key?
    var heldByUser = false
    var leasedByAgent = false

    private(set) var state: TunnelState = .off
    private(set) var lastError: String?
    private(set) var failureKind: FailureKind?
    private(set) var forwardStatus: [UUID: ForwardStatus] = [:]
    private(set) var logs: [LogEntry] = []

    /// Whether the user wants this tunnel on.
    private(set) var desiredOn = false

    @ObservationIgnored weak var manager: TunnelManager?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var tunnel: Tunnel?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var stabilityTask: Task<Void, Never>?
    @ObservationIgnored private var forwardingTask: Task<Void, Never>?
    @ObservationIgnored private var controlSocket: SSHControlSocket?
    @ObservationIgnored private var killTask: Task<Void, Never>?
    @ObservationIgnored private var stderrBuffer = Data()
    @ObservationIgnored private var fatalMessage: String?
    @ObservationIgnored private var forwardFailedThisRun = false
    @ObservationIgnored private var networkProblemThisRun = false
    @ObservationIgnored private var configProblem: String?
    @ObservationIgnored private var restartRequested = false
    @ObservationIgnored private var usedSavedPasswords: Set<String> = []
    @ObservationIgnored private var usedSavedPassphrases: Set<String> = []
    @ObservationIgnored private var nextLogID: UInt64 = 0
    @ObservationIgnored private var wasConnectedThisRun = false
    /// Bumped by every launch and stop, so a slow pre-flight check can tell it is out of date.
    @ObservationIgnored private var launchGeneration = 0

    static let maxLogEntries = 2_000

    init(tunnelID: UUID, agentRouteKey: AgentPreparedRoute.Key? = nil) {
        self.tunnelID = tunnelID
        self.agentRouteKey = agentRouteKey
    }

    var pid: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }
    var currentConfiguration: Tunnel? { tunnel }
    var isAgentOwned: Bool { agentRouteKey != nil }

    // MARK: Public control

    func start(_ tunnel: Tunnel) {
        retryTask?.cancel()
        desiredOn = true
        attempt = 0
        lastError = nil
        if process != nil {
            // The previous ssh is still shutting down (Disconnect, then Connect right away):
            // start again as soon as it has exited instead of running two at once.
            self.tunnel = tunnel
            if state == .disconnecting {
                restartRequested = true
                state = .connecting
            }
            return
        }
        launch(tunnel)
    }

    func stop() {
        desiredOn = false
        launchGeneration += 1
        retryTask?.cancel()
        retryTask = nil
        forwardingTask?.cancel()
        manager?.prompts.cancel(tunnelID: tunnelID)
        if let process {
            state = .disconnecting
            log(.info, String(localized: "Disconnecting…"))
            if process.isRunning { terminate(process) }
        } else {
            state = .off
            clearForwardStatus()
            if isAgentOwned { manager?.removeStoppedAgentRuntime(tunnelID) }
        }
    }

    /// Restart immediately (settings changed, wake from sleep).
    func restart(with tunnel: Tunnel, reason: String) {
        guard desiredOn else { return }
        self.tunnel = tunnel
        log(.info, reason)
        retryTask?.cancel()
        if let process {
            restartRequested = true
            forwardingTask?.cancel()
            state = .connecting
            if process.isRunning { terminate(process) }
        } else {
            attempt = 0
            launch(tunnel)
        }
    }

    func retryNow() {
        guard desiredOn, case .reconnecting = state,
              let tunnel, tunnel.autoReconnect else { return }
        retryTask?.cancel()
        launch(tunnel)
    }

    /// Metadata can change live. Turning off retry also ends a pending backoff.
    func updateConfiguration(_ tunnel: Tunnel) {
        self.tunnel = tunnel
        if !tunnel.autoReconnect, case .reconnecting = state { stop() }
    }

    /// Synchronous best-effort shutdown used when the app quits.
    func terminateForQuit() {
        desiredOn = false
        retryTask?.cancel()
        forwardingTask?.cancel()
        manager?.prompts.cancel(tunnelID: tunnelID)
        if let process, process.isRunning {
            process.terminate()
        }
    }

    func forceStopForQuit() {
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        controlSocket?.remove()
    }

    // MARK: Launch

    private func launch(_ tunnel: Tunnel) {
        guard manager != nil else { return }
        launchGeneration += 1
        let generation = launchGeneration
        self.tunnel = tunnel
        fatalMessage = nil
        failureKind = nil
        configProblem = nil
        networkProblemThisRun = false
        forwardFailedThisRun = false
        usedSavedPasswords = []
        usedSavedPassphrases = []
        wasConnectedThisRun = false

        let errors = TunnelValidator.validate(tunnel).filter { $0.severity == .error }
        if let first = errors.first {
            fail(first.message)
            return
        }

        forwardStatus = Dictionary(uniqueKeysWithValues: tunnel.forwardings.map {
            ($0.id, $0.enabled ? ForwardStatus.pending : .idle)
        })
        state = .connecting
        let host = tunnel.hostNotation
        log(.info, attempt > 0 ? String(localized: "Reconnecting to \(host) (attempt \(attempt))…") : String(localized: "Connecting to \(host)…"))

        // Pre-flight: make sure local listening ports are free so the user gets a clear message.
        // lsof can take a moment, so it runs off the main thread.
        let checks = tunnel.enabledForwardings.filter(\.kind.listensLocally).map { (id: $0.id, port: $0.port, bind: $0.bindAddress) }
        let ipv6ByDefault = SSHCommandBuilder.prefersIPv6(for: tunnel)
        Task { [weak self] in
            guard let self else { return }
            await manager?.waitForStoppingRoutes(profileID: agentRouteKey?.profileID ?? tunnelID, except: tunnelID)
            guard generation == launchGeneration, desiredOn else { return }
            let conflict = await Task.detached(priority: .userInitiated) { () -> (id: UUID, message: String)? in
                for check in checks {
                    if let message = PortInspector.conflict(port: check.port, bindAddress: check.bind,
                                                            ipv6ByDefault: ipv6ByDefault) {
                        return (check.id, message)
                    }
                }
                return nil
            }.value
            guard generation == launchGeneration, desiredOn else { return }
            if let conflict {
                self.failureKind = .portInUse
                self.forwardStatus[conflict.id] = .failed(conflict.message)
                self.fail(conflict.message)
                return
            }
            self.spawn(tunnel)
        }
    }

    private func spawn(_ tunnel: Tunnel) {
        guard let manager else { return }
        let socket: SSHControlSocket
        do {
            socket = try SSHControlSocket()
        } catch {
            fail(L10n.text("Could not prepare SSH forwarding.", "无法准备 SSH 转发。"))
            return
        }
        controlSocket = socket
        let sshPath = manager.sshPath
        var builder = manager.commandBuilder
        builder.context.controlPath = socket.url.path
        let arguments = builder.arguments(for: tunnel)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: sshPath)
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = Bundle.main.executablePath
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        env[AskpassEnvironment.socketPath] = manager.askpass.socketPath
        env[AskpassEnvironment.token] = manager.askpass.token
        env[AskpassEnvironment.tunnelID] = tunnelID.uuidString
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe
        stderrBuffer = Data()

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                if self?.process === p { self?.consume(data) }
            }
        }
        p.terminationHandler = { [weak self, weak manager] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            let pid = proc.processIdentifier
            Task { @MainActor [weak self] in
                // Even if this tunnel was deleted meanwhile, its PID must leave the registry.
                manager?.processEnded(pid)
                errPipe.fileHandleForReading.readabilityHandler = nil
                guard let self, self.process === proc else { return }
                let rest = errPipe.fileHandleForReading.readDataToEndOfFile()
                self.consume(rest)
                self.flushStderr()
                self.processExited(proc, status: status, reason: reason)
            }
        }

        log(.debug, "$ " + builder.displayCommand(for: tunnel))

        do {
            try p.run()
            process = p
            manager.processStarted(p.processIdentifier)
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            socket.remove()
            controlSocket = nil
            fail(String(localized: "Could not start ssh: \(error.localizedDescription)"))
        }
    }

    // MARK: Output

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrBuffer.append(data)
        while let nl = stderrBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = stderrBuffer[stderrBuffer.startIndex..<nl]
            stderrBuffer.removeSubrange(stderrBuffer.startIndex...nl)
            handleLine(String(decoding: lineData, as: UTF8.self))
        }
    }

    private func flushStderr() {
        if !stderrBuffer.isEmpty {
            handleLine(String(decoding: stderrBuffer, as: UTF8.self))
            stderrBuffer = Data()
        }
    }

    private func handleLine(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\r")))
        guard !line.isEmpty else { return }
        let parsed = SSHLogParser.parse(line)
        log(parsed.level, parsed.message)
        if let event = parsed.event { handle(event) }
    }

    private func handle(_ event: SSHEvent) {
        guard let tunnel else { return }
        switch event {
        case .sessionReady:
            applyRules(tunnel)
        case .localForwardListening, .remoteForwardSuccess, .authenticated, .serverHostKey:
            break
        case .forwardFailed(let port, let remote, let message):
            forwardFailedThisRun = true
            lastError = message
            for f in tunnel.enabledForwardings where (port == nil || f.port == port) && (f.kind == .remote) == remote {
                if forwardStatus[f.id] != .active || port != nil { forwardStatus[f.id] = .failed(message) }
            }
        case .authFailed:
            failureKind = .authentication
            fatalMessage = L10n.text("SSH authentication was rejected. Check the key or credentials.",
                                     "SSH 认证被拒绝，请检查密钥或登录凭据。")
            lastError = fatalMessage
        case .hostKeyProblem(let detail):
            if detail.localizedCaseInsensitiveContains("identification has changed") {
                fatalMessage = L10n.text("The SSH host key changed. Verify the new fingerprint before reconnecting.",
                                         "SSH 主机指纹已变化，请核实新指纹后再连接。")
            } else if fatalMessage == nil {
                fatalMessage = L10n.text("The SSH host key could not be verified.", "无法验证 SSH 主机指纹。")
            }
            lastError = fatalMessage
        case .configError:
            // Some of these are only warnings (e.g. an option this ssh doesn't support) and ssh
            // carries on; it only matters if ssh then gives up before reaching the network.
            configProblem = SSHLogParser.friendlyMessage(for: event)
        case .connectionFailed, .disconnected:
            networkProblemThisRun = true
            lastError = SSHLogParser.friendlyMessage(for: event)
        case .connecting, .connectionEstablished:
            break
        }
    }

    /// A jump host may log its own session start. Only our private master can acknowledge rules.
    private func applyRules(_ tunnel: Tunnel) {
        // Keep the control client paired with the master even if the global SSH preference changed.
        guard desiredOn, !restartRequested, forwardingTask == nil, let socket = controlSocket, socket.exists,
              let ssh = process?.executableURL?.path, let pid else { return }
        let rules = tunnel.enabledForwardings
        let ipv6ByDefault = SSHCommandBuilder.prefersIPv6(for: tunnel)
        forwardingTask = Task.detached(priority: .userInitiated) { [weak self] in
            let failure = socket.apply(rules, ssh: ssh)
            let conflict = failure.flatMap { result in
                result.rule.kind.listensLocally ? PortInspector.conflict(port: result.rule.port, bindAddress: result.rule.bindAddress,
                                                                         ipv6ByDefault: ipv6ByDefault) : nil
            }
            guard !Task.isCancelled else { return }
            await self?.finishedApplying(rules, failure: failure, conflict: conflict, pid: pid)
        }
    }

    private func finishedApplying(_ rules: [Forwarding], failure: SSHControlSocket.Failure?, conflict: String?, pid: Int32) {
        guard self.pid == pid, desiredOn, let process else { return }
        if let failure {
            let rule = failure.rule
            if conflict != nil { failureKind = .portInUse }
            let message = rule.kind == .remote
                ? L10n.text("The SSH server refused port \(rule.port).", "SSH 服务器未接受端口 \(rule.port) 的转发。")
                : conflict ?? L10n.text("Unable to listen on local port \(rule.port).", "无法监听本机端口 \(rule.port)。")
            forwardFailedThisRun = true
            lastError = message
            forwardStatus[rule.id] = .failed(message)
            if !failure.detail.isEmpty { log(.error, failure.detail) }
            terminate(process)
        } else {
            for rule in rules { forwardStatus[rule.id] = .active }
            markConnected()
        }
    }

    private func markConnected() {
        guard desiredOn, state != .connected, process?.isRunning == true else { return }
        state = .connected
        wasConnectedThisRun = true
        lastError = nil
        log(.success, String(localized: "Tunnel is up."))
        manager?.notifyConnected(tunnelID)

        // Reset the backoff once the connection has been stable for a while.
        stabilityTask?.cancel()
        stabilityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.state == .connected else { return }
            self.attempt = 0
        }
    }

    // MARK: Exit / reconnect

    private func processExited(_ p: Process, status: Int32, reason: Process.TerminationReason) {
        guard p === process else { return }
        process = nil
        killTask?.cancel()
        stabilityTask?.cancel()
        forwardingTask?.cancel()
        forwardingTask = nil
        controlSocket?.remove()
        controlSocket = nil
        manager?.prompts.cancel(tunnelID: tunnelID)
        let wasConnected = wasConnectedThisRun

        if restartRequested, desiredOn, let tunnel {
            restartRequested = false
            attempt = 0
            launch(tunnel)
            return
        }
        restartRequested = false

        guard desiredOn else {
            state = .off
            clearForwardStatus()
            log(.info, String(localized: "Disconnected."))
            if isAgentOwned { manager?.removeStoppedAgentRuntime(tunnelID) }
            return
        }

        let code = Int(status)
        if fatalMessage == nil, !wasConnected, !networkProblemThisRun, let configProblem {
            fatalMessage = configProblem
        }
        let message = fatalMessage ?? lastError ?? String(localized: "ssh exited unexpectedly (status \(code)).")
        if fatalMessage != nil {
            fail(message)
            return
        }

        let allowRetry = (tunnel?.autoReconnect ?? true) && !forwardFailedThisRun
        if allowRetry {
            // Report the transition from connected to retrying once, even when several retries fail.
            if wasConnected { manager?.notifyFailure(tunnelID, message: message, interrupted: true) }
            attempt += 1
            let delay = ReconnectPolicy.delay(forAttempt: attempt)
            let at = Date().addingTimeInterval(delay)
            state = .reconnecting(attempt: attempt, at: at)
            for (id, s) in forwardStatus where s == .active { forwardStatus[id] = .pending }
            let sentence = SSHLogParser.sentence(message)
            let seconds = Int(delay)
            log(.warning, String(localized: "Connection lost: \(sentence) Retrying in \(seconds) s."))
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.desiredOn else { return }
                if let latest = self.tunnel {
                    self.launch(latest)
                }
            }
        } else {
            fail(message)
        }
    }

    private func fail(_ message: String) {
        desiredOn = false
        state = .failed(message)
        lastError = message
        for (id, s) in forwardStatus where s == .pending || s == .active { forwardStatus[id] = .idle }
        log(.error, message)
        manager?.notifyFailure(tunnelID, message: message, interrupted: wasConnectedThisRun)
    }

    private func terminate(_ process: Process) {
        process.terminate()
        killTask?.cancel()
        let pid = process.processIdentifier
        killTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, process.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }

    private func clearForwardStatus() {
        for key in forwardStatus.keys { forwardStatus[key] = .idle }
    }

    func log(_ level: LogLevel, _ message: String) {
        nextLogID += 1
        logs.append(LogEntry(id: nextLogID, level: level, message: message))
        if logs.count > Self.maxLogEntries { logs.removeFirst(logs.count - Self.maxLogEntries) }
    }

    // MARK: Prompts

    func answer(_ request: AskpassRequest) async -> AskpassReply {
        guard let manager, let tunnel = tunnel ?? manager.store.tunnel(tunnelID) else { return .cancelled }
        guard desiredOn else { return .cancelled }
        let credentials = agentRouteKey?.profileID ?? tunnelID

        if request.kind == .proxyPassword {
            if let saved = Keychain.get(Keychain.proxyPassword(credentials)) { return AskpassReply(ok: true, answer: saved) }
            let response = await present(.init(tunnelID: tunnelID, tunnelName: tunnel.displayName, kind: .proxyPassword,
                                               message: String(localized: "Password for proxy user “\(tunnel.proxy.username)” at \(tunnel.proxy.host)"),
                                               rememberAccount: Keychain.proxyPassword(credentials)))
            return response
        }

        let kind = PromptClassifier.classify(request.prompt)
        switch kind {
        case .password:
            // OpenSSH may be asking for a configured jump host. Key by the prompt account, not the alias.
            let account = PromptClassifier.passwordAccount(in: request.prompt).map {
                Keychain.tunnelPassword(credentials, account: "\($0.user)@\($0.host)")
            }
            if let account, !usedSavedPasswords.contains(account), let saved = Keychain.get(account) {
                usedSavedPasswords.insert(account)
                log(.info, String(localized: "Using the password saved in your Keychain."))
                return AskpassReply(ok: true, answer: saved)
            }
            return await present(.init(tunnelID: tunnelID, tunnelName: tunnel.displayName, kind: .password,
                                       message: request.prompt, rememberAccount: account))
        case .passphrase(let keyPath):
            let path = PromptClassifier.resolveKeyPath(fromPrompt: keyPath, identityFile: tunnel.identityFile)
            let account = Keychain.keyPassphrase(path)
            if !usedSavedPassphrases.contains(account), let saved = Keychain.get(account) {
                usedSavedPassphrases.insert(account)
                log(.info, String(localized: "Using the key passphrase saved in your Keychain."))
                return AskpassReply(ok: true, answer: saved)
            }
            return await present(.init(tunnelID: tunnelID, tunnelName: tunnel.displayName, kind: .passphrase,
                                       message: String(localized: "Passphrase for key \((path as NSString).abbreviatingWithTildeInPath)"), rememberAccount: account))
        case .hostKey(let host, let keyType, let fingerprint):
            let detail = PromptRequest.HostKeyDetail(host: host ?? tunnel.hostNotation, keyType: keyType ?? "", fingerprint: fingerprint ?? "")
            return await present(.init(tunnelID: tunnelID, tunnelName: tunnel.displayName, kind: .hostKey(detail),
                                       message: request.prompt, rememberAccount: nil))
        case .confirmation:
            return await present(.init(tunnelID: tunnelID, tunnelName: tunnel.displayName, kind: .confirm,
                                       message: request.prompt, rememberAccount: nil))
        case .proxyPassword, .other:
            return await present(.init(tunnelID: tunnelID, tunnelName: tunnel.displayName, kind: .secret,
                                       message: request.prompt.trimmingCharacters(in: .whitespacesAndNewlines), rememberAccount: nil))
        }
    }

    private func present(_ request: PromptRequest) async -> AskpassReply {
        guard let manager else { return .cancelled }
        let previous = state
        state = .waitingForUser
        let reply = await manager.prompts.ask(request)
        if state == .waitingForUser { state = previous == .waitingForUser ? .connecting : previous }
        if !reply.ok, desiredOn {
            log(.warning, String(localized: "Prompt cancelled."))
            stop()
        }
        return reply
    }

    // MARK: Demo support (snapshots)

    func applyDemo(state: TunnelState, forwardStatus: [UUID: ForwardStatus] = [:],
                   logs: [(LogLevel, String)] = [], lastError: String? = nil, failureKind: FailureKind? = nil) {
        self.state = state
        self.forwardStatus = forwardStatus
        self.lastError = lastError
        self.failureKind = failureKind
        self.desiredOn = state.isActive
        for (level, message) in logs { log(level, message) }
    }
}
