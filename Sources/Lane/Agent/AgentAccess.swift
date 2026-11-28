import Foundation
import Observation
import LaneCore

/// Serializes policy, audit writes, and ownership changes on the app's main actor.
@MainActor
@Observable
final class AgentAccess {
    private struct Connection {
        let runtime: TunnelRuntime
        let ruleID: UUID
    }

    private struct RequestKey: Hashable {
        let clientID: UUID
        let value: String
    }

    private let manager: TunnelManager
    private let files: AgentFiles?
    @ObservationIgnored private var ipc: AgentIPC?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var nextDiscovery = Date.distantPast
    @ObservationIgnored private var isClosing = false
    @ObservationIgnored private var audit: AgentAuditStore?
    @ObservationIgnored private var requestIDs: [RequestKey: UUID] = [:]
    private var connections: [AgentPreparedRoute.Key: Connection] = [:]
    private var leasesByID: [UUID: AgentLease] = [:]
    private var leaseOrder: [UUID] = []
    private var openIDs: Set<UUID> = []
    private(set) var ledger = AgentLedger()
    private(set) var storageError = false
    private(set) var serviceError = false

    var available: Bool { files != nil && !storageError && !serviceError }
    var hasLeases: Bool { !leaseOrder.isEmpty }
    private var openLeases: [AgentLease] { openIDs.compactMap { leasesByID[$0] } }
    var active: [AgentLease] {
        openLeases.filter { $0.state != .pendingApproval }
            .sorted { ($0.events.first?.at ?? $0.waitUntil) > ($1.events.first?.at ?? $1.waitUntil) }
    }
    var history: [AgentLease] {
        leaseOrder.reversed().compactMap { id in openIDs.contains(id) ? nil : leasesByID[id] }
    }

    init(manager: TunnelManager, files: AgentFiles?) {
        self.manager = manager
        self.files = files
        guard let files else { return }
        do {
            let database = try AgentAuditStore(files: files)
            var restored = try database.load(legacy: files.ledger)
            audit = database
            for lease in restored.leases { remember(lease) }
            restored.leases = []
            ledger = restored
            let ended = endedLeases(reason: .appRestarted) { _ in true }
            if !ended.isEmpty { try commit(leases: ended) }
        } catch {
            storageError = true
        }
    }

    /// No TCP endpoint is opened. The stdio helper talks to this app instance over a private socket.
    func start() {
        guard let files, ipc == nil else { return }
        if ledger.requestsEnabled { libraryChanged() }
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
        let ended = endedLeases(reason: .appQuit) { _ in true }
        if !ended.isEmpty { try? commit(leases: ended) }
        collectUnusedConnections()
    }

    /// The generated setup points at a private credential file, not the token itself.
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
            try commit(settings: next)
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

    /// Reuse a valid local identity so copied recipes and audit records remain stable.
    func configuration(forClientNamed name: String, executable: String? = Bundle.main.executablePath) throws -> AgentMCPConfiguration {
        guard available, let files, let executable else { throw AgentToolError.unavailable }
        for client in ledger.clients.reversed() where client.name.caseInsensitiveCompare(name) == .orderedSame {
            let file = files.credentialURL(client.id)
            guard let data = try? Data(contentsOf: file),
                  let credential = try? JSONDecoder().decode(AgentCredential.self, from: data),
                  credential.clientID == client.id, credential.socketPath == files.socketPath,
                  client.tokenDigest == agentDigest(Data(credential.token.utf8)) else { continue }
            return AgentMCPConfiguration(executable: executable, credentialFile: file.path)
        }
        let client = try pair(name)
        return AgentMCPConfiguration(executable: executable, credentialFile: files.credentialURL(client.id).path)
    }

    func setRequestsEnabled(_ enabled: Bool) throws {
        var next = ledger
        next.requestsEnabled = enabled
        var ended: [AgentLease] = []
        if enabled {
            next.shares = availableShares(from: next.shares)
        } else {
            ended = endedLeases(reason: .accessDisabled) { _ in true }
        }
        try commit(settings: next, leases: ended)
        collectUnusedConnections()
    }

