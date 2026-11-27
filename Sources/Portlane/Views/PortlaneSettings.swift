import AppKit
import SwiftUI

/// The settings window uses native form controls within Portlane's shared light and dark surfaces.
struct PortlaneSettings: View {
    private enum Page: CaseIterable {
        case general, connection, agent, data, about

        var title: String {
            switch self {
            case .general: L10n.text("General", "通用")
            case .connection: L10n.text("Connection", "连接")
            case .agent: L10n.text("Agent Access", "Agent 接入")
            case .data: L10n.text("Data", "数据")
            case .about: L10n.text("About", "关于")
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .connection: "link"
            case .agent: "point.3.connected.trianglepath.dotted"
            case .data: "externaldrive"
            case .about: "info.circle"
            }
        }
    }

    let model: PortlaneModel
    @State private var page: Page = .general
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let style = PortlaneStyle(scheme: scheme)
        VStack(spacing: 0) {
            pageButtons(style: style)
            Divider().overlay(style.edge)

            ZStack(alignment: .top) {
                Group {
                    switch page {
                    case .general: GeneralSettings(preferences: model.preferences, demo: model.demo)
                    case .connection: ConnectionSettings(preferences: model.preferences)
                    case .agent: AgentSettings(model: model)
                    case .data: DataSettings(model: model)
                    case .about: about
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(page)
                .transition(.opacity)
            }
            .animation(reduceMotion ? nil : LaneMotion.crossfade, value: page)
        }
        .frame(width: 592, height: 552)
        .background(style.window)
        .tint(style.accent)
    }

    private func pageButtons(style: PortlaneStyle) -> some View {
        HStack(spacing: 5) {
            ForEach(Page.allCases, id: \.self) { choice in
                let selected = choice == page
                Button {
                    page = choice
                } label: {
                    Label(choice.title, systemImage: choice.symbol)
                        .font(.callout.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? style.accent : style.secondary)
                        .frame(minWidth: 108, minHeight: 30)
                        .background(selected ? style.selected : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .modifier(LaneHoverHighlight())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(style.control, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Settings pages", "设置页面"))
        .padding(.vertical, 12)
    }

    /// A project link is supplied by the bundle when Portlane has a published homepage.
    private var about: some View {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let homepage = (bundle.object(forInfoDictionaryKey: "PortlaneProjectURL") as? String).flatMap(URL.init(string:))
        let license = bundle.url(forResource: "Porthole-MIT", withExtension: "txt")
        return VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 82, height: 82)
                .accessibilityHidden(true)
            Text("Portlane").font(.title.weight(.semibold))
            Text(L10n.text("Version \(version)", "版本 \(version)"))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(L10n.text("Manage SSH tunnels and copy forwarding addresses from the menu bar.",
                           "在菜单栏管理 SSH 隧道、复制转发地址。"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340)
                .padding(.top, 6)
            HStack(spacing: 12) {
                if let homepage {
                    Link(L10n.text("Project Homepage", "项目主页"), destination: homepage)
                }
                if let license {
                    Button(L10n.text("Third-Party License", "第三方许可证")) {
                        NSWorkspace.shared.open(license)
                    }
                    .buttonStyle(LaneButtonStyle())
                }
            }
            .padding(.top, 6)
        }
        .padding(34)
    }
}
