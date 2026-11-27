import Foundation

public enum TunnelState: Equatable, Sendable {
    case off
    case connecting
    /// Waiting for the user to answer a password / host key prompt.
    case waitingForUser
    case connected
    case reconnecting(attempt: Int, at: Date)
    case disconnecting
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .off, .failed: return false
        default: return true
        }
    }

    public var isConnected: Bool { self == .connected }

    public var isBusy: Bool {
        switch self {
        case .connecting, .waitingForUser, .reconnecting, .disconnecting: return true
        default: return false
        }
    }

    public var title: String {
        switch self {
        case .off: return String(localized: "Off")
        case .connecting: return String(localized: "Connecting…")
        case .waitingForUser: return String(localized: "Waiting for you")
        case .connected: return String(localized: "Connected")
        case .reconnecting: return String(localized: "Reconnecting")
        case .disconnecting: return String(localized: "Disconnecting…")
        case .failed: return String(localized: "Failed")
        }
    }
}

public enum ForwardStatus: Equatable, Sendable {
    case idle
    case pending
    case active
    case failed(String)
}

public enum ReconnectPolicy {
    /// Delay before retry `attempt` (1-based): 2, 4, 8, 16, 30, 30… seconds.
    public static func delay(forAttempt attempt: Int) -> TimeInterval {
        let a = max(1, attempt)
        return min(30, pow(2, Double(min(a, 5))))
    }
}

public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let date: Date
    public let level: LogLevel
    public let message: String

    public init(id: UInt64, date: Date = Date(), level: LogLevel, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}
