<p align="center">
  <img src="docs/screenshots/lane-icon.png" width="84" alt="Lane 应用图标">
</p>
<h1 align="center">Lane</h1>
<p align="center"><strong>macOS 原生 SSH 隧道管理工具</strong></p>
<p align="center">平时从菜单栏连接和复制地址。要配置转发、查看已有隧道或审批 Agent 申请时，再打开主窗口。</p>
<p align="center">
  <a href="README.md">English</a> ·
  <a href="#安装">安装</a> ·
  <a href="docs/usage.zh-CN.md">使用指南</a> ·
  <a href="docs/06-agent-mcp.md">Agent MCP</a>
</p>
<p align="center">
  <a href="https://github.com/dong4j/lane/actions/workflows/macos.yml"><img src="https://github.com/dong4j/lane/actions/workflows/macos.yml/badge.svg" alt="macOS CI"></a>
</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/main-dark.zh-CN.png">
  <img src="docs/screenshots/main-light.zh-CN.png" width="960" alt="Lane 主窗口显示从本机 PostgreSQL 入口经过 SSH 主机到数据库的转发路径">
</picture>

## Lane 可以做什么

- **菜单栏里连隧道、拿地址。** 主窗口关闭后仍可连接、断开和复制每条规则的入口。
- **看清连接往哪走。** 本地 `-L`、远程 `-R` 和动态 `-D` 转发各有路径图、方向动效和用途说明。
- **查看已经运行的 OpenSSH 转发。** 同一个 SSH 进程的多个入口归到一组。外部会话为只读，远端只有配置声明时会标为未核实。
- **让 Agent 通过 MCP 申请本地转发。** 开启 Agent 接入并复制客户端配置，即可在 Lane 里查看申请、结束连接并追溯历史。
- **继续使用现有配置。** 支持预览导入 `~/.ssh/config`、Lane 或 Porthole 备份，以及兼容的 Codinn 导出。Lane 使用 OpenSSH，已保存的凭据由 macOS 钥匙串管理。

| 菜单栏 | Agent 审批 |
| --- | --- |
| <img src="docs/screenshots/menu.zh-CN.png" width="294" alt="Lane 菜单栏面板，列出已保存的隧道和本机发现的会话"> | <img src="docs/screenshots/agent-approval.zh-CN.png" width="430" alt="Lane Agent 活动展示本机入口、SSH 主机、目标服务和批准或拒绝按钮"> |

截图来自 Lane 的原生界面，使用演示数据。应用支持浅色、深色、英文和简体中文。

## 安装

Lane 需要 **macOS 14 或更高版本**。Apple 芯片用户可登录 GitHub，打开一次成功的 [macOS CI 构建](https://github.com/dong4j/lane/actions/workflows/macos.yml?query=branch%3Amain)，从 **Artifacts** 下载 `Lane-macOS-arm64.zip`。CI 构建采用临时签名。如果 macOS 拦截下载版，可以在本机从源码构建。

本机源码构建使用 Swift 6。可以在终端运行以下命令。

```sh
git clone https://github.com/dong4j/lane.git
cd lane
make run
```

`make build` 可单独打包调试版到 `.build/Lane.app`。需要用 `make run` 启动刚构建的版本时，先退出当前运行的 Lane。

打开 Lane，选择「新建隧道」，填写 SSH 别名或主机名并添加转发。比如用本地转发在 `127.0.0.1:15432` 监听，将目标设为 SSH 主机可访问的 `db.internal:5432`。连接成功后，把本机地址复制到数据库客户端。远程转发、SOCKS5 和排障见[使用指南](docs/usage.zh-CN.md)。

## Agent MCP

打开「设置 → Agent 接入」，开启总开关后复制 **Codex**、**Claude Code** 的命令，或复制「通用 MCP」配置。通用方式提供 `mcpServers` JSON，也可以分别复制 `command` 和 `args`，填写到支持本机 stdio 的客户端。

Agent 接入默认关闭。开启后，Agent 可申请使用符合条件的已保存本机环回转发；临时目标和外部入口仍需在 Lane 审批。关闭开关会结束 Agent 的申请。[接入与工具说明](docs/06-agent-mcp.md)

## 贡献与许可

构建、回归测试和界面预览见[贡献指南](CONTRIBUTING.md)。安全问题请通过[私密渠道](SECURITY.md)报告。

Lane 采用 [MIT 许可](LICENSE)。部分 OpenSSH 核心代码和测试来自 [Porthole](https://github.com/bryan31/porthole)，其 [MIT 声明](docs/Porthole-MIT.txt)随源码和应用分发。设计原型另附 [Lucide 和 Feather 的许可](docs/design/Lucide-LICENSE.txt)。
