import AppKit
import SwiftUI
import UserNotifications

/// Both app surfaces use the same SwiftUI state and AppKit process lifetime.
struct PortlaneApp: App {
    @NSApplicationDelegateAdaptor(PortlaneDelegate.self) private var delegate

    private var preferences: PortlanePreferences { delegate.model.preferences }

    private var preferredScheme: ColorScheme? {
        switch preferences.appearance {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }

    private var menuBarVisible: Binding<Bool> {
        Binding(
            get: { preferences.presentation != .dockOnly },
            set: { inserted in
                // Removing the status item in macOS leaves a Dock entry to recover Settings.
                if !inserted, preferences.presentation != .dockOnly { preferences.presentation = .dockOnly }
            }
        )
    }

    var body: some Scene {
        Window("Portlane", id: "main") {
            MainWindow(model: delegate.model)
                .preferredColorScheme(preferredScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 620)
        .windowResizability(.contentMinSize)
        .onChange(of: preferences.presentation) { delegate.applyPresentation() }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("New Tunnel", "新建隧道")) {
                    delegate.model.showMainWindow()
                    delegate.model.newTunnel()
                }
                .keyboardShortcut("n")
                Button(L10n.text("Import SSH Configuration…", "导入 SSH 配置…")) {
                    delegate.model.showMainWindow()
                    delegate.model.previewSSHConfig()
                }
            }
        }

        MenuBarExtra(isInserted: menuBarVisible) {
            LaneMenuBar(model: delegate.model)
                .preferredColorScheme(preferredScheme)
        } label: {
            Image(systemName: delegate.model.manager.hasConnectedSession ? "point.3.connected.trianglepath.dotted" : "arrow.left.arrow.right")
                .accessibilityLabel("Portlane")
        }
        .menuBarExtraStyle(.window)

        Settings {
            PortlaneSettings(model: delegate.model)
                .preferredColorScheme(preferredScheme)
        }
    }
}

/// Closing the main window leaves the menu bar and its owned sessions alive.
@MainActor
final class PortlaneDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = PortlaneModel(demo: CommandLine.arguments.contains {
        ["--demo", "--render-previews", "--menu-layout-check"].contains($0)
    })

    func applicationWillFinishLaunching(_ notification: Notification) {
        applyPresentation()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(activateExistingInstance(_:)), name: PortlaneInstance.activation,
            object: PortlaneInstance.user, suspensionBehavior: .deliverImmediately
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let option = CommandLine.arguments.firstIndex(of: "--render-previews"),
           CommandLine.arguments.indices.contains(option + 1) {
            DebugPreviews.write(model: model, directory: CommandLine.arguments[option + 1])
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--menu-layout-check") {
            DebugPreviews.showMenuHarness(model: model)
            return
        }
        #endif
        if !model.demo, TunnelNotifications.available {
            UNUserNotificationCenter.current().delegate = self
            model.agents.approvalNeeded = {
                TunnelNotifications.post(title: L10n.text("An Agent tunnel needs approval", "有一条 Agent 隧道待审批"),
                                         body: L10n.text("Review the route in Portlane.", "请在 Portlane 中确认转发路径。"),
                                         category: TunnelNotifications.agentApproval)
            }
        }
        model.agents.start()
        model.manager.startServices()
        model.manager.connectOnLaunch()
        model.refreshDiscovery()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard model.openMainWindow != nil else { return true }
        model.showMainWindow()
        return false
    }

    /// Both Finder and a rejected second process can restore the existing SwiftUI scene.
    @objc private func activateExistingInstance(_ notification: Notification) {
        model.showMainWindow()
    }

    func applyPresentation() {
        NSApp.setActivationPolicy(model.preferences.presentation == .menuBarOnly ? .accessory : .regular)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.notification.request.content.categoryIdentifier == TunnelNotifications.agentApproval {
            await model.showAgentActivity()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        model.agents.shutdown()
        model.manager.shutdown()
    }
}
