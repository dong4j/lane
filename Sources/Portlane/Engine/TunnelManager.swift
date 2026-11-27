import AppKit
import Observation
import PortlaneCore

/// Shared owner of managed SSH sessions. Discovery never gets a process control handle.
@MainActor
@Observable
final class TunnelManager {
    let store: TunnelStore
    let prompts = PromptPresenter()
    let sshPath = "/usr/bin/ssh"
    private let demo: Bool
    private(set) var runtimes: [UUID: TunnelRuntime] = [:]
    private(set) var runningPIDs: Set<Int32> = []
    @ObservationIgnored private let network = NetworkWatcher()
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored lazy var askpass = AskpassServer { [weak self] request in
        guard let self else { return .cancelled }
        return await self.answer(request)
    }

    init(store: TunnelStore, demo: Bool = false) {
        self.store = store
        self.demo = demo
    }

    func startServices() {
        guard !demo, wakeObserver == nil else { return }
        do {
            try askpass.start()
        } catch {
            NSLog("Portlane: %@", error.localizedDescription)
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

    var connectedCount: Int { runtimes.values.filter { $0.state == .connected }.count }

    func connect(_ id: UUID) {
        guard let tunnel = store.tunnel(id) else { return }
        let runtime = runtime(id)
        if demo {
            let ready = Dictionary(uniqueKeysWithValues: tunnel.enabledForwardings.map { ($0.id, ForwardStatus.active) })
            runtime.applyDemo(state: .connected, forwardStatus: ready)
        } else {
            startServices()
            runtime.start(tunnel)
        }
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
        for runtime in runtimes.values where runtime.desiredOn {
            guard let tunnel = store.tunnel(runtime.tunnelID), tunnel.autoReconnect else { continue }
            if runtime.state == .connected {
                runtime.restart(with: tunnel, reason: "Mac woke from sleep. Refreshing SSH.")
            } else {
                runtime.retryNow()
            }
        }
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