    func revokeClient(_ id: UUID) throws {
        var next = ledger
        next.clients.removeAll { $0.id == id }
        let ended = endedLeases(reason: .clientRevoked) { $0.clientID == id }
        try commit(settings: next, leases: ended)
        collectUnusedConnections()
        if let file = files?.credentialURL(id) { try? FileManager.default.removeItem(at: file) }
    }

    /// Keep eligible local rules in sync and end leases when their saved route changes.
    func libraryChanged() {
        let invalid = endedLeases(reason: .routeChanged) { lease in
            guard let key = lease.connectionKey else { return false }
            return prepared(lease.input.target)?.key != key
        }
        let validShares = ledger.requestsEnabled ? availableShares(from: ledger.shares) :
            ledger.shares.filter { preparedShared($0) != nil }
        guard !invalid.isEmpty || validShares.map(\.id) != ledger.shares.map(\.id) else { return }
        var next = ledger
        next.shares = validShares
        try? commit(settings: next, leases: invalid)
        collectUnusedConnections()
    }

    /// Enabling Agent access makes saved, valid loopback local forwards discoverable.
    private func availableShares(from existing: [AgentShare]) -> [AgentShare] {
        var shares = existing.filter { preparedShared($0) != nil }
        for profile in manager.store.tunnels {
            for rule in profile.forwardings {
                guard let route = AgentPreparedRoute(profile: profile, forwarding: rule),
                      !shares.contains(where: { $0.profileID == profile.id && $0.forwardingID == rule.id }) else { continue }
                shares.append(AgentShare(id: UUID(), profileID: profile.id, forwardingID: rule.id,
                                         fingerprint: route.key.fingerprint))
            }
        }
        return shares
    }

