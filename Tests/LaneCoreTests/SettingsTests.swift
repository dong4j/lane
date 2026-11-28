import Darwin
import Foundation
import LaneCore
@testable import Lane
import Testing

/// Covers settings behavior without using the real tunnel library, defaults, or saved credentials.
@MainActor
struct SettingsTests {
    @Test func roundTripsLanePreferences() throws {
        let name = "site.dong4j.lane.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("dark", forKey: "lane.appearance")

        let preferences = LanePreferences(defaults: defaults)
        #expect(preferences.appearance == .dark)
        #expect(preferences.presentation == .both)
        #expect(preferences.reconnectOnWake)
        #expect(preferences.sshPath == "/usr/bin/ssh")

        preferences.language = .chinese
        preferences.presentation = .menuBarOnly
        preferences.reconnectOnWake = false
        preferences.notifyOnConnect = true
        preferences.customSSHPath = "/opt/homebrew/bin/ssh"

        let reloaded = LanePreferences(defaults: defaults)
        #expect(reloaded.language == .chinese)
        #expect(reloaded.presentation == .menuBarOnly)
        #expect(!reloaded.reconnectOnWake)
        #expect(reloaded.notifyOnConnect)
        #expect(reloaded.sshPath == "/opt/homebrew/bin/ssh")
    }

