import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// Appearance and presentation reflect shared app state. Login and notification status come from macOS.
struct GeneralSettings: View {
    @Bindable var preferences: LanePreferences
    let demo: Bool
    @State private var loginStatus: SMAppService.Status?
    @State private var loginError: String?
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var notificationError: String?

    private var systemServicesAvailable: Bool { !demo && TunnelNotifications.available }
    private var notificationsEnabled: Bool { preferences.notifyOnConnect || preferences.notifyOnFailure }

    var body: some View {
        Form {
            Section(L10n.text("Application", "应用")) {
                LabeledContent(L10n.text("Appearance", "外观")) {
                    Picker(L10n.text("Appearance", "外观"), selection: $preferences.appearance) {
                        Text(L10n.text("System", "跟随系统")).tag(LanePreferences.Appearance.system)
                        Text(L10n.text("Light", "浅色")).tag(LanePreferences.Appearance.light)
                        Text(L10n.text("Dark", "深色")).tag(LanePreferences.Appearance.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Picker(L10n.text("Language", "语言"), selection: $preferences.language) {
                    Text(L10n.text("System Default", "跟随系统")).tag(LanePreferences.Language.system)
                    Text("简体中文").tag(LanePreferences.Language.chinese)
                    Text("English").tag(LanePreferences.Language.english)
                }
                if preferences.language != L10n.launchedLanguage {
                    Text(L10n.text("The language changes the next time you open Lane.", "下次启动 Lane 时应用所选语言。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker(L10n.text("Show Lane in", "Lane 显示位置"), selection: $preferences.presentation) {
                    Text(L10n.text("Dock and Menu Bar", "程序坞与菜单栏")).tag(LanePreferences.Presentation.both)
                    Text(L10n.text("Dock Only", "仅程序坞")).tag(LanePreferences.Presentation.dockOnly)
                    Text(L10n.text("Menu Bar Only", "仅菜单栏")).tag(LanePreferences.Presentation.menuBarOnly)
                }
                loginItem
            }
            Section(L10n.text("Notifications", "通知")) {
                Toggle(L10n.text("When a tunnel connects", "连接成功时通知"), isOn: $preferences.notifyOnConnect)
                Toggle(L10n.text("On failure or unexpected disconnection", "连接失败或意外中断时通知"),
                       isOn: $preferences.notifyOnFailure)

                if notificationsEnabled, notificationStatus == .denied {
                    Text(L10n.text("Allow notifications for Lane in System Settings › Notifications.",
                                   "请在「系统设置 → 通知」中允许 Lane 发送通知。"))
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
            Toggle(L10n.text("Open Lane at login", "登录时启动 Lane"), isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                // Swift 6.2 crashes when it emits a direct reference to this actor-isolated setter.
                set: { enabled in setLoginItem(enabled) }
            ))
            .disabled(loginStatus == nil || loginStatus == .notFound)

            if loginStatus == .requiresApproval {
                LabeledContent(L10n.text("Waiting for approval", "等待系统批准")) {
                    SettingsActionButton(L10n.text("Open Login Items", "打开登录项")) { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }
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
