import Foundation
import PortlaneCore
#if DEBUG
import AppKit
#endif

// OpenSSH invokes the same binary as a helper. Enter those modes before launching AppKit.
let arguments = CommandLine.arguments
if arguments.dropFirst().first == "--proxy-connect" {
    exit(ProxyHelper.run(Array(arguments.dropFirst(2))))
}
if arguments.dropFirst().first == AgentMCP.mode {
    exit(AgentMCP.run(Array(arguments.dropFirst(2))))
}
if ProcessInfo.processInfo.environment[AskpassEnvironment.socketPath] != nil {
    exit(AskpassHelper.run(prompt: arguments.dropFirst().joined(separator: " ")))
}

#if DEBUG
if arguments.dropFirst().first == "--render-previews", arguments.indices.contains(2) {
    // Render fixture views without starting services or claiming the live app's lock.
    _ = NSApplication.shared
    DebugPreviews.write(model: PortlaneModel(demo: true), directory: arguments[2])
    exit(EXIT_SUCCESS)
}
#endif

do {
    if try !PortlaneInstance.claim() {
        PortlaneInstance.activatePrimary()
        exit(EXIT_SUCCESS)
    }
} catch {
    NSLog("Lane: could not acquire the application lock: %@", error.localizedDescription)
    exit(EXIT_FAILURE)
}

// Resolve the language before displaying the first view so it stays fixed until the next launch.
_ = L10n.launchedLanguage
PortlaneApp.main()
