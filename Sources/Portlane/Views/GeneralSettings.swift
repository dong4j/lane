import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// Appearance and presentation reflect shared app state. Login and notification status come from macOS.
struct GeneralSettings: View {
    @Bindable var preferences: PortlanePreferences
    let demo: Bool
    @State private var loginStatus: SMAppService.Status?
    @State private var loginError: String?
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var notificationError: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var systemServicesAvailable: Bool { !demo && TunnelNotifications.available }
    private var notificationsEnabled: Bool { preferences.notifyOnConnect || preferences.notifyOnFailure }

    var body: some View {
        Form {
            Section(L10n.text("Appearance", "外观")) {
                HStack(spacing: 10) {
                    ForEach(PortlanePreferences.Appearance.allCases, id: \.self, content: appearanceCard)
                }
                .padding(.vertical, 4)
            }
            Section(L10n.text("Application", "应用")) {
                Picker(L10n.text("Language", "语言"), selection: $preferences.language) {
                    Text(L10n.text("System Default", "跟随系统")).tag(PortlanePreferences.Language.system)
                    Text("简体中文").tag(PortlanePreferences.Language.chinese)
                    Text("English").tag(PortlanePreferences.Language.english)
                }
                if preferences.language != L10n.launchedLanguage {
                    Text(L10n.text("The language changes the next time you open Portlane.", "下次启动 Portlane 时应用所选语言。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker(L10n.text("Show Portlane in", "Portlane 显示位置"), selection: $preferences.presentation) {
                    Text(L10n.text("Dock and Menu Bar", "程序坞与菜单栏")).tag(PortlanePreferences.Presentation.both)
                    Text(L10n.text("Dock Only", "仅程序坞")).tag(PortlanePreferences.Presentation.dockOnly)
                    Text(L10n.text("Menu Bar Only", "仅菜单栏")).tag(PortlanePreferences.Presentation.menuBarOnly)
                }
                loginItem
            }
            Section(L10n.text("Notifications", "通知")) {
                Toggle(L10n.text("When a tunnel connects", "连接成功时通知"), isOn: $preferences.notifyOnConnect)
                Toggle(L10n.text("On failure or unexpected disconnection", "连接失败或意外中断时通知"),
                       isOn: $preferences.notifyOnFailure)

                if notificationsEnabled, notificationStatus == .denied {
                    Text(L10n.text("Allow notifications for Portlane in System Settings › Notifications.",
                                   "请在「系统设置 → 通知」中允许 Portlane 发送通知。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let notificationError, notificationsEnabled {
                    Text(notificationError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .task { await refreshSystemStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshSystemStatus() }
        }
        .onChange(of: notificationsEnabled) { _, enabled in
            guard enabled, systemServicesAvailable else { return }
            Task { await requestNotifications() }
        }
    }

    private var loginItem: some View {
        Group {
            Toggle(L10n.text("Open Portlane at login", "登录时启动 Portlane"), isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: setLoginItem
            ))
            .disabled(loginStatus == nil || loginStatus == .notFound)

            if loginStatus == .requiresApproval {
                LabeledContent(L10n.text("Waiting for approval", "等待系统批准")) {
                    Button(L10n.text("Open Login Items", "打开登录项")) { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func appearanceCard(_ choice: PortlanePreferences.Appearance) -> some View {
        let style = PortlaneStyle(scheme: scheme)
        let selected = preferences.appearance == choice
        let title = switch choice {
        case .system: L10n.text("System", "跟随系统")
        case .light: L10n.text("Light", "浅色")
        case .dark: L10n.text("Dark", "深色")
        }
        return Button {
            preferences.appearance = choice
        } label: {
            VStack(spacing: 8) {
                AppearanceSample(appearance: choice)
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(selected ? style.accent : style.text)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(style.accent)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .padding(9)
            .frame(maxWidth: .infinity)
            .background(selected ? style.selected : style.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? style.accent : style.edge) }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(reduceMotion ? nil : LaneMotion.crossfade, value: selected)
    }

    /// Use the service's status after each write, including when approval is still pending.
    private func setLoginItem(_ enabled: Bool) {
        guard systemServicesAvailable else { return }
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = service.status
    }

    private func refreshSystemStatus() async {
        guard systemServicesAvailable else { return }
        loginStatus = SMAppService.mainApp.status
        notificationStatus = await TunnelNotifications.authorizationStatus()
    }

    private func requestNotifications() async {
        do {
            try await TunnelNotifications.requestPermission()
            notificationError = nil
        } catch {
            notificationError = error.localizedDescription
        }
        notificationStatus = await TunnelNotifications.authorizationStatus()
    }
}

/// A miniature library and route render directly from the same palette as the main window.
private struct AppearanceSample: View {
    let appearance: PortlanePreferences.Appearance

    var body: some View {
        ZStack {
            miniature(appearance == .dark ? .dark : .light)
            if appearance == .system {
                miniature(.dark)
                    .mask {
                        HStack(spacing: 0) {
                            Color.clear
                            Rectangle()
                        }
                    }
            }
        }
        .frame(width: 120, height: 54)
        .accessibilityHidden(true)
    }

    private func miniature(_ scheme: ColorScheme) -> some View {
        let style = PortlaneStyle(scheme: scheme)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                ForEach([0xE37F82, 0xD8AD62, 0x6EAD96], id: \.self) { rgb in
                    Circle().fill(Color(rgb: rgb)).frame(width: 4, height: 4)
                }
            }
            HStack(spacing: 6) {
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(style.selected).frame(height: 7)
                    RoundedRectangle(cornerRadius: 2).fill(style.edge).frame(height: 4)
                    Spacer(minLength: 0)
                }
                .padding(4)
                .frame(width: 27)
                .background(style.sidebar, in: RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(style.secondary).frame(width: 23, height: 3)
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 2).fill(style.selected).frame(width: 12, height: 8)
                        Rectangle().fill(style.accent).frame(height: 1)
                        RoundedRectangle(cornerRadius: 2).fill(style.selected).frame(width: 12, height: 8)
                    }
                    .padding(4)
                    .background(style.routeSurface, in: RoundedRectangle(cornerRadius: 3))
                }
            }
        }
        .padding(6)
        .background(style.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(style.edge) }
    }
}
