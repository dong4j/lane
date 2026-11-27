import Foundation
import Observation
import PortlaneCore

/// Serializes policy, audit writes, and ownership changes on the app's main actor.
@MainActor
@Observable
final class AgentAccess {
    private struct Connection {
        let runtime: TunnelRuntime
        let ruleID: UUID
    }

    private let manager: TunnelManager
    private let files: AgentFiles?
    @ObservationIgnored private var ipc: AgentIPC?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var nextDiscovery = Date.distantPast
    @ObservationIgnored private var isClosing = false
    @ObservationIgnored var approvalNeeded: (() -> Void)?
    private var connections: [AgentPreparedRoute.Key: Connection] = [:]
    private(set) var ledger = AgentLedger()
    private(set) var storageError = false
    private(set) var serviceError = false

    var available: Bool { files != nil && !storageError && !serviceError }
    var pending: [AgentLease] { ledger.leases.reversed().filter { $0.state == .pendingApproval } }
    var active: [AgentLease] { ledger.leases.reversed().filter { $0.state.isOpen && $0.state != .pendingApproval } }
    var history: [AgentLease] { ledger.leases.reversed().filter { !$0.state.isOpen } }

    init(manager: TunnelManager, files: AgentFiles?) {
        self.manager = manager
        self.files = files
        guard let files, FileManager.default.fileExists(atPath: files.ledger.path) else { return }
        do {
            ledger = try JSONDecoder().decode(AgentLedger.self, from: Data(contentsOf: files.ledger))
            if ledger.leases.contains(where: { $0.state.isOpen }) {
                var restored = ledger
                endLeases(in: &restored, reason: .appRestarted) { _ in true }
                try commit(restored)
            }
        } catch {
            storageError = true
        }
    }

