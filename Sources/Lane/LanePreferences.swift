import Foundation
import Observation

/// Shared application preferences. Passing no defaults keeps demo and test changes in memory.
@MainActor
@Observable
final class LanePreferences {
    enum Appearance: String, CaseIterable { case system, light, dark }
    enum Presentation: String, CaseIterable { case both, dockOnly, menuBarOnly }

    enum Language: String, CaseIterable {
        case system, chinese = "zh-Hans", english = "en"

        static let key = "lane.language"
    }

    @ObservationIgnored private let defaults: UserDefaults?
    var appearance: Appearance {
        didSet { defaults?.set(appearance.rawValue, forKey: "lane.appearance") }
    }
    var presentation: Presentation {
        didSet { defaults?.set(presentation.rawValue, forKey: "lane.presentation") }
    }
    var language: Language {
        didSet { defaults?.set(language.rawValue, forKey: Language.key) }
    }
    var notifyOnConnect: Bool {
        didSet { defaults?.set(notifyOnConnect, forKey: "lane.notifyOnConnect") }
    }
    var notifyOnFailure: Bool {
        didSet { defaults?.set(notifyOnFailure, forKey: "lane.notifyOnFailure") }
    }
    var reconnectOnWake: Bool {
        didSet { defaults?.set(reconnectOnWake, forKey: "lane.reconnectOnWake") }
    }
    var customSSHPath: String {
        didSet { defaults?.set(customSSHPath, forKey: "lane.sshPath") }
    }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        appearance = Appearance(rawValue: defaults?.string(forKey: "lane.appearance") ?? "") ?? .system
        presentation = Presentation(rawValue: defaults?.string(forKey: "lane.presentation") ?? "") ?? .both
        language = Language(rawValue: defaults?.string(forKey: Language.key) ?? "") ?? .system
        notifyOnConnect = defaults?.bool(forKey: "lane.notifyOnConnect") ?? false
        notifyOnFailure = defaults?.bool(forKey: "lane.notifyOnFailure") ?? false
        reconnectOnWake = defaults?.object(forKey: "lane.reconnectOnWake") as? Bool ?? true
        customSSHPath = defaults?.string(forKey: "lane.sshPath") ?? ""
    }

    /// An empty preference explicitly selects the macOS OpenSSH client.
    var sshPath: String { customSSHPath.isEmpty ? OpenSSHClient.systemPath : customSSHPath }
}