    /// Preview and commit independently skip duplicates, even if a second preview is still open.
    @Test func restoresSelectedBackupEntriesAndPreservesTheirIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "backup.json")
        let tunnel = Tunnel(name: "Fixture", host: "example.invalid",
                            forwardings: [Forwarding(kind: .dynamic, port: 1090)], autoConnect: true)
        let document = PortholeDocument(tunnels: [tunnel, tunnel, Tunnel()])
        try PortholeDocument.encoder().encode(document).write(to: file)

        let model = LaneModel(demo: true)
        let preview = try model.backupImport(from: file)
        #expect(preview.tunnels == [tunnel])
        #expect(preview.skippedCount == 2)
        #expect(try model.importSelected(preview.tunnels, kind: preview.kind) == 1)
        #expect(model.selection == .managed(tunnel.id))
        #expect(throws: (any Error).self) {
            try model.importSelected(preview.tunnels, kind: preview.kind)
        }

        let exported = try PortholeDocument.decoder().decode(PortholeDocument.self, from: model.store.exportData())
        #expect(exported.tunnels.first(where: { $0.id == tunnel.id }) == tunnel)
    }

    @Test func recognizesCodinnFilesAndSkipsAnAlreadyImportedSession() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "codinn.json")
        try Data("""
        {"tunnels":[{"name":"Legacy","ssh_host":"legacy.example","forwardings":[{"type":2,"port":1091}]}]}
        """.utf8).write(to: file)

        let model = LaneModel(demo: true)
        let preview = try model.backupImport(from: file)
        #expect(preview.tunnels.first?.forwardings.first?.kind == .dynamic)
        #expect(try model.importSelected(preview.tunnels, kind: preview.kind) == 1)
        #expect(throws: (any Error).self) { try model.backupImport(from: file) }
    }

    @Test func externalBackupPreviewAndMergeKeepOnlySupportedSSHOptions() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "untrusted.json")
        let original = Tunnel(host: "sample.invalid", identityFile: "/fixture/example-key",
                              forwardings: [Forwarding()], extraOptions: """
                              ServerAliveInterval 45
                              ProxyCommand fixture-placeholder
                              -o KnownHostsCommand=fixture-placeholder
                              LocalCommand=fixture-placeholder
                              """)
        let contents = try PortholeDocument.encoder().encode(PortholeDocument(tunnels: [original]))
        try contents.write(to: file)
        let model = LaneModel(demo: true)
        let preview = try model.backupImport(from: file)
        #expect(preview.ignoredOptions == ["knownhostscommand", "localcommand", "proxycommand"])
        let safe = try #require(preview.tunnels.first)
        #expect(safe.identityFile == original.identityFile)
        #expect(safe.forwardings == original.forwardings)
        #expect(safe.extraOptions == "ServerAliveInterval=45")
        #expect(try model.importSelected(preview.tunnels, kind: preview.kind) == 1)
        #expect(model.store.tunnel(original.id)?.extraOptions == safe.extraOptions)
        #expect(try Data(contentsOf: file) == contents)
    }

    @Test func restoringSameIdentityAndMalformedLibraryPreservesTheOriginalBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = directory.appending(path: "backup.json")
        let config = directory.appending(path: "tunnels.json")
        let original = Tunnel(host: "sample.invalid", forwardings: [Forwarding(targetPort: 3113)])
        let groups = [SmartGroup(name: "All", keywords: "sample")]
        try PortholeDocument.encoder().encode(PortholeDocument(tunnels: [original], smartGroups: groups)).write(to: backup)
        var changed = original
        changed.forwardings[0].targetPort = 3111
        let altered = try PortholeDocument.encoder().encode(PortholeDocument(tunnels: [changed]))
        let model = LaneModel(demo: true)
        let preview = try model.backupImport(from: backup, restoring: true)
        #expect(preview.tunnels == [original])

        for startingBytes in [altered, Data("truncated".utf8)] {
            try startingBytes.write(to: config)
            let store = TunnelStore(fileURL: config)
            #expect(store.canRestore)
            #expect((store.loadError != nil) == (startingBytes != altered))
            let preserved = try #require(try store.restore(preview.tunnels, smartGroups: preview.smartGroups))
            #expect(try Data(contentsOf: preserved) == startingBytes)
            #expect(store.loadError == nil)
            #expect(store.tunnel(original.id)?.forwardings.first?.targetPort == 3113)
            let stored = try PortholeDocument.decoder().decode(PortholeDocument.self, from: Data(contentsOf: config))
            #expect(stored.smartGroups == groups)
        }
    }

    @Test func unsupportedLibraryStaysReadOnlyEvenWhenRestoring() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "future.json")
        let bytes = Data(#"{"version":2,"tunnels":[],"future":{"field":true}}"#.utf8)
        try bytes.write(to: file)
        let store = TunnelStore(fileURL: file)
        #expect(store.loadError != nil)
        #expect(!store.canRestore)
        #expect(throws: (any Error).self) { try store.save(Tunnel(host: "fixture")) }
        #expect(throws: (any Error).self) { try store.restore([], smartGroups: []) }
        let model = LaneModel(demo: true)
        #expect(throws: (any Error).self) { try model.backupImport(from: file) }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func proxyIdentityChangesBothRestartAndReuseWhileNotesDoNot() throws {
        let model = LaneModel(demo: true)
        let rule = Forwarding(bindAddress: "127.0.0.1")
        let original = Tunnel(host: "sample.invalid", forwardings: [rule],
                              proxy: ProxySettings(kind: .socks5, host: "proxy.invalid", port: 1080,
                                                   username: "alice", requiresPassword: true))
        let before = try #require(AgentPreparedRoute(profile: original, forwarding: rule))
        var changed = original
        changed.note = "New note"
        #expect(!model.manager.requiresRestart(for: changed, replacing: original))
        changed.proxy.username = "bob"
        let after = try #require(AgentPreparedRoute(profile: changed, forwarding: rule))
        #expect(model.manager.requiresRestart(for: changed, replacing: original))
        #expect(before.key != after.key)
        let command = model.manager.commandBuilder.displayCommand(for: changed)
        #expect(command.contains("--proxy-connect socks5 proxy.invalid 1080 %h %p bob ask-password"))
    }

    @Test func configPreviewExpandsIncludesWithoutTurningPatternsIntoHosts() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let parts = directory.appending(path: "conf.d")
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appending(path: "config")
        let hosts = parts.appending(path: "10-lab hosts.conf")
        try """
        Include conf.d/*.conf missing/*.conf
        Host *
          ServerAliveInterval 10
        """.write(to: config, atomically: true, encoding: .utf8)
        try """
        Include config
        Host dev staging
          Include "conf.d/forward file"
        Host unused* !unused-test
          LocalForward 3111 127.0.0.1:3111
        Match host staging
          LocalForward 3112 127.0.0.1:3112
        """.write(to: hosts, atomically: true, encoding: .utf8)
        try "LocalForward 3113 127.0.0.1:3113\n".write(to: parts.appending(path: "forward file"),
                                                               atomically: true, encoding: .utf8)
        let model = LaneModel(demo: true)
        let preview = try model.sshConfigImport(from: config)
        #expect(preview.tunnels.map(\.host) == ["dev", "staging"])
        #expect(preview.tunnels.allSatisfy { $0.forwardings.map(\.port) == [3113] && $0.useSSHConfig })
        #expect(preview.configSources.values.allSatisfy { $0.hasSuffix("10-lab hosts.conf") })
        #expect(preview.configWarnings.count == 3)
    }

    @Test func bindFailureUsesTheRightFieldAndListenerFamily() {
        let rule = Forwarding(bindAddress: "127.0.0.1:3113", port: 3113)
        #expect(TunnelValidator.validate(rule).first?.field == .forwarding(rule.id, .listenAddress))
        let sockets = """
        p42
        cWrongIPv4
        f7
        tIPv4
        n127.0.0.2:3113
        p57
        cIPv6Listener
        f11
        tIPv6
        n*:3113
        p93
        cIPv4Listener
        f4
        tIPv4
        n127.0.0.1:3113
        """
        #expect(PortInspector.listenerName(in: sockets, port: 3113, host: "127.0.0.1", family: AF_INET) == "IPv4Listener")
        #expect(PortInspector.listenerName(in: sockets, port: 3113, host: "::1", family: AF_INET6) == "IPv6Listener")
        #expect(PortInspector.listenerName(in: sockets, port: 3113, host: "0.0.0.0", family: AF_INET) == nil)
        #expect(PortInspector.listenerName(in: sockets, port: 3114, host: "127.0.0.1", family: AF_INET) == nil)
    }

    @Test func validatesOnlyOpenSSHExecutables() async throws {
        #expect(try await OpenSSHClient.version(at: "/usr/bin/ssh").hasPrefix("OpenSSH_"))
        await #expect(throws: OpenSSHClient.CheckError.unsupported) {
            try await OpenSSHClient.version(at: "/usr/bin/true")
        }
    }
}
