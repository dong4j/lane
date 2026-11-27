import PortlaneCore

/// The Pen examples are loaded only in the in-memory design review mode.
enum DemoContent {
    static var tunnels: [Tunnel] {
        [
            Tunnel(name: L10n.text("Development", "开发环境"), host: "dev-gateway", forwardings: [
                Forwarding(bindAddress: "127.0.0.1", port: 15432, targetHost: "db.dev.example", targetPort: 5432,
                           note: L10n.text("Development database", "开发数据库"), name: "PostgreSQL"),
                Forwarding(bindAddress: "127.0.0.1", port: 16379, targetHost: "cache.dev.example", targetPort: 6379,
                           note: L10n.text("Cache", "缓存"), name: "Redis")
            ]),
            Tunnel(name: L10n.text("Local preview", "本地预览"), host: "preview-host", forwardings: [rule(.remote)]),
            Tunnel(name: L10n.text("Home lab", "家庭实验室"), host: "home-gateway", forwardings: [rule(.dynamic)]),
            Tunnel(name: L10n.text("Staging panel", "预发面板"), host: "staging-gateway", forwardings: [
                Forwarding(bindAddress: "127.0.0.1", port: 8080, targetHost: "panel.example", targetPort: 80)
            ])
        ]
    }

    /// Examples supply valid endpoints, even when the real editor starts with a blank port.
    static func rule(_ kind: ForwardingKind) -> Forwarding {
        switch kind {
        case .local:
            Forwarding(bindAddress: "127.0.0.1", port: 15432, targetHost: "db.dev.example", targetPort: 5432, name: "PostgreSQL")
        case .remote:
            Forwarding(kind: .remote, bindAddress: "127.0.0.1", port: 18080, targetHost: "127.0.0.1", targetPort: 3000)
        case .dynamic:
            Forwarding(kind: .dynamic, bindAddress: "127.0.0.1", port: 1080)
        }
    }

    /// Recreates the two reported discovery states using synthetic processes and listeners.
    static var externalSessions: [ExternalSession] {
        let remote = SSHInvocation(arguments: ["ssh", "-N", "-R", "18080:127.0.0.1:3000", "preview-relay"])
        let local = SSHInvocation(arguments: ["ssh", "-N", "-L", "3111:127.0.0.1:3111",
                                              "-L", "3113:127.0.0.1:3113", "dev-box"])
        return [
            ExternalSession(pid: 10001, invocation: remote, listeners: []),
            ExternalSession(pid: 10002, invocation: local,
                            listeners: ListeningEndpoint.parseLsof("p10002\nn127.0.0.1:3111\nn127.0.0.1:3113\n"))
        ].compactMap { $0 }
    }
}
