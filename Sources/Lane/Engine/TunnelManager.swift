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
    var commandBuilder: SSHCommandBuilder {
        SSHCommandBuilder(context: .init(sshPath: sshPath, helperExecutable: Bundle.main.executablePath))
    }
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

    func displayRuntime(_ id: UUID) -> TunnelRuntime? {
        let direct = runtimes[id]
        if let direct, direct.state.isActive { return direct }
        guard let profile = store.tunnel(id) else { return direct }
        let shared = matchingAgentRoutes(profile).values
        if let direct, direct.state.isFailure, shared.contains(where: \.heldByUser) { return direct }
        let heldFailure = agentRuntimes(id).first { $0.heldByUser && $0.state.isFailure }
        return shared.first(where: { $0.state.isConnected }) ?? shared.first ?? heldFailure ?? direct
    }

    func state(_ id: UUID) -> TunnelState { displayRuntime(id)?.state ?? .off }

    func keepsConnected(_ id: UUID) -> Bool {
        runtimes[id]?.desiredOn == true || agentRuntimes(id).contains { $0.heldByUser && $0.desiredOn }
    }

    func agentRuleCount(_ tunnel: Tunnel) -> Int { matchingAgentRoutes(tunnel).count }

    func connectionLabel(_ tunnel: Tunnel, state: TunnelState) -> String {
        let shared = matchingAgentRoutes(tunnel).values.filter { $0.state.isConnected }.count
        guard shared > 0, state.isConnected, !keepsConnected(tunnel.id) else { return state.displayLabel }
        if shared == tunnel.enabledForwardings.count { return L10n.text("In use by Agent", "Agent 使用中") }
        return L10n.text("Agent · \(shared)/\(tunnel.enabledForwardings.count) rules",
                         "Agent 使用中 · \(shared)/\(tunnel.enabledForwardings.count) 条")
    }

    func ruleStatus(_ rule: Forwarding, in tunnel: Tunnel) -> ForwardStatus {
        if let shared = matchingAgentRuntime(rule, in: tunnel, includeFailures: true),
           let actual = shared.currentConfiguration?.forwardings.first {
            if case .failed(let message) = shared.state { return .failed(message) }
            return shared.state.isConnected ? shared.forwardStatus[actual.id] ?? .idle : .pending
        }
        guard let direct = runtimes[tunnel.id] else { return .idle }
        let status = direct.forwardStatus[rule.id] ?? .idle
        return !direct.state.isConnected && status == .active ? .pending : status
    }

    func ruleAddress(_ rule: Forwarding, in tunnel: Tunnel) -> String {
        matchingAgentRuntime(rule, in: tunnel)?.currentConfiguration?.forwardings.first?.clientAddress ?? rule.clientAddress
    }

    var connectedCount: Int { store.tunnels.filter { state($0.id).isConnected }.count }

    var hasConnectedSession: Bool { runtimes.values.contains { $0.state == .connected } }

    func connect(_ id: UUID) {
        guard let tunnel = store.tunnel(id) else { return }
        applyManualConnection(tunnel)
    }

    /// Only start sibling rules that do not already have an isolated runtime for the same route.
    private func applyManualConnection(_ tunnel: Tunnel) {
        let shared = matchingAgentRoutes(tunnel)
        let keptIDs = Set(shared.values.map(\.tunnelID))
        for runtime in agentRuntimes(tunnel.id) where runtime.heldByUser && !keptIDs.contains(runtime.tunnelID) {
            releaseManualHold(runtime)
        }
        for runtime in shared.values { runtime.heldByUser = true }
        var remaining = tunnel
        remaining.forwardings.removeAll { shared[$0.id] != nil }
        if !shared.isEmpty, remaining.enabledForwardings.isEmpty {
            if let direct = runtimes[tunnel.id] { stop(direct) }
            return
        }
        let direct = runtime(tunnel.id)
        if direct.desiredOn, let previous = direct.currentConfiguration {
            if !requiresRestart(for: remaining, replacing: previous) {
                direct.updateConfiguration(remaining)
                return
            }
            if !demo {
                direct.restart(with: remaining, reason: "SSH configuration changed. Reconnecting.")
                return
            }
        }
        start(direct, with: remaining)
    }

    private func start(_ runtime: TunnelRuntime, with tunnel: Tunnel) {
        if demo {
            runtime.updateConfiguration(tunnel)
            runtime.applyDemo(state: .connected, forwardStatus: Dictionary(uniqueKeysWithValues:
                tunnel.enabledForwardings.map { ($0.id, ForwardStatus.active) }))
        } else {
            startServices()
            runtime.start(tunnel)
        }
    }

    private func agentRuntimes(_ profileID: UUID) -> [TunnelRuntime] {
        runtimes.values.filter { $0.agentRouteKey?.profileID == profileID }
    }

    private func matchingAgentRoutes(_ tunnel: Tunnel) -> [UUID: TunnelRuntime] {
        Dictionary(uniqueKeysWithValues: tunnel.enabledForwardings.compactMap { rule in
            matchingAgentRuntime(rule, in: tunnel).map { (rule.id, $0) }
        })
    }

    private func matchingAgentRuntime(_ rule: Forwarding, in tunnel: Tunnel, includeFailures: Bool = false) -> TunnelRuntime? {
        let candidates = agentRuntimes(tunnel.id)
        guard !candidates.isEmpty, let route = AgentPreparedRoute(profile: tunnel, forwarding: rule) else { return nil }
        return candidates.first {
            $0.agentRouteKey == route.key && ($0.desiredOn || (includeFailures && $0.heldByUser && $0.state.isFailure))
        }
    }

    func reusableRoute(_ route: AgentPreparedRoute) -> (TunnelRuntime, UUID)? {
        if let shared = agentRuntimes(route.key.profileID).first(where: { $0.desiredOn && $0.agentRouteKey == route.key }),
           let rule = shared.currentConfiguration?.forwardings.first {
            return (shared, rule.id)
        }
        guard let direct = runtimes[route.key.profileID], direct.desiredOn, let current = direct.currentConfiguration,
              let match = current.enabledForwardings.first(where: { rule in
                  AgentPreparedRoute(profile: current, forwarding: rule)?.key == route.key
              }) else { return nil }
        return (direct, match.id)
    }

    /// An Agent runtime is keyed separately so it can never pick up the saved profile's sibling rules.
    func connectAgentRoute(_ route: AgentPreparedRoute) -> TunnelRuntime {
        var tunnel = route.tunnel
        tunnel.id = UUID()
        let runtime = TunnelRuntime(tunnelID: tunnel.id, agentRouteKey: route.key)
        runtime.manager = self
        runtime.leasedByAgent = true
        runtimes[tunnel.id] = runtime
        start(runtime, with: tunnel)
        return runtime
    }

    func releaseAgentRoute(_ runtime: TunnelRuntime) {
        guard runtime.isAgentOwned else { return }
        runtime.leasedByAgent = false
        if !runtime.heldByUser { stop(runtime) }
    }

    private func releaseManualHold(_ runtime: TunnelRuntime) {
        runtime.heldByUser = false
        if !runtime.leasedByAgent { stop(runtime) }
    }

    func removeStoppedAgentRuntime(_ id: UUID) {
        if runtimes[id]?.isAgentOwned == true { runtimes.removeValue(forKey: id) }
    }

    func disconnect(_ id: UUID) {
        if let direct = runtimes[id] { stop(direct) }
        for runtime in agentRuntimes(id) where runtime.heldByUser {
            runtime.heldByUser = false
            stop(runtime)
        }
    }

    private func stop(_ runtime: TunnelRuntime) {
        if demo {
            runtime.applyDemo(state: .off)
            removeStoppedAgentRuntime(runtime.tunnelID)
        } else {
            runtime.stop()
        }
    }

    func toggle(_ id: UUID) {
        if keepsConnected(id) { disconnect(id) } else { connect(id) }
    }

    /// Compare the effective arguments so changing a label or a note cannot drop a live SSH session.
    func requiresRestart(for tunnel: Tunnel, replacing previous: Tunnel) -> Bool {
        SSHCommandBuilder.connectionArguments(for: tunnel) != SSHCommandBuilder.connectionArguments(for: previous)
    }

    func tunnelDidChange(_ tunnel: Tunnel, previous: Tunnel?) {
        guard previous != nil, keepsConnected(tunnel.id) else { return }
        applyManualConnection(tunnel)
    }

    /// A replaced route can still own its listener until OpenSSH exits.
    func waitForStoppingRoutes(profileID: UUID, except id: UUID) async {
        while runtimes.values.contains(where: { runtime in
            runtime.tunnelID != id && (runtime.tunnelID == profileID || runtime.agentRouteKey?.profileID == profileID)
                && runtime.state == .disconnecting && runtime.pid != nil
        }) {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
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
