import AppKit
import SwiftUI

/// Both app surfaces use the same SwiftUI state and AppKit process lifetime.
struct PortlaneApp: App {
    @NSApplicationDelegateAdaptor(PortlaneDelegate.self) private var delegate
    @AppStorage("portlane.appearance") private var appearance = "system"

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some Scene {
        Window("Portlane", id: "main") {
            MainWindow(model: delegate.model)
                .preferredColorScheme(preferredScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("New Tunnel", "新建隧道")) { delegate.model.newTunnel() }
                    .keyboardShortcut("n")
                Button(L10n.text("Import SSH Configuration…", "导入 SSH 配置…")) { delegate.model.previewSSHConfig() }
            }
        }

        MenuBarExtra {
            LaneMenuBar(model: delegate.model)
                .preferredColorScheme(preferredScheme)
        } label: {
            Image(systemName: delegate.model.manager.connectedCount > 0 ? "point.3.connected.trianglepath.dotted" : "arrow.left.arrow.right")
                .accessibilityLabel("Portlane")
        }
        .menuBarExtraStyle(.window)

        Settings {
            Form {
                Picker(L10n.text("Appearance", "外观"), selection: $appearance) {
                    Text(L10n.text("System", "跟随系统")).tag("system")
                    Text(L10n.text("Light", "浅色")).tag("light")
                    Text(L10n.text("Dark", "深色")).tag("dark")
                }
                Button(L10n.text("Refresh Local Discovery", "刷新本机发现")) { delegate.model.refreshDiscovery() }
            }
            .formStyle(.grouped)
            .padding(8)
            .frame(width: 410, height: 170)
            .preferredColorScheme(preferredScheme)
        }
    }
}

/// Closing the main window leaves the menu bar and its owned sessions alive.
@MainActor
final class PortlaneDelegate: NSObject, NSApplicationDelegate {
    let model = PortlaneModel(demo: CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--render-previews"))

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
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
        model.manager.startServices()
        model.refreshDiscovery()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model.manager.shutdown()
    }
}
