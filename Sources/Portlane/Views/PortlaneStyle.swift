import SwiftUI
import PortlaneCore

/// Chinese and English wording for the product surfaces. Raw SSH diagnostics retain their original text.
enum L10n {
    static let launchedLanguage = PortlanePreferences.Language(
        rawValue: UserDefaults.standard.string(forKey: PortlanePreferences.Language.key) ?? ""
    ) ?? .system

    private static let usesChinese = switch launchedLanguage {
    case .system: Locale.preferredLanguages.first?.hasPrefix("zh") == true
    case .chinese: true
    case .english: false
    }

    static func text(_ english: String, _ chinese: String) -> String { usesChinese ? chinese : english }
}

/// Semantic colors from the editable v2 boards, shared across the window, menu and editor.
struct PortlaneStyle {
    let scheme: ColorScheme
    var dark: Bool { scheme == .dark }
    var window: Color { Color(rgb: dark ? 0x171A22 : 0xF7F8FA) }
    var sidebar: Color { Color(rgb: dark ? 0x20232D : 0xF0F0F6) }
    var surface: Color { Color(rgb: dark ? 0x242736 : 0xFEFEFF) }
    var control: Color { Color(rgb: dark ? 0x2C2F40 : 0xEFF0F6) }
    var edge: Color { Color(rgb: dark ? 0x393D52 : 0xDADCE8) }
    var text: Color { Color(rgb: dark ? 0xF2F1F8 : 0x232537) }
    var secondary: Color { Color(rgb: dark ? 0xB7B8CD : 0x575B6F) }
    var accent: Color { Color(rgb: dark ? 0xBEB0FF : 0x5B49C8) }
    var selected: Color { Color(rgb: dark ? 0x332E50 : 0xE7E3F7) }
    var positive: Color { Color(rgb: dark ? 0x8ED7BA : 0x236E55) }
    var positiveFill: Color { Color(rgb: dark ? 0x203D38 : 0xE3F2E8) }
    var warning: Color { Color(rgb: dark ? 0xF3C486 : 0x8C5116) }
    var warningFill: Color { Color(rgb: dark ? 0x3E3329 : 0xF8EDDC) }
    var routeSurface: Color { Color(rgb: dark ? 0x191E2D : 0xF9FAFD) }
    var routeNote: Color { Color(rgb: dark ? 0x151925 : 0xEEF0F7) }

    func routeInk(_ kind: ForwardingKind) -> Color {
        kind == .local ? accent : ink(kind)
    }

    func ink(_ kind: ForwardingKind) -> Color {
        switch kind {
        case .local: Color(rgb: dark ? 0xB5C5FD : 0x3655AA)
        case .remote: Color(rgb: dark ? 0xEFB0CD : 0x9C4A72)
        case .dynamic: Color(rgb: dark ? 0x9EDBCF : 0x1B6D66)
        }
    }

    func tile(_ kind: ForwardingKind) -> Color {
        switch kind {
        case .local: Color(rgb: dark ? 0x323A5D : 0xE7EDFD)
        case .remote: Color(rgb: dark ? 0x4D3045 : 0xF8E8F0)
        case .dynamic: Color(rgb: dark ? 0x24403F : 0xE2F2EF)
        }
    }
}

/// Selection changes keep their position, while disclosures can change the available space.
enum LaneMotion {
    static let crossfade = Animation.easeInOut(duration: 0.18)
    static let disclosure = Animation.smooth(duration: 0.22)
}

/// Provides pointer feedback for lightweight controls without changing their layout.
struct LaneHoverHighlight: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovered && enabled ? PortlaneStyle(scheme: scheme).control : .clear)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.11), value: hovered)
            }
            .onHover { hovered = $0 }
    }
}

extension Color {
    init(rgb: Int) {
        self.init(red: Double(rgb >> 16 & 255) / 255,
                  green: Double(rgb >> 8 & 255) / 255,
                  blue: Double(rgb & 255) / 255)
    }
}

extension ForwardingKind {
    var displayLabel: String {
        switch self {
        case .local: L10n.text("Local forwarding", "本地转发")
        case .remote: L10n.text("Remote forwarding", "远程转发")
        case .dynamic: L10n.text("Dynamic forwarding", "动态转发")
        }
    }

    var routeIcon: String {
        switch self {
        case .local: "arrow.right"
        case .remote: "arrow.left"
        case .dynamic: "point.3.connected.trianglepath.dotted"
        }
    }

