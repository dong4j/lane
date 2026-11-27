import CoreFoundation
import Foundation
import PortlaneCore

/// The bundled stdio mode negotiates MCP locally and forwards tool calls to the running app.
enum AgentMCP {
    static let name = "lane"
    static let mode = "--mcp-stdio"
    static let credentialOption = "--credential-file"
    static let credentialEnvironment = "LANE_MCP_CREDENTIAL_FILE"

    private static let modernRevision = "2026-07-28"
    private static let legacyRevisions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private static let protocolVersionKey = "io.modelcontextprotocol/protocolVersion"
    private static let clientCapabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    private static let serverInfoKey = "io.modelcontextprotocol/serverInfo"
    private static let serverInfo = ["name": name, "version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"]
    private static let capabilities: [String: [String: Bool]] = ["tools": [:]]
    static let projectInstructions = """
        Use Lane MCP for new local SSH forwardings. Start with lane_list and use lane_request with a stable \
        idempotency_key and a short purpose without secrets. Ask the user to approve temporary or external routes in Lane. \
        Poll lane_status and use the local address only when the lease is ready. Call lane_release when done. \
        If Lane is unavailable or refuses a request, report that to the user before using another SSH workflow.
        """

    /// This mode never launches AppKit. Every stdout line is a JSON-RPC response.
    static func run(_ arguments: [String]) -> Int32 {
        let credentialPath: String?
        if arguments.isEmpty {
            credentialPath = ProcessInfo.processInfo.environment[credentialEnvironment] ??
                ProcessInfo.processInfo.environment["PORTLANE_MCP_CREDENTIAL_FILE"]
        } else if arguments.count == 2, arguments[0] == credentialOption {
            credentialPath = arguments[1]
        } else {
            FileHandle.standardError.write(Data("Usage: Lane --mcp-stdio --credential-file <path>\n".utf8))
            return EXIT_FAILURE
        }
        let credential = credentialPath.flatMap { path -> AgentCredential? in
            guard path.hasPrefix("/"), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            return try? JSONDecoder().decode(AgentCredential.self, from: data)
        }
        var negotiatedLegacy: String?
        while let line = readLine() {
            if let reply = response(to: Data(line.utf8), credential: credential, negotiatedLegacy: &negotiatedLegacy),
               var data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys, .withoutEscapingSlashes]) {
                data.append(UInt8(ascii: "\n"))
                FileHandle.standardOutput.write(data)
            }
        }
        return EXIT_SUCCESS
    }

    private static func response(to data: Data, credential: AgentCredential?, negotiatedLegacy: inout String?) -> [String: Any]? {
        guard let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return rpcError(id: NSNull(), code: -32700, message: "Parse error")
        }
        guard let message = decoded as? [String: Any], message["jsonrpc"] as? String == "2.0",
              let method = message["method"] as? String else {
            return rpcError(id: NSNull(), code: -32600, message: "Invalid request")
        }
        guard let id = message["id"] else { return nil }
        let number = id as? NSNumber
        let integerID = number.map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.rounded(.towardZero) == $0.doubleValue } ?? false
        guard id is String || integerID else {
            return rpcError(id: NSNull(), code: -32600, message: "Invalid request ID")
        }
        let parameters = message["params"] as? [String: Any] ?? [:]
        let metadata = parameters["_meta"] as? [String: Any] ?? [:]
        let modern = method == "server/discover" || metadata[protocolVersionKey] != nil ||
            metadata[clientCapabilitiesKey] != nil || (negotiatedLegacy == nil && method != "initialize" && method != "ping")
        if modern {
            guard let version = metadata[protocolVersionKey] as? String,
                  metadata[clientCapabilitiesKey] is [String: Any] else {
                return rpcError(id: id, code: -32602, message: "MCP protocol version and client capabilities are required")
            }
            guard version == modernRevision else {
                return ["jsonrpc": "2.0", "id": id, "error": [
                    "code": -32022, "message": "Unsupported protocol version",
                    "data": ["supported": [modernRevision] + legacyRevisions, "requested": version],
                ]]
            }
        }
        var result: [String: Any]
        switch method {
        case "server/discover":
            result = ["supportedVersions": [modernRevision], "capabilities": capabilities, "instructions": projectInstructions]
        case "initialize":
            guard !modern, let requested = parameters["protocolVersion"] as? String else {
                return rpcError(id: id, code: -32602, message: "A protocol version is required")
            }
            let version = legacyRevisions.contains(requested) ? requested : legacyRevisions[0]
            negotiatedLegacy = version
            result = [
                "protocolVersion": version,
                "serverInfo": serverInfo,
                "capabilities": capabilities,
                "instructions": projectInstructions,
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": AgentTool.allCases.map(\.definition)]
        case "tools/call":
            guard let name = parameters["name"] as? String, let tool = AgentTool(mcpName: name) else {
                return rpcError(id: id, code: -32602, message: "Unknown tool")
            }
            if let arguments = parameters["arguments"], !(arguments is [String: Any]) {
                return rpcError(id: id, code: -32602, message: "Tool arguments must be an object")
            }
            let reply = call(tool, arguments: parameters["arguments"] as? [String: Any] ?? [:], credential: credential)
            guard let payload = try? AgentToolResult.encoder().encode(reply),
                  let structured = try? JSONSerialization.jsonObject(with: payload) else {
                return rpcError(id: id, code: -32603, message: "Could not encode tool result")
            }
            result = [
                "content": [["type": "text", "text": String(decoding: payload, as: UTF8.self)]],
                "isError": reply.error != nil,
            ]
            if modern || (negotiatedLegacy ?? "") >= "2025-06-18" { result["structuredContent"] = structured }
        default:
            return rpcError(id: id, code: -32601, message: "Method not found")
        }
        if modern {
            result["_meta"] = [serverInfoKey: serverInfo]
            if method != "ping" { result["resultType"] = "complete" }
            if method == "server/discover" || method == "tools/list" {
                result["cacheScope"] = "public"
                result["ttlMs"] = 3_600_000
            }
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func call(_ tool: AgentTool, arguments: [String: Any], credential: AgentCredential?) -> AgentToolResult {
        do {
            guard let credential else { throw AgentToolError.notPaired }
            let input = try tool.decode(arguments)
            return try AgentIPC.send(AgentToolCall(credential: credential, tool: tool, arguments: input))
        } catch let error as AgentToolError {
            return AgentToolResult(error: error)
        } catch {
            return AgentToolResult(error: .unavailable)
        }
    }

    private static func rpcError(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}

/// Every client-specific recipe and the generic fields are generated from the same launch vector.
struct AgentMCPConfiguration: Sendable {
    let executable: String
    let credentialFile: String

    var args: [String] { [AgentMCP.mode, AgentMCP.credentialOption, credentialFile] }
    var codexCommand: String { "codex mcp add \(AgentMCP.name) -- \(shellCommand)" }
    var claudeCommand: String { "claude mcp add --transport stdio --scope user \(AgentMCP.name) -- \(shellCommand)" }
    var argsJSON: String { Self.json(args) }
    var json: String { Self.json(["mcpServers": [AgentMCP.name: ["command": executable, "args": args]]]) }
    var cursorJSON: String {
        Self.json(["mcpServers": [AgentMCP.name: ["type": "stdio", "command": executable, "args": args]]])
    }

    private var shellCommand: String { ([executable] + args).map(SSHCommandBuilder.shellQuote).joined(separator: " ") }

    private static func json(_ object: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Exercise the generated launch vector, both negotiation modes, and an authenticated list.
    func check() async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let messages = """
                {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"lane-check","version":"1"}}}
                {"jsonrpc":"2.0","method":"notifications/initialized"}
                {"jsonrpc":"2.0","id":2,"method":"tools/list"}
                {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"lane_list","arguments":{}}}
                {"jsonrpc":"2.0","id":4,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
                {"jsonrpc":"2.0","id":5,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
                """
            try input.fileHandleForWriting.write(contentsOf: Data((messages + "\n").utf8))
            try input.fileHandleForWriting.close()
            let response = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let results = String(decoding: response, as: UTF8.self).split(separator: "\n").compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }
            guard process.terminationStatus == 0, results.count == 5,
                  (results[0]["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25",
                  let definitions = (results[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]],
                  Set(definitions.compactMap { $0["name"] as? String }) == Set(AgentTool.allCases.map(\.mcpName)),
                  let result = results[2]["result"] as? [String: Any],
                  let structured = result["structuredContent"] as? [String: Any],
                  let discovery = results[3]["result"] as? [String: Any],
                  discovery["supportedVersions"] as? [String] == ["2026-07-28"],
                  discovery["resultType"] as? String == "complete",
                  let modernList = results[4]["result"] as? [String: Any],
                  modernList["resultType"] as? String == "complete",
                  modernList["ttlMs"] is Int,
                  modernList["cacheScope"] as? String == "public" else { throw AgentToolError.unavailable }
            if let error = structured["error"] as? [String: Any], let code = error["code"] as? String,
               let message = error["message"] as? String { throw AgentToolError(code: code, message: message) }
            guard let canRequest = structured["can_request"] as? Bool else { throw AgentToolError.unavailable }
            return canRequest
        }.value
    }
}