    /// Only the paired client that owns a lease can query or release it.
    func handle(_ call: AgentToolCall) async -> AgentToolResult {
        do {
            let client = try authenticate(call.credential)
            guard ledger.requestsEnabled else { throw AgentToolError.readOnly }
            try reconcile()
            switch call.tool {
            case .list:
                let rules = ledger.shares.compactMap { share in
                    preparedShared(share).map { AgentToolResult.Rule(share: share, route: $0.route) }
                }
                let profiles = manager.store.tunnels.map(AgentToolResult.Profile.init)
                return AgentToolResult(rules: rules, profiles: profiles, canRequest: true)
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

    func end(_ id: UUID) throws {
        try reconcile()
        guard var lease = lease(id), lease.state.isOpen else { return }
        lease.move(to: .ended, action: .ended, at: Date(), reason: .userEnded)
        try save(lease)
        collectUnusedConnections()
    }

    func borrowed(_ lease: AgentLease) -> Bool {
        guard let key = lease.connectionKey, let connection = connections[key] else { return false }
        return !connection.runtime.isAgentOwned || connection.runtime.heldByUser
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
        guard ledger.requestsEnabled else { throw AgentToolError.readOnly }

        let managed: AgentPreparedRoute?
        let external: AgentExternalEvidence?
        if case .external(let address) = input.target {
            managed = nil
            external = try await externalEvidence(at: address)
            let current = try authenticate(credential)
            if let existing = try previousRequest(current.id, key: key, input: input) { return existing }
            guard ledger.requestsEnabled else { throw AgentToolError.readOnly }
        } else {
            managed = prepared(input.target)
            external = nil
        }
        guard let route = managed?.route ?? external?.route else {
            if case .external = input.target { throw AgentToolError.externalGone }
            throw AgentToolError.routeChanged
        }
        let now = Date()
        var lease = AgentLease(id: UUID(), clientID: client.id, clientName: client.name, requestKey: key, input: input, route: route,
                               profileID: managed?.key.profileID, fingerprint: managed?.key.fingerprint, external: external,
                               state: .connecting, waitUntil: now.addingTimeInterval(120),
                               events: [.init(at: now, action: .requested, reason: nil),
                                        .init(at: now, action: .authorized, reason: nil)])
        if let managed {
            let existing = connections[managed.key] ?? manager.reusableRoute(managed).map {
                Connection(runtime: $0.0, ruleID: $0.1)
            }
            lease.reusesExistingConnection = existing != nil
            // Persist the audit before starting an SSH process.
            try save(lease)
            let connection = existing ?? Connection(runtime: manager.connectAgentRoute(managed), ruleID: managed.rule.id)
            if connection.runtime.isAgentOwned { connection.runtime.leasedByAgent = true }
            connections[managed.key] = connection
            try reconcile(at: now)
        } else {
            lease.makeReady(action: .reused, at: now)
            try save(lease)
        }
        return self.lease(lease.id) ?? lease
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

    private func lease(_ id: UUID) -> AgentLease? { leasesByID[id] }

    private func previousRequest(_ id: UUID, key: String, input: AgentLeaseInput) throws -> AgentLease? {
        guard let leaseID = requestIDs[RequestKey(clientID: id, value: key)], let lease = lease(leaseID) else { return nil }
        guard lease.input == input else { throw AgentToolError.conflict }
        return lease
    }

    private func save(_ lease: AgentLease) throws {
        try commit(leases: [lease])
    }

    private func remember(_ lease: AgentLease) {
        if leasesByID[lease.id] == nil {
            leaseOrder.append(lease.id)
            requestIDs[RequestKey(clientID: lease.clientID, value: lease.requestKey)] = lease.id
        }
        leasesByID[lease.id] = lease
        if lease.state.isOpen {
            openIDs.insert(lease.id)
        } else {
            openIDs.remove(lease.id)
        }
    }

    private func commit(settings: AgentLedger? = nil, leases: [AgentLease] = []) throws {
        guard !storageError else { throw AgentToolError.storage }
        do {
            try audit?.write(settings: settings, leases: leases)
            if let settings { ledger = settings }
            for lease in leases { remember(lease) }
        } catch {
            storageError = true
            // If storage fails during cleanup, stop owned forwards anyway. Borrowed sessions remain untouched.
            for item in connections.values { manager.releaseAgentRoute(item.runtime) }
            connections.removeAll()
            throw AgentToolError.storage
        }
    }

    private func endedLeases(reason: AgentLease.Reason, matching: (AgentLease) -> Bool) -> [AgentLease] {
        let date = Date()
        return openLeases.filter(matching).map {
            var lease = $0
            lease.move(to: .ended, action: .ended, at: date, reason: reason)
            return lease
        }
    }

    /// Observe readiness from the same runtime that owns the OpenSSH acknowledgement.
    func reconcile(at now: Date = Date()) throws {
        var changed: [AgentLease] = []
        for var lease in openLeases {
            let count = lease.events.count
            update(&lease, at: now)
            if lease.events.count != count { changed.append(lease) }
        }
        if !changed.isEmpty { try commit(leases: changed) }
        collectUnusedConnections()
    }

    private func update(_ lease: inout AgentLease, at now: Date) {
        if let expiresAt = lease.expiresAt, now >= expiresAt {
            lease.move(to: .expired, action: .expired, at: now)
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
        let inUse = Set(openLeases.compactMap(\.connectionKey))
        for key in connections.keys.filter({ !inUse.contains($0) }) {
            if let connection = connections.removeValue(forKey: key) {
                manager.releaseAgentRoute(connection.runtime)
            }
        }
    }

    private func tick() async {
        guard !storageError else { return }
        try? reconcile()
        let externalIDs = openLeases.filter { $0.state == .ready && $0.external != nil }.map(\.id)
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
        let gone = endedLeases(reason: .externalGone) { lease in
            guard lease.state == .ready, candidates.contains(lease.id), let evidence = lease.external else { return false }
            return !observed.contains(evidence)
        }
        guard !gone.isEmpty else { return }
        try commit(leases: gone)
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
