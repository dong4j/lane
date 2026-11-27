# Contributing to Lane

Issues and pull requests are welcome in English or Simplified Chinese. Include your macOS and Lane versions, the forwarding type, and the steps to reproduce the behavior. Use example hosts, addresses, or credentials when sharing configuration or screenshots.

## Build and test

Use macOS 14 or later, a Swift 6 toolchain, and Python 3.

```sh
make run
swift test
./scripts/test-loopback.py
```

The loopback suite runs local OpenSSH and HTTP fixtures with temporary keys. To render native views with sample tunnels, build the Debug app with `make build`.

```sh
.build/Lane.app/Contents/MacOS/Lane --render-previews .build/previews -lane.language en
```

When changing the window, editor, or menu, check both appearance modes. The [design index](docs/README.md) links to the editable prototype and interaction notes. If changing Agent access, run the loopback suite and check that the pairing, request, and release behavior still matches the [MCP guide](docs/agent-mcp.md).

Keep pull requests focused. Explain the user-visible change and include the checks you ran. Put screenshots of UI changes in the PR description where they help explain the result.

## Source and assets

Lane contributions use the [MIT License](LICENSE). Keep the [Porthole notice](docs/Porthole-MIT.txt) with the reused code and the [Lucide and Feather notices](docs/design/Lucide-LICENSE.txt) with the design assets.
