import AppKit
import Observation
import LaneCore

/// Shared owner of managed SSH sessions. Discovery never gets a process control handle.
@MainActor
@Observable
final class TunnelManager {
    let store: TunnelStore
    let prompts = PromptPresenter()
    private let preferences: LanePreferences
    var sshPath: String { preferences.sshPath }
    let demo: Bool
    private(set) var runtimes: [UUID: TunnelRuntime] = [:]
    private(set) var runningPIDs: Set<Int32> = []
    @ObservationIgnored private let network = NetworkWatcher()
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored lazy var askpass = AskpassServer { [weak self] request in
        guard let self else { return .cancelled }
        return await self.answer(request)
    }

    init(store: TunnelStore, demo: Bool = false, preferences: LanePreferences = LanePreferences()) {
        self.store = store
        self.demo = demo
        self.preferences = preferences
    }

    /// Only tunnels explicitly marked for launch are connected when the app starts.
    func connectOnLaunch() {
        guard !demo else { return }
        for tunnel in store.tunnels where tunnel.autoConnect {
            connect(tunnel.id)
        }
    }

    func startServices() {
        guard !demo, wakeObserver == nil else { return }
        do {
            try askpass.start()
        } catch {
            NSLog("Lane: %@", error.localizedDescription)
        }
        network.onBecameReachable = { [weak self] in self?.retryWaitingSessions() }
        network.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.resumeAfterWake() }
        }
    }

    func runtime(_ id: UUID) -> TunnelRuntime {
        if let current = runtimes[id] { return current }
        let runtime = TunnelRuntime(tunnelID: id)
        runtime.manager = self
        runtimes[id] = runtime
        return runtime
    }

    func state(_ id: UUID) -> TunnelState { runtimes[id]?.state ?? .off }

    var connectedCount: Int { runtimes.values.filter { !$0.isAgentOwned && $0.state == .connected }.count }

    var hasConnectedSession: Bool { runtimes.values.contains { $0.state == .connected } }

    func connect(_ id: UUID) {
        guard let tunnel = store.tunnel(id) else { return }
        let runtime = runtime(id)
        if demo {
            runtime.updateConfiguration(tunnel)
            let ready = Dictionary(uniqueKeysWithValues: tunnel.enabledForwardings.map { ($0.id, ForwardStatus.active) })
            runtime.applyDemo(state: .connected, forwardStatus: ready)
        } else {
            startServices()
            runtime.start(tunnel)
        }
    }

    /// An Agent runtime is keyed separately so it can never pick up the saved profile's sibling rules.
    func connectAgentRoute(_ route: AgentPreparedRoute) -> TunnelRuntime {
        var tunnel = route.tunnel
        tunnel.id = UUID()
        let runtime = TunnelRuntime(tunnelID: tunnel.id, credentialTunnelID: route.key.profileID)
        runtime.manager = self
        runtimes[tunnel.id] = runtime
        if demo {
            runtime.updateConfiguration(tunnel)
            runtime.applyDemo(state: .connected, forwardStatus: [route.rule.id: .active])
        } else {
            startServices()
            runtime.start(tunnel)
        }
        return runtime
    }

    func removeStoppedAgentRuntime(_ id: UUID) {
        if runtimes[id]?.isAgentOwned == true { runtimes.removeValue(forKey: id) }
    }

    func disconnect(_ id: UUID) {
        if demo {
            runtimes[id]?.applyDemo(state: .off)
        } else {
            runtimes[id]?.stop()
        }
    }

    func toggle(_ id: UUID) {
        if runtimes[id]?.desiredOn == true { disconnect(id) } else { connect(id) }
    }

    /// Compare the effective arguments so changing a label or a note cannot drop a live SSH session.
    func requiresRestart(for tunnel: Tunnel, replacing previous: Tunnel) -> Bool {
        let command = SSHCommandBuilder()
        return command.arguments(for: tunnel) != command.arguments(for: previous)
    }

    func tunnelDidChange(_ tunnel: Tunnel, previous: Tunnel?) {
        guard let active = runtimes[tunnel.id], let previous else { return }
        if active.desiredOn, requiresRestart(for: tunnel, replacing: previous) {
            if demo { connect(tunnel.id) } else {
                active.restart(with: tunnel, reason: "SSH configuration changed. Reconnecting.")
            }
        } else {
            active.updateConfiguration(tunnel)
        }
    }

    func processStarted(_ pid: Int32) { runningPIDs.insert(pid) }
    func processEnded(_ pid: Int32) { runningPIDs.remove(pid) }

    private func answer(_ request: AskpassRequest) async -> AskpassReply {
        guard let id = UUID(uuidString: request.tunnelID), let runtime = runtimes[id] else { return .cancelled }
        return await runtime.answer(request)
    }

    private func retryWaitingSessions() {
        for runtime in runtimes.values { runtime.retryNow() }
    }

    private func resumeAfterWake() {
        guard preferences.reconnectOnWake else { return }
        for runtime in runtimes.values where runtime.desiredOn {
            guard let tunnel = runtime.currentConfiguration, tunnel.autoReconnect else { continue }
            if runtime.state == .connected {
                runtime.restart(with: tunnel, reason: "Mac woke from sleep. Refreshing SSH.")
            } else {
                runtime.retryNow()
            }
        }
    }

    func notifyConnected(_ id: UUID) {
        guard !demo, preferences.notifyOnConnect, let tunnel = store.tunnel(id) else { return }
        TunnelNotifications.post(title: L10n.text("\(tunnel.displayName) connected", "\(tunnel.displayName) 已连接"))
    }

    func notifyFailure(_ id: UUID, message: String, interrupted: Bool) {
        guard !demo, preferences.notifyOnFailure, let tunnel = store.tunnel(id) else { return }
        let name = tunnel.displayName
        let title = interrupted ? L10n.text("\(name) disconnected unexpectedly", "\(name) 意外中断")
            : L10n.text("\(name) could not connect", "\(name) 连接失败")
        TunnelNotifications.post(title: title, body: message)
    }

    /// Use live `Process` owners exclusively. A PID saved on disk is insufficient proof of ownership.
    func shutdown() {
        guard !demo else { return }
        for runtime in runtimes.values { runtime.terminateForQuit() }
        let deadline = Date().addingTimeInterval(1)
        while runtimes.values.contains(where: { $0.pid != nil }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        for runtime in runtimes.values { runtime.forceStopForQuit() }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        network.stop()
        askpass.stop()
    }
}
