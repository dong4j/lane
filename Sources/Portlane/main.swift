import Foundation
import PortlaneCore

// OpenSSH invokes the same binary as a helper. Enter those modes before launching AppKit.
let arguments = CommandLine.arguments
if arguments.dropFirst().first == "--proxy-connect" {
    exit(ProxyHelper.run(Array(arguments.dropFirst(2))))
}
if ProcessInfo.processInfo.environment[AskpassEnvironment.socketPath] != nil {
    exit(AskpassHelper.run(prompt: arguments.dropFirst().joined(separator: " ")))
}
PortlaneApp.main()