    var usage: String {
        switch self {
        case .local: L10n.text("Connect on this Mac to a fixed service reachable from the SSH host.",
                              "在这台 Mac 打开本机端口，访问 SSH 主机能访问的服务。")
        case .remote: L10n.text("Use the server’s listening address to reach a service on this Mac.",
                               "用服务器的监听地址，访问这台 Mac 上运行的服务。")
        case .dynamic: L10n.text("Point a client at the local SOCKS5 proxy. Each connection chooses its destination.",
                                "把浏览器或客户端指向本机 SOCKS5，每个请求可选择不同目标。")
        }
    }
}

extension Forwarding {
    var displayName: String {
        if !name.isEmpty { return name }
        if kind == .dynamic { return "SOCKS5" }
        return targetHost.isEmpty || targetHost == "127.0.0.1" ? kind.displayLabel : targetHost
    }

    var clientAddress: String {
        let address: String
        switch bindAddress {
        case "*", "0.0.0.0": address = "127.0.0.1:\(port)"
        case "::", "[::]": address = "[::1]:\(port)"
        default: address = listenDisplayAddress
        }
        return (kind == .dynamic ? "socks5://" : "") + address
    }

    var copyTitle: String {
        switch kind {
        case .local: L10n.text("Copy address", "复制地址")
        case .remote: L10n.text("Copy server address", "复制服务器地址")
        case .dynamic: L10n.text("Copy proxy address", "复制代理地址")
        }
    }
}

extension TunnelState {
    var displayLabel: String {
        switch self {
        case .off: L10n.text("Disconnected", "已断开")
        case .connecting: L10n.text("Connecting…", "连接中…")
        case .waitingForUser: L10n.text("Awaiting verification", "等待验证")
        case .connected: L10n.text("Connected", "已连接")
        case .reconnecting: L10n.text("Waiting to reconnect", "等待重连")
        case .disconnecting: L10n.text("Disconnecting…", "断开中…")
        case .failed: L10n.text("Connection failed", "连接失败")
        }
    }

    var isFailure: Bool { if case .failed = self { true } else { false } }
}

/// Compact native buttons with the v2 control surface and stable hit targets.
struct LaneButtonStyle: ButtonStyle {
    enum Kind { case primary, neutral, subtle }
    var kind: Kind = .neutral
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let style = PortlaneStyle(scheme: scheme)
        let foreground: Color = kind == .primary ? (style.dark ? Color(rgb: 0x211749) : .white)
            : kind == .subtle ? style.accent : style.text
        let fill: Color = kind == .primary ? style.accent : kind == .neutral ? style.surface : .clear
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, kind == .subtle ? 5 : 10)
            .frame(minHeight: 30)
            .foregroundStyle(foreground)
            .background(fill, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                if kind == .neutral { RoundedRectangle(cornerRadius: 9).strokeBorder(style.edge) }
            }
            .opacity(enabled ? (configuration.isPressed ? 0.67 : 1) : 0.48)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// Portlane's compact route mark uses the same continuous line in every surface.
struct LaneGlyph: View {
    var size: CGFloat = 28
    var tinted = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let style = PortlaneStyle(scheme: scheme)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29).fill(tinted ? style.accent : style.selected)
            RouteMark().stroke(tinted ? (style.dark ? Color(rgb: 0x211749) : .white) : style.accent,
                               style: StrokeStyle(lineWidth: size * 0.055, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.56, height: size * 0.56)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private struct RouteMark: Shape {
        func path(in rect: CGRect) -> Path {
            let width = rect.width, height = rect.height
            let first = CGPoint(x: width * 0.79, y: height * 0.19)
            let last = CGPoint(x: width * 0.21, y: height * 0.81)
            let radius = width * 0.14
            var route = Path()
            route.move(to: CGPoint(x: first.x - radius, y: first.y))
            route.addLine(to: CGPoint(x: width * 0.25, y: first.y))
            route.addQuadCurve(to: CGPoint(x: width * 0.09, y: height * 0.34), control: CGPoint(x: width * 0.09, y: first.y))
            route.addQuadCurve(to: CGPoint(x: width * 0.25, y: height * 0.5), control: CGPoint(x: width * 0.09, y: height * 0.5))
            route.addLine(to: CGPoint(x: width * 0.75, y: height * 0.5))
            route.addQuadCurve(to: CGPoint(x: width * 0.91, y: height * 0.66), control: CGPoint(x: width * 0.91, y: height * 0.5))
            route.addQuadCurve(to: CGPoint(x: width * 0.75, y: last.y), control: CGPoint(x: width * 0.91, y: last.y))
            route.addLine(to: CGPoint(x: last.x + radius, y: last.y))
            for center in [first, last] {
                route.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
            return route
        }
    }
}