    /// No TCP endpoint is opened. The stdio helper talks to this app instance over a private socket.
    func start() {
        guard let files, ipc == nil else { return }
        let server = AgentIPC(socketPath: files.socketPath)
        do {
            try server.start { [weak self] call in
                guard let self else { return AgentToolResult(error: .unavailable) }
                return await self.handle(call)
            }
            ipc = server
            serviceError = false
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    await self.tick()
                }
            }
        } catch {
            serviceError = true
        }
    }

    func shutdown() {
        isClosing = true
        monitor?.cancel()
        monitor = nil
        ipc?.stop()
        ipc = nil
        if ledger.leases.contains(where: { $0.state.isOpen }) {
            var next = ledger
            endLeases(in: &next, reason: .appQuit) { _ in true }
            try? commit(next)
        }
        collectUnusedConnections()
    }

    /// Pairings start read-only. The generated setup only points at the private credential file.
    func pair(_ input: String) throws -> AgentClient {
        guard let files else { throw AgentToolError.unavailable }
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 240 else { throw AgentToolError.invalidArguments }
        let token = try AgentFiles.makeToken()
        let client = AgentClient(id: UUID(), name: name, tokenDigest: agentDigest(Data(token.utf8)))
        let credential = AgentCredential(clientID: client.id, token: token, socketPath: files.socketPath)
        try files.writeCredential(credential)
        var next = ledger
        next.clients.append(client)
        do {
            try commit(next)
        } catch {
            try? FileManager.default.removeItem(at: files.credentialURL(client.id))
            throw error
        }
        return client
    }

    func configuration(for id: UUID, executable: String? = Bundle.main.executablePath) -> AgentMCPConfiguration? {
        guard let executable, let file = files?.credentialURL(id), ledger.clients.contains(where: { $0.id == id }) else {
            return nil
        }
        return AgentMCPConfiguration(executable: executable, credentialFile: file.path)
    }

    func setRequestsEnabled(_ enabled: Bool) throws {
        var next = ledger
        next.requestsEnabled = enabled
        if !enabled { endLeases(in: &next, reason: .accessDisabled) { _ in true } }
        try commit(next)
        collectUnusedConnections()
    }

    func setClientRequests(_ id: UUID, enabled: Bool) throws {
        guard let index = ledger.clients.firstIndex(where: { $0.id == id }) else { throw AgentToolError.notPaired }
        var next = ledger
        next.clients[index].canRequest = enabled
        if !enabled { endLeases(in: &next, reason: .accessDisabled) { $0.clientID == id } }
        try commit(next)
        collectUnusedConnections()
    }

    func revokeClient(_ id: UUID) throws {
        var next = ledger
        next.clients.removeAll { $0.id == id }
        endLeases(in: &next, reason: .clientRevoked) { $0.clientID == id }
        try commit(next)
        collectUnusedConnections()
        if let file = files?.credentialURL(id) { try? FileManager.default.removeItem(at: file) }
    }

    func canShare(_ rule: Forwarding, from profile: Tunnel) -> Bool {
        AgentPreparedRoute(profile: profile, forwarding: rule) != nil
    }

    func isShared(_ rule: Forwarding, from profile: Tunnel) -> Bool {
        guard let share = ledger.shares.first(where: { $0.profileID == profile.id && $0.forwardingID == rule.id }) else {
            return false
        }
        return preparedShared(share) != nil
    }

    /// Grants are scoped to the current effective route. Editing an address requires sharing it again.
    func setShared(_ rule: Forwarding, from profile: Tunnel, enabled: Bool) throws {
        guard let current = manager.store.tunnel(profile.id), let selected = current.forwardings.first(where: { $0.id == rule.id }),
              let route = AgentPreparedRoute(profile: current, forwarding: selected) else { throw AgentToolError.routeChanged }
        var next = ledger
        let replaced = next.shares.filter { $0.profileID == profile.id && $0.forwardingID == rule.id }
        next.shares.removeAll { $0.profileID == profile.id && $0.forwardingID == rule.id }
        if enabled {
            next.shares.append(AgentShare(id: UUID(), profileID: profile.id, forwardingID: rule.id, fingerprint: route.key.fingerprint))
        }
        endLeases(in: &next, reason: .routeChanged) { lease in
            guard case .shared(let id) = lease.input.target else { return false }
            return replaced.contains { $0.id == id }
        }
        try commit(next)
        collectUnusedConnections()
    }

    /// Revoke requests whose approved forwarding or SSH profile no longer matches the saved setup.
    func libraryChanged() {
        let invalid = ledger.leases.filter { lease in
            guard lease.state.isOpen, let key = lease.connectionKey else { return false }
            return prepared(lease.input.target)?.key != key
        }
        let validShares = ledger.shares.filter { preparedShared($0) != nil }
        guard !invalid.isEmpty || validShares.count != ledger.shares.count else { return }
        let ids = Set(invalid.map(\.id))
        var next = ledger
        next.shares = validShares
        endLeases(in: &next, reason: .routeChanged) { ids.contains($0.id) }
        try? commit(next)
        collectUnusedConnections()
    }

    /// Only the paired client that owns a lease can query or release it.
    func handle(_ call: AgentToolCall) async -> AgentToolResult {
        do {
            let client = try authenticate(call.credential)
            try reconcile()
            switch call.tool {
            case .list:
                let rules = ledger.shares.compactMap { share in
                    preparedShared(share).map { AgentToolResult.Rule(share: share, route: $0.route) }
                }
                return AgentToolResult(rules: rules, canRequest: ledger.requestsEnabled && client.canRequest)
            case .request:
                return AgentToolResult(lease: AgentToolResult.Lease(try await request(call.arguments, credential: call.credential)))
            case .status, .release:
                guard let id = call.arguments.leaseID else { throw AgentToolError.invalidArguments }
                guard var lease = lease(id), lease.clientID == client.id else { throw AgentToolError.notFound }
                if call.tool == .release, lease.state.isOpen {
                    lease.move(to: .released, action: .released, at: Date())
                    try save(lease)
                    collectUnusedConnections()
                } else if call.tool == .status, lease.state == .ready, lease.external != nil {
                    try await checkExternalLease(id, credential: call.credential)
                    if let updated = self.lease(id) { lease = updated }
                }
                return AgentToolResult(lease: AgentToolResult.Lease(lease))
            }
        } catch let error as AgentToolError {
            return AgentToolResult(error: error)
        } catch {
            return AgentToolResult(error: .storage)
        }
    }

    /// A native approval applies only to the exact route shown on the pending card.
    func approve(_ id: UUID) async throws {
        try reconcile()
        guard var lease = lease(id), lease.state == .pendingApproval else { return }
        if let evidence = lease.external {
            let matches = try await externalEvidence(at: evidence.route.listenAddress) == evidence
            try reconcile()
            guard let fresh = self.lease(id), fresh.state == .pendingApproval else { return }
            lease = fresh
            if matches {
                let date = Date()
                lease.move(to: .connecting, action: .approved, at: date)
                lease.makeReady(action: .reused, at: date)
            } else {
                lease.move(to: .failed, action: .failed, at: Date(), reason: .externalGone)
            }
            try save(lease)
        } else if let route = prepared(lease.input.target), route.key == lease.connectionKey {
            try activate(lease, route: route, action: .approved)
        } else {
            lease.move(to: .failed, action: .failed, at: Date(), reason: .routeChanged)
            try save(lease)
        }
    }

    func deny(_ id: UUID) throws {
        try reconcile()
        guard var lease = lease(id), lease.state == .pendingApproval else { return }
        lease.move(to: .denied, action: .denied, at: Date(), reason: .userDenied)
        try save(lease)
    }

    func end(_ id: UUID) throws {
        try reconcile()
        guard var lease = lease(id), lease.state.isOpen else { return }
        lease.move(to: .ended, action: .ended, at: Date(), reason: .userEnded)
        try save(lease)
        collectUnusedConnections()
    }

    func borrowed(_ lease: AgentLease) -> Bool {
        guard let key = lease.connectionKey, let connection = connections[key] else { return false }
        return !connection.runtime.isAgentOwned
    }

    private func request(_ arguments: AgentToolArguments, credential: AgentCredential) async throws -> AgentLease {
        let (key, input) = try arguments.leaseInput()
        let client = try authenticate(credential)
        if let existing = try previousRequest(client.id, key: key, input: input) {
            if existing.state == .ready, existing.external != nil {
                try await checkExternalLease(existing.id, credential: credential)
            }
            return lease(existing.id) ?? existing
        }
        guard ledger.requestsEnabled, client.canRequest else { throw AgentToolError.readOnly }

        let managed: AgentPreparedRoute?
        let external: AgentExternalEvidence?
        if case .external(let address) = input.target {
            managed = nil
            external = try await externalEvidence(at: address)
            let current = try authenticate(credential)
            if let existing = try previousRequest(current.id, key: key, input: input) { return existing }
            guard ledger.requestsEnabled, current.canRequest else { throw AgentToolError.readOnly }
        } else {
            managed = prepared(input.target)
            external = nil
        }
        guard let route = managed?.route ?? external?.route else {
            if case .external = input.target { throw AgentToolError.externalGone }
            throw AgentToolError.routeChanged
        }
        let date = Date()
        let lease = AgentLease(id: UUID(), clientID: client.id, clientName: client.name, requestKey: key, input: input, route: route,
                               profileID: managed?.key.profileID, fingerprint: managed?.key.fingerprint, external: external,
                               waitUntil: date.addingTimeInterval(300), events: [.init(at: date, action: .requested, reason: nil)])
        if case .shared = input.target, let managed {
            try activate(lease, route: managed, action: .authorized)
        } else {
            try save(lease)
            approvalNeeded?()
        }
        return self.lease(lease.id) ?? lease
    }

    private func activate(_ request: AgentLease, route: AgentPreparedRoute, action: AgentLease.Action) throws {
        let existing = connections[route.key] ?? manualConnection(for: route)
        var lease = request
        let now = Date()
        lease.waitUntil = now.addingTimeInterval(120)
        lease.reusesExistingConnection = existing != nil
        lease.move(to: .connecting, action: action, at: now)
        // Persist approval first. A failed audit write must never open a listener.
        try save(lease)
        connections[route.key] = existing ?? Connection(runtime: manager.connectAgentRoute(route), ruleID: route.rule.id)
        try reconcile(at: now)
    }

    private func manualConnection(for route: AgentPreparedRoute) -> Connection? {
        guard let runtime = manager.runtimes[route.key.profileID], runtime.desiredOn, let current = runtime.currentConfiguration,
              let match = current.enabledForwardings.first(where: { rule in
                  rule.bindAddress == route.rule.bindAddress &&
                      AgentPreparedRoute(profile: current, forwarding: rule)?.key == route.key
              }) else { return nil }
        return Connection(runtime: runtime, ruleID: match.id)
    }

    private func prepared(_ target: AgentLeaseInput.Target) -> AgentPreparedRoute? {
        switch target {
        case .shared(let id):
            return ledger.shares.first { $0.id == id }.flatMap(preparedShared)
        case .temporary(let id, let host, let port, let bind, let listenPort):
            guard let profile = manager.store.tunnel(id) else { return nil }
            let forwarding = Forwarding(bindAddress: bind, port: listenPort, targetHost: host, targetPort: port,
                                        name: L10n.text("Temporary Forward", "临时转发"))
            return AgentPreparedRoute(profile: profile, forwarding: forwarding)
        case .external:
            return nil
        }
    }

    private func preparedShared(_ share: AgentShare) -> AgentPreparedRoute? {
        guard let profile = manager.store.tunnel(share.profileID),
              let forwarding = profile.forwardings.first(where: { $0.id == share.forwardingID }),
              let route = AgentPreparedRoute(profile: profile, forwarding: forwarding),
              route.key.fingerprint == share.fingerprint else { return nil }
        return route
    }

    private func authenticate(_ credential: AgentCredential) throws -> AgentClient {
        guard !isClosing else { throw AgentToolError.unavailable }
        guard !storageError else { throw AgentToolError.storage }
        guard let client = ledger.clients.first(where: { $0.id == credential.clientID }),
              client.tokenDigest == agentDigest(Data(credential.token.utf8)) else { throw AgentToolError.notPaired }
        return client
    }

    private func lease(_ id: UUID) -> AgentLease? { ledger.leases.first { $0.id == id } }

    private func previousRequest(_ id: UUID, key: String, input: AgentLeaseInput) throws -> AgentLease? {
        guard let lease = ledger.leases.first(where: { $0.clientID == id && $0.requestKey == key }) else { return nil }
        guard lease.input == input else { throw AgentToolError.conflict }
        return lease
    }

    private func save(_ lease: AgentLease) throws {
        var next = ledger
        if let index = next.leases.firstIndex(where: { $0.id == lease.id }) {
            next.leases[index] = lease
        } else {
            next.leases.append(lease)
        }
        try commit(next)
    }

    private func commit(_ next: AgentLedger) throws {
        guard !storageError else { throw AgentToolError.storage }
        do {
            try files?.writeLedger(next)
            ledger = next
        } catch {
            storageError = true
            // If storage fails during cleanup, stop owned forwards anyway. Borrowed sessions remain untouched.
            for item in connections.values where item.runtime.isAgentOwned { item.runtime.stop() }
            connections.removeAll()
            throw AgentToolError.storage
        }
    }

    private func endLeases(in next: inout AgentLedger, reason: AgentLease.Reason, matching: (AgentLease) -> Bool) {
        let date = Date()
        for index in next.leases.indices where next.leases[index].state.isOpen && matching(next.leases[index]) {
            next.leases[index].move(to: .ended, action: .ended, at: date, reason: reason)
        }
    }

    /// Observe readiness from the same runtime that owns the OpenSSH acknowledgement.
    func reconcile(at now: Date = Date()) throws {
        var next = ledger
        var changed = false
        for index in next.leases.indices where next.leases[index].state.isOpen {
            let count = next.leases[index].events.count
            update(&next.leases[index], at: now)
            if next.leases[index].events.count != count { changed = true }
        }
        if changed { try commit(next) }
        collectUnusedConnections()
    }

    private func update(_ lease: inout AgentLease, at now: Date) {
        if let expiresAt = lease.expiresAt, now >= expiresAt {
            lease.move(to: .expired, action: .expired, at: now)
        } else if lease.state == .pendingApproval {
            if now >= lease.waitUntil {
                lease.move(to: .expired, action: .expired, at: now, reason: .approvalTimedOut)
            }
        } else if lease.external == nil {
            guard let key = lease.connectionKey, let connection = connections[key] else {
                lease.move(to: .failed, action: .failed, at: now, reason: .sshFailed)
                return
            }
            let runtime = connection.runtime
            if runtime.state.isFailure {
                lease.move(to: .failed, action: .failed, at: now, reason: .sshFailed)
            } else if !runtime.desiredOn {
                if lease.expiresAt == nil {
                    lease.move(to: .failed, action: .failed, at: now, reason: .sshFailed)
                } else {
                    lease.move(to: .ended, action: .ended, at: now, reason: .userEnded)
                }
            } else if lease.expiresAt == nil, now >= lease.waitUntil {
                lease.move(to: .failed, action: .failed, at: now, reason: .startupTimedOut)
            } else if runtime.state.isConnected, runtime.forwardStatus[connection.ruleID] == .active,
                      runtime.pid != nil || manager.demo {
                if lease.state != .ready {
                    let action: AgentLease.Action = lease.expiresAt != nil ? .reconnected :
                        (lease.reusesExistingConnection ? .reused : .connected)
                    lease.makeReady(action: action, at: now)
                }
            } else if lease.state == .ready {
                lease.move(to: .reconnecting, action: .reconnecting, at: now)
            }
        }
    }

    private func collectUnusedConnections() {
        let inUse = Set(ledger.leases.filter { $0.state.isOpen && $0.state != .pendingApproval }.compactMap(\.connectionKey))
        for key in connections.keys.filter({ !inUse.contains($0) }) {
            if let connection = connections.removeValue(forKey: key), connection.runtime.isAgentOwned {
                connection.runtime.stop()
            }
        }
    }

    private func tick() async {
        guard !storageError else { return }
        try? reconcile()
        let externalIDs = ledger.leases.filter { $0.state == .ready && $0.external != nil }.map(\.id)
        guard !externalIDs.isEmpty, nextDiscovery <= Date() else { return }
        nextDiscovery = Date().addingTimeInterval(5)
        guard let observed = try? await observedExternal() else { return }
        try? reconcileExternal(externalIDs, observed: observed)
    }

    private func checkExternalLease(_ id: UUID, credential: AgentCredential) async throws {
        let observed = try await observedExternal()
        _ = try authenticate(credential)
        try reconcile()
        try reconcileExternal([id], observed: observed)
    }

    private func reconcileExternal(_ ids: [UUID], observed: [AgentExternalEvidence]) throws {
        guard !isClosing else { return }
        let candidates = Set(ids)
        let gone = ledger.leases.filter { lease in
            guard lease.state == .ready, candidates.contains(lease.id), let evidence = lease.external else { return false }
            return !observed.contains(evidence)
        }
        guard !gone.isEmpty else { return }
        let missing = Set(gone.map(\.id))
        var next = ledger
        endLeases(in: &next, reason: .externalGone) { missing.contains($0.id) }
        try commit(next)
    }

    private func externalEvidence(at address: String) async throws -> AgentExternalEvidence? {
        let matches = try await observedExternal().filter { $0.route.listenAddress == address }
        return matches.count == 1 ? matches.first : nil
    }

    private func observedExternal() async throws -> [AgentExternalEvidence] {
        let owned = manager.runningPIDs
        do {
            let observed = try await Task.detached(priority: .utility) { try ExternalScanner.scan(excluding: owned) }.value
            return observed.filter { !manager.runningPIDs.contains($0.id) }.flatMap { session in
                session.rules.compactMap { AgentExternalEvidence(session: session, rule: $0) }
            }
        } catch {
            throw AgentToolError.externalGone
        }
    }
}
