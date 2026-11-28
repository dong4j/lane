import SwiftUI
import LaneCore

/// The three v2 paths share the same spatial model: this Mac, the SSH host, then the server side.
struct RouteDiagram: View {
    enum Mode { case live, preview, example, idle, external, blocked }

    var forwarding: Forwarding?
    var sshHost: String
    var mode: Mode
    var observedAddress: String? = nil
    var ruleID: String? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let capturesStillFrame = CommandLine.arguments.contains("--render-previews")
    private var style: LaneStyle { LaneStyle(scheme: scheme) }
    private var tint: Color { mode == .blocked ? style.warning : forwarding.map { style.routeInk($0.kind) } ?? style.secondary }
    private var listen: String {
        if let observedAddress { return observedAddress }
        guard let forwarding, forwarding.port > 0 else { return L10n.text("Listening port", "等待填写端口") }
        return forwarding.listenDisplayAddress
    }
    private var destination: String {
        guard let forwarding, !forwarding.targetHost.isEmpty, forwarding.targetPort > 0 else {
            return L10n.text("Target address", "等待填写目标")
        }
        return forwarding.targetDisplayAddress
    }
    private var host: String { sshHost.isEmpty ? L10n.text("SSH host", "SSH 主机") : sshHost }

    var body: some View {
        let identity = PathIdentity(ruleID: ruleID, kind: forwarding?.kind)
        ZStack {
            VStack(spacing: 7) {
                header
                if let forwarding {
                    GeometryReader { geometry in
                        routes(forwarding, in: RouteLayout(width: geometry.size.width, height: geometry.size.height))
                    }
                    .frame(height: 105)
                } else {
                    unknownRoute
                        .frame(height: 105)
                }
                footer
            }
            .id(identity)
            .transition(.opacity)
        }
        .animation(reduceMotion ? nil : LaneMotion.crossfade, value: identity)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(minHeight: 205)
        .background {
            let shape = RoundedRectangle(cornerRadius: 16)
            shape.fill(style.routeSurface)
                .overlay {
                    shape.fill(RadialGradient(colors: [style.accent.opacity(style.dark ? 0.105 : 0.06), .clear],
                                              center: .center, startRadius: 0, endRadius: 340))
                }
        }
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(style.edge).allowsHitTesting(false) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleRoute)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: mode == .blocked ? "exclamationmark.triangle" : "point.topleft.down.to.point.bottomright.curvepath")
                .foregroundStyle(tint)
            Text(title).foregroundStyle(style.text).fontWeight(.semibold)
            Spacer()
            if let kind = forwarding?.kind {
                HStack(spacing: 6) {
                    Text(kind.displayLabel).font(.system(size: 11, weight: .semibold))
                    Text(kind.flag).font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .foregroundStyle(tint)
                .background(tint.opacity(style.dark ? 0.15 : 0.09), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .font(.system(size: 13))
        .frame(height: 28)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: mode == .blocked ? "exclamationmark.circle" : "info.circle")
                .foregroundStyle(tint)
                .font(.system(size: 12))
            Text(usage).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let kind = forwarding?.kind {
                Text(kind.listensLocally ? L10n.text("Starts on this Mac", "从本机发起")
                    : L10n.text("Starts at the server", "从服务器发起"))
                    .font(.system(size: 10))
                    .fixedSize()
            }
        }
        .foregroundStyle(style.secondary)
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(style.routeNote, in: RoundedRectangle(cornerRadius: 8))
    }

    private var unknownRoute: some View {
        HStack(spacing: 14) {
            endpoint("laptopcomputer", L10n.text("Mac · Listener", "这台 Mac · 本机监听"), listen, accented: false)
                .frame(maxWidth: 180)
            Image(systemName: "ellipsis").foregroundStyle(style.secondary)
            endpoint("questionmark", L10n.text("Target unknown", "目标未知"), nil, accented: false)
                .frame(maxWidth: 170)
        }
        .frame(maxWidth: .infinity)
    }

    private func routes(_ rule: Forwarding, in layout: RouteLayout) -> some View {
        let dynamic = rule.kind == .dynamic
        let remote = rule.kind == .remote
        let narrow = layout.width < 470
        let isAnimating = switch mode {
        case .live, .preview, .example, .external: !reduceMotion && !capturesStillFrame
        case .idle, .blocked: false
        }
        return ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 45.0, paused: !isAnimating)) { timeline in
                Canvas { context, _ in
                    let lanes: [CGFloat] = dynamic ? [-25, 25] : [0]
                    for lane in lanes {
                        drawRail(in: context, layout: layout, lane: lane, remote: remote)
                    }
                    if isAnimating {
                        let time = timeline.date.timeIntervalSinceReferenceDate / 2.75
                        let whole = time.rounded(.down)
                        let fraction = time - whole
                        let lane = lanes[Int(whole) % lanes.count]
                        drawPulse(in: context, layout: layout, lane: lane, phase: fraction, remote: remote)
                    }
                }
            }
            Text(L10n.text("SSH encrypted", "SSH 加密"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(style.secondary)
                .position(x: (layout.leftEdge + layout.centerLeft) / 2, y: layout.midY - (narrow ? 33 : 19))
            endpoint("laptopcomputer", startCaption(remote: remote, dynamic: dynamic, narrow: narrow),
                     remote ? destination : listen, accented: !remote)
                .frame(width: layout.leftWidth)
                .position(x: layout.leftCenter, y: layout.midY)
            endpoint("lock", L10n.text("SSH host", "SSH 主机"), host, accented: true, compactIcon: true)
                .frame(width: layout.centerWidth)
                .position(x: layout.midX, y: layout.midY)
            if dynamic {
                endpoint("globe", L10n.text("Intranet page", "内网页面"), nil, accented: true)
                    .frame(width: layout.rightWidth)
                    .position(x: layout.rightCenter, y: layout.midY - 25)
                endpoint("globe", L10n.text("Remote API", "远端 API"), nil, accented: true)
                    .frame(width: layout.rightWidth)
                    .position(x: layout.rightCenter, y: layout.midY + 25)
            } else {
                endpoint(remote ? "server.rack" : "shippingbox", remote ? L10n.text("Server entry", "服务器入口")
                         : rule.name.isEmpty ? L10n.text("Remote service", "远端服务") : rule.name,
                         remote ? listen : destination, accented: remote)
                    .frame(width: layout.rightWidth)
                    .position(x: layout.rightCenter, y: layout.midY)
            }
        }
    }

    private func startCaption(remote: Bool, dynamic: Bool, narrow: Bool) -> String {
        if remote { return L10n.text("Target via Mac", narrow ? "经 Mac 访问" : "Mac 访问的目标") }
        if dynamic { return L10n.text("Mac · SOCKS5", narrow ? "本机 SOCKS5" : "这台 Mac · SOCKS5") }
        return L10n.text("Mac · Entry", narrow ? "本机入口" : "这台 Mac · 本机入口")
    }

    private func endpoint(_ icon: String, _ title: String, _ value: String?, accented: Bool, compactIcon: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: compactIcon ? 17 : 23, height: 23)
                .foregroundStyle(accented ? tint : style.secondary)
                .background(compactIcon ? .clear : accented ? tint.opacity(0.14) : style.control,
                            in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(value == nil ? style.text : style.secondary)
                    .lineLimit(1)
                if let value {
                    ViewThatFits(in: .horizontal) {
                        Text(value).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        Text(wrapAddress(value)).lineLimit(2).minimumScaleFactor(0.86)
                    }
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(style.text)
                    .help(value)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, value == nil ? 3 : 8)
        .frame(minHeight: value == nil ? 30 : 48)
        .background {
            let shape = RoundedRectangle(cornerRadius: 10)
            shape.fill(style.surface)
                .overlay { shape.fill(accented ? tint.opacity(style.dark ? 0.11 : 0.045) : .clear) }
                .overlay { shape.strokeBorder(accented ? tint.opacity(style.dark ? 0.46 : 0.31) : style.edge) }
        }
    }

    /// The narrow layout may wrap at the port separator, leaving the port number intact.
    private func wrapAddress(_ value: String) -> String {
        guard let colon = value.lastIndex(of: ":"), Int(value[value.index(after: colon)...]) != nil else { return value }
        return String(value[...colon]) + "\u{200B}" + value[value.index(after: colon)...]
    }

    private var title: String {
        switch mode {
        case .preview: L10n.text("Path preview", "路径预览")
        case .example: L10n.text("Example path", "路径示例")
        default: L10n.text("Forwarding path", "转发路径")
        }
    }

    private var usage: String {
        if mode == .blocked { return L10n.text("Resolve the listening port before reconnecting.", "修正监听端口后，重新连接此隧道。") }
        if mode == .external, forwarding?.kind == .remote {
            return L10n.text("Declared on the command line. The remote listener is unverified.", "启动参数声明了远程转发，远端监听尚未核实。")
        }
        return forwarding?.kind.usage ?? L10n.text("A local listener was observed. The forwarding target is unknown.",
                                                 "已观测到本机监听，无法确认转发目标。")
    }

    private var accessibleRoute: String {
        guard let forwarding else { return usage }
        let sequence: String
        switch forwarding.kind {
        case .local: sequence = "\(listen) → \(host) → \(destination)"
        case .remote: sequence = "\(host) \(listen) → \(destination)"
        case .dynamic: sequence = "\(listen) SOCKS5 → \(host)"
        }
        return "\(title). \(forwarding.kind.displayLabel). \(sequence). \(usage)"
    }

    private func drawRail(in context: GraphicsContext, layout: RouteLayout, lane: CGFloat, remote: Bool) {
        let dashed = mode == .idle || (mode == .external && remote) || mode == .blocked
        let rail = Path { path in
            path.move(to: CGPoint(x: layout.leftCenter, y: layout.midY))
            path.addLine(to: CGPoint(x: layout.midX, y: layout.midY))
            let span = layout.branchEnd - layout.midX
            path.addCurve(to: CGPoint(x: layout.branchEnd, y: layout.midY + lane),
                          control1: CGPoint(x: layout.midX + span / 3, y: layout.midY),
                          control2: CGPoint(x: layout.midX + span * 2 / 3, y: layout.midY + lane))
            path.addLine(to: CGPoint(x: layout.rightCenter, y: layout.midY + lane))
        }
        if !dashed { context.stroke(rail, with: .color(tint.opacity(style.dark ? 0.16 : 0.09)), lineWidth: 7) }
        context.stroke(rail, with: .color(tint.opacity(dashed ? 0.62 : 0.76)),
                       style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: dashed ? [4, 5] : []))
    }

    private func drawPulse(in context: GraphicsContext, layout: RouteLayout, lane: CGFloat, phase: Double, remote: Bool) {
        for step in 0..<14 {
            let progress = phase - Double(step) * 0.005
            guard progress > 0, progress < 1 else { continue }
            let headX = layout.leftCenter + (layout.rightCenter - layout.leftCenter) * (remote ? 1 - progress : progress)
            let branch = min(1, max(0, (headX - layout.midX) / max(1, layout.branchEnd - layout.midX)))
            let headY = layout.midY + lane * branch * branch * (3 - 2 * branch)
            let opacity = min(1, progress / 0.12, (1 - progress) / 0.12) * (1 - Double(step) / 14)
            let radius: CGFloat = step == 0 ? 3.0 : 1.15
            if step == 0 {
                let bloom = Path(ellipseIn: CGRect(x: headX - 7, y: headY - 7, width: 14, height: 14))
                context.fill(bloom, with: .radialGradient(Gradient(colors: [tint.opacity(0.48 * opacity), .clear]),
                    center: CGPoint(x: headX, y: headY), startRadius: 1, endRadius: 7))
            }
            let point = Path(ellipseIn: CGRect(x: headX - radius, y: headY - radius, width: 2 * radius, height: 2 * radius))
            context.fill(point, with: .color(tint.opacity(step == 0 ? opacity : opacity * 0.40)))
        }
    }

    /// A saved rule or observed entry can change even when its forwarding type stays the same.
    private struct PathIdentity: Hashable {
        let ruleID: String?
        let kind: ForwardingKind?
    }

    /// Cards stay pinned to the same three positions as the window narrows.
    private struct RouteLayout {
        let width: CGFloat
        let height: CGFloat
        var inset: CGFloat { width > 570 ? 11 : 2 }
        var midX: CGFloat { width / 2 }
        var midY: CGFloat { height / 2 }
        var leftWidth: CGFloat { min(151, width * 0.29) }
        var centerWidth: CGFloat { min(116, width * 0.23) }
        var rightWidth: CGFloat { min(172, width * 0.30) }
        var leftCenter: CGFloat { inset + leftWidth / 2 }
        var rightCenter: CGFloat { width - inset - rightWidth / 2 }
        var leftEdge: CGFloat { inset + leftWidth }
        var centerLeft: CGFloat { midX - centerWidth / 2 }
        var rightEdge: CGFloat { width - inset - rightWidth }
        var branchEnd: CGFloat { rightEdge - 22 }
    }
}
