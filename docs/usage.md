# Using Lane

[简体中文](usage.zh-CN.md) · [Home](../README.md) · [Agent MCP](agent-mcp.md)

## Start with a local forward

In the main window, choose **New Tunnel** and enter an SSH alias or hostname. An alias can use the credentials, jump hosts, and connection options in your existing OpenSSH configuration.

| Rule | Where the client connects | Where the destination is reached |
| --- | --- | --- |
| Local `-L` | A port on this Mac, for example `127.0.0.1:15432` | A fixed service from the SSH host, for example `db.internal:5432` |
| Remote `-R` | A port on the SSH server, for example its `127.0.0.1:18080` | A fixed service from this Mac, for example `127.0.0.1:3000` |
| Dynamic `-D` | A SOCKS5 proxy on this Mac, for example `127.0.0.1:1080` | Each destination selected by the client, reached from the SSH host |

Choose **Save and Connect**, or save and connect later from the menu. Lane opens one SSH connection for a profile and applies its enabled rules. The path diagram shows where the connection starts and labels the SSH-encrypted leg. If you only need a local client to access a rule, use a loopback binding such as `127.0.0.1`. Remote listener visibility is subject to the SSH server's policy.

**Connected** means SSH and the forwarding rules are ready. To test the destination, make a request from the actual client, such as a database query, HTTP request, or SOCKS5-aware connection.

## Use the menu bar

The menu bar can connect and disconnect saved profiles, copy individual addresses, and reopen the main window. Expand a profile with multiple entrances to choose which one to copy. The command for a failed connection opens the affected profile in the main window.

**Local discovery** shows SSH processes owned by the current macOS user when Lane can observe a relevant forwarding. Lane groups listeners by process and correlates them with the SSH arguments when available. If a remote forward has no locally verifiable listener, the requested address is shown as unverified. Use the original tool or terminal to change or stop a discovered session.

## Import, export, and preferences

Under **Settings → Data**, preview aliases with explicit forwarding rules from `~/.ssh/config` or import a supported backup. Select the entries you want to add. Export writes a configuration document. Credentials stay in Keychain.

**General** includes appearance, language, menu bar and Dock visibility, launch at login, and notifications. Language changes take effect after restarting Lane. **Connection** includes wake behavior and a custom OpenSSH executable. Configure automatic connection separately for each profile in its editor.

## Diagnose a connection

1. Check **Diagnostics & Logs** for the SSH command, authentication stage, and recent events.
2. If a listener is occupied, open the affected rule, choose a different port or release the existing one, then retry.
3. For a first-time SSH host key, verify the fingerprint against a trusted source before accepting it. For a changed fingerprint, check with the server administrator.
4. If Lane shows **Connected** and the application reports an error, test that the destination is reachable from the machine shown on the route diagram.

## Local data and the earlier app name

Lane keeps the existing app identity from its Portlane development builds. Saved tunnels are under `~/Library/Application Support/Portlane/tunnels.json`. Previously saved settings, Keychain references, and Agent pairings use the same identity. If you were using a pre-release build or moved the app, copy the MCP recipe again so your client uses the path to `Lane.app`.

Try the UI with sample data by quitting the running app and starting the bundled app with `--demo`.

```sh
open .build/Lane.app --args --demo
```

The demo keeps example tunnels and preferences in memory. In normal use, closing the main window keeps tunnels running. Quitting Lane ends its managed connections and leases. Externally owned SSH sessions continue until their owner ends them.
