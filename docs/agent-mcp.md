# Agent access over MCP

[简体中文](06-agent-mcp.md) · [Home](../README.md)

Lane can open time-limited SSH local forwards for an Agent on the same Mac. The Agent requests a lease, waits for a ready address, uses it, and releases it. The user can review the route, stop a lease, and see the audit history inside Lane.

## Connect a client

1. Open **Settings → Agent** and turn on **Allow Agent access**. The switch is off by default.
2. Copy and run the **Codex** or **Claude Code** command, or copy the **Generic MCP** configuration into another local stdio client.
3. Reload the client's MCP configuration and call `lane_list` to verify the connection. Lane prepares the local client identity automatically; no separate pairing or per-client permission is needed.

While access is on, Agents can request any eligible saved loopback `-L` rule. Temporary destinations and external listeners still require approval. Turning access off blocks Agent tool calls and ends outstanding Agent leases.

### Generic stdio setup

Merge the generated entry into the client's `mcpServers` object. Lane fills the absolute paths for the installation and local client identity. Open **Manual MCP fields** to copy `command` and `args` separately.

```json
{
  "mcpServers": {
    "lane": {
      "command": "/Applications/Lane.app/Contents/MacOS/Lane",
      "args": ["--mcp-stdio", "--credential-file", "/absolute/path/to/client.pairing"]
    }
  }
}
```

| Field | Value |
| --- | --- |
| Transport | `stdio` |
| `command` | The absolute executable path from Lane |
| `args` | `--mcp-stdio`, `--credential-file`, then the absolute pairing file path |
| `env` | Empty when passing `--credential-file`. Alternatively, pass just `--mcp-stdio` and set `LANE_MCP_CREDENTIAL_FILE` to the pairing file path. |

Keep Lane running under the same macOS account as the client. Copy the recipe again after moving or renaming the app. The recipe points at a private pairing file. Any same-account process that can read that file can use the pairing.

## Tool calls

Lane supplies usage instructions during MCP initialization. You can also tell your Agent to use Lane for local SSH forwards and to release each lease after use.

| Tool | Use |
| --- | --- |
| `lane_list` | Return eligible loopback `rules`, saved SSH `profiles`, and `can_request`. |
| `lane_request` | Request a shared rule, a temporary destination, or an observed external listener. |
| `lane_status` | Poll with the returned `lease_id`. Use `lease.address` when `state` is `ready`. |
| `lane_release` | Release a lease from this pairing with `lease_id`. It is safe to retry. |

For a shared rule, use an ID from `lane_list`. Repeat the same `idempotency_key` and inputs to recover that request after a timeout. The client supplies the `purpose` and optional `project` fields. Keep credentials out of both.

```json
{
  "kind": "shared",
  "rule_id": "<shared-rule-id>",
  "idempotency_key": "preview-check-01",
  "project": "Preview",
  "purpose": "Check the preview service",
  "ttl_seconds": 900
}
```

- **Temporary destination.** Use `kind: "temporary"`, an ID from `lane_list` → `profiles` as `profile_id`, plus `listen_port`, `target_host`, and `target_port`. A saved profile can be selected even if it has no eligible loopback rule. The listener defaults to `127.0.0.1`. For IPv6, set `listen_host` to `::1`. The approval shows the local address, SSH host, and destination.
- **External listener.** Use `kind: "external"` and `external_address`, for example `127.0.0.1:3113`. Lane must observe a matching loopback `-L` listener. Approve each request. Releasing the lease ends the reference while the original process retains ownership of the listener.

A request opens only the selected loopback `-L` rule. Compatible requests can share the same established forward. The last lease closes a forward started for Agents. Manually connected tunnels remain open under the user's control. Changing a saved route ends affected Agent leases and refreshes the available rule.

Approval can take up to five minutes, and initial connection up to two minutes. The default lease lasts 15 minutes from first readiness. Supported durations are 1 to 3,600 seconds. While the route is reconnecting, wait for `ready` before using the address again.

## Review and troubleshoot

Open **Agent Activity** from the window or menu bar to approve, deny, copy a ready address, or end a lease. History is searchable by pairing, project, address, and request ID. It includes approval, connection, reuse, and end events.

The audit is local under `~/Library/Application Support/Lane/Agent/activity.json`. It contains route metadata and the client's stated purpose. Pairing credentials, SSH credentials, and forwarded traffic are stored or handled separately. Lane ends outstanding leases on quit and marks any left from an interrupted run as ended after restart.

| Response | What to check |
| --- | --- |
| `not_paired` | Copy the client's setup again and update its configuration. |
| `read_only` | Turn on **Allow Agent access** in Lane Settings. |
| `lane_unavailable` | Open Lane on this Mac, then retry. |
| `route_unavailable` | Verify the shared rule and the saved SSH profile. |
| `external_unverified` | Check the listener and arguments under Local discovery. |

The bundled stdio helper supports `server/discover` for MCP `2026-07-28` and `initialize` for revisions from `2024-11-05` through `2025-11-25`.
