import Foundation
import Observation

/// Shared application preferences. Passing no defaults keeps demo and test changes in memory.
@MainActor
@Observable
final class PortlanePreferences {
    enum Appearance: String, CaseIterable { case system, light, dark }
    enum Presentation: String, CaseIterable { case both, dockOnly, menuBarOnly }

    enum Language: String, CaseIterable {
        case system, chinese = "zh-Hans", english = "en"

        static let key = "portlane.language"
    }

    @ObservationIgnored private let defaults: UserDefaults?
    var appearance: Appearance {
        didSet { defaults?.set(appearance.rawValue, forKey: "portlane.appearance") }
    }
    var presentation: Presentation {
        didSet { defaults?.set(presentation.rawValue, forKey: "portlane.presentation") }
    }
    var language: Language {
        didSet { defaults?.set(language.rawValue, forKey: Language.key) }
    }
    var notifyOnConnect: Bool {
        didSet { defaults?.set(notifyOnConnect, forKey: "portlane.notifyOnConnect") }
    }
    var notifyOnFailure: Bool {
        didSet { defaults?.set(notifyOnFailure, forKey: "portlane.notifyOnFailure") }
    }
    var reconnectOnWake: Bool {
        didSet { defaults?.set(reconnectOnWake, forKey: "portlane.reconnectOnWake") }
    }
    var customSSHPath: String {
        didSet { defaults?.set(customSSHPath, forKey: "portlane.sshPath") }
    }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        appearance = Appearance(rawValue: defaults?.string(forKey: "portlane.appearance") ?? "") ?? .system
        presentation = Presentation(rawValue: defaults?.string(forKey: "portlane.presentation") ?? "") ?? .both
        language = Language(rawValue: defaults?.string(forKey: Language.key) ?? "") ?? .system
        notifyOnConnect = defaults?.bool(forKey: "portlane.notifyOnConnect") ?? false
        notifyOnFailure = defaults?.bool(forKey: "portlane.notifyOnFailure") ?? false
        reconnectOnWake = defaults?.object(forKey: "portlane.reconnectOnWake") as? Bool ?? true
        customSSHPath = defaults?.string(forKey: "portlane.sshPath") ?? ""
    }

    /// An empty preference explicitly selects the macOS OpenSSH client.
    var sshPath: String { customSSHPath.isEmpty ? OpenSSHClient.systemPath : customSSHPath }
}
