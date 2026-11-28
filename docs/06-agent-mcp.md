# Agent 接入与审计

[English](agent-mcp.md) · [主页](../README.zh-CN.md)

Lane 可以为本机 Agent 建立 SSH 本地转发。Agent 请求限时使用隧道，拿到就绪地址后继续工作，完成时释放。用户可在「Agent 活动」中查看当前会话和历史，也可从菜单栏复制地址或结束使用。

## 接入客户端

1. 启动 Lane，打开「设置 → Agent 接入」，开启「允许 Agent 接入」。该开关默认关闭。
2. 复制并运行 Codex 或 Claude Code 的接入命令；其他支持本机 stdio 的客户端使用「通用 MCP」配置。
3. 让客户端重新加载 MCP 配置，并调用 `lane_list` 检查接入。Lane 会自动准备客户端身份，无需手动配对或分别开启权限。

开启后，Agent 可使用符合条件的已保存环回 `-L` 规则、通过已配置的 SSH 主机建立临时环回转发，或引用已核实的外部入口。关闭开关会阻止 Agent 工具调用并结束当前 Agent 会话。

### 通用 MCP 配置

点击「通用 MCP」旁的「复制配置」，把其中的 `lane` 条目合并到客户端的 `mcpServers` 对象中。Lane 会填好可执行文件和本机配对文件的绝对路径。

```json
{
  "mcpServers": {
    "lane": {
      "command": "/Applications/Lane.app/Contents/MacOS/Lane",
      "args": [
        "--mcp-stdio",
        "--credential-file",
        "/absolute/path/to/client.pairing"
      ]
    }
  }
}
```

如需通过环境变量传入配对文件路径，可设置 `LANE_MCP_CREDENTIAL_FILE`，`args` 只保留 `--mcp-stdio`。

助手随应用打包，由 MCP 客户端拉起。Lane 主程序需要在该 Mac 的同一 macOS 用户下运行。移动应用后重新复制接入配置。配对文件位于用户私有目录，复制出的配置只有文件路径。能在同一 macOS 用户下读取该配对文件的进程可代表该配对身份调用。

## Agent 怎么使用

Lane 在 MCP 初始化时提供使用说明。也可以在项目指令中要求 Agent 优先使用 Lane 开启本地 SSH 转发，完成任务后释放申请。一次工具调用超时后，用相同的 `idempotency_key` 和参数重试，可以取回同一份申请。

| 工具 | 操作 |
| --- | --- |
| `lane_list` | 列出环回规则 `rules` 及其 `listen_address`、已保存的 SSH 配置 `profiles` 和 `can_request`。传入 `include_external: true` 可查看已核实的外部环回 `-L` 入口。 |
| `lane_request` | 申请使用共享规则、临时目标或已确认的外部入口，返回申请编号和当前状态。 |
| `lane_status` | 以 `lease_id` 查询本配对的申请。状态为 `ready` 时，`lease.address` 可用于连接，`expires_at` 为到期时间。 |
| `lane_release` | 以 `lease_id` 释放本配对的申请，可重复调用。 |

共享规则示例中的 `rule_id` 取自 `lane_list`。`project` 可选。这两个字段分别记录客户端提供的项目和用途，供查看活动和历史时参考，填写时应排除凭据。

```json
{
  "kind": "shared",
  "rule_id": "<shared-rule-id>",
  "idempotency_key": "preview-check-01",
  "project": "Preview",
  "purpose": "检查本机预览环境",
  "ttl_seconds": 900
}
```

- **临时目标**用 `kind: "temporary"`，从 `lane_list` 返回的 `profiles` 中选一个 ID 填入 `profile_id`，再填 `listen_port`、`target_host` 和 `target_port`。没有环回规则的已保存配置也可选择，认证沿用该 SSH 配置。监听默认 `127.0.0.1`，可设 `listen_host: "::1"`。
- **外部入口**用 `kind: "external"`，把 `lane_list` 传入 `{"include_external": true}` 后返回的 `listen_address` 填入 `external_address`，例如 `127.0.0.1:3113`。Lane 会重新核实监听。释放、到期或人工结束只解除引用，外部 SSH 继续由原进程管理。

申请只启动选中的环回 `-L` 规则。Agent 和手动连接匹配同一条规则时复用现有监听。选「保持连接」会同时打开配置中的其他启用规则，最后一个 Agent 释放后手动连接继续运行。转发路径或 SSH 配置改动后，Lane 会结束受影响的申请并刷新可用规则。

新建连接时先返回 `connecting`，首次连接最多等待 2 分钟，重连期间返回 `reconnecting`。TTL 默认 15 分钟，从首次就绪开始计时，支持 1 到 3,600 秒。就绪表示 OpenSSH 已确认监听，目标服务是否可用由客户端按实际任务验证。

## 审计和排障

- 从主窗口或菜单栏打开「Agent 活动」。「使用中」可复制地址或结束使用。「历史」支持按客户端、项目、SSH 主机、目标、入口或申请编号查找，展开可看失败发生在哪一步。
- 记录保存在 `~/Library/Application Support/Lane/Agent/activity.sqlite3`。旧的 `activity.json` 会导入一次并保留原文件。通用 MCP 的客户端名称标为「客户端自报」，鉴权沿用本机配对凭据。
- Agent 审计记录管理动作和路径元数据。SSH 凭据仍由 macOS 钥匙串及 OpenSSH 管理，配对密钥、业务流量和 OpenSSH 运行日志分别处理。
- 正常退出会结束当前申请并关闭 Lane 管理的 SSH。重启可查询历史，上一进程留下的未结申请会标为已结束。异常退出后若仍观察到 SSH 监听，可以在「本机发现」核查。
- `read_only` 表示 Agent 接入未开启。`not_paired` 表示客户端身份文件缺失或无效，需要重新复制接入配置。`lane_unavailable` 表示需要在本机启动 Lane。`route_unavailable` 时核对已保存的规则或 SSH 配置。`external_unverified` 时在「本机发现」核对监听和转发参数。
- `local_port_in_use` 表示本机监听端口冲突。`authentication_failed` 时检查 SSH 密钥或登录凭据。用相同幂等键重试同一份失败请求时会返回原结果，修正后用新的键重新连接。

stdio 支持 `2026-07-28` 的 `server/discover`，以及从 `2024-11-05` 到 `2025-11-25` 的 `initialize` 握手。客户端接入格式可查阅 [MCP stdio](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio)、[Codex MCP](https://developers.openai.com/codex/mcp)、[Claude Code MCP](https://code.claude.com/docs/en/mcp) 和 [Cursor MCP](https://cursor.com/docs/context/mcp)。
