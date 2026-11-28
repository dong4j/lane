# Lane 发布验收

正式安装包面向 macOS 14 或更高版本的 Apple 芯片 Mac。GitHub Release 提供 `Lane-<version>-macOS-arm64.zip` 和 `SHA256SUMS.txt`。

## 构建与自动验收

用 Swift 6 和 Python 3.12 运行与 CI 相同的测试。测试使用临时 OpenSSH 密钥和回环 HTTP 服务。

```sh
python3.12 -m venv .build/mcp-test
source .build/mcp-test/bin/activate
python3 -m pip install mcp==1.26.0
make build
LANE_TEST_MCP_HELPER="$PWD/.build/Lane.app/Contents/MacOS/Lane" \
LANE_TEST_MCP_CLIENT="$PWD/scripts/test-mcp-client.py" \
./scripts/test-loopback.py
```

MCP 测试使用设置页复制的通用 JSON 启动打包助手。两份客户端会话分别走共享规则和外部入口，验证四个工具、取址、实际访问、释放和审计来源。

生成和校验本地打包产物可运行下面的命令。正式发布任务会用 Git 标签校对包内版本。

```sh
./scripts/build-app.sh release
sh scripts/package-release.sh
(cd .build/dist && shasum -a 256 -c SHA256SUMS.txt)
```

## 首次配置发布

在 GitHub Actions 的 `release` 环境中配置以下机密。

| Secret | 内容 |
| --- | --- |
| `LANE_DEVELOPER_ID_P12` | 包含 Developer ID Application 证书和私钥的 Base64 编码 `.p12` |
| `LANE_DEVELOPER_ID_PASSWORD` | 导出 `.p12` 时使用的密码 |
| `LANE_NOTARY_APPLE_ID` | 用于提交 Apple 公证的账号 |
| `LANE_NOTARY_APP_PASSWORD` | 该账号的 App 专用密码 |
| `LANE_NOTARY_TEAM_ID` | Apple Developer Team ID |

核对 `scripts/Info.plist` 中的版本号和构建号。推送匹配的 `v<version>` 标签会触发 CI、Developer ID 签名、公证和 GitHub Release。公证完成后，工作流把票据装订到 `.app`，校验 Gatekeeper 结果，再重新打包并计算公开安装包的校验值。

## 真机清单

每次发布记录版本、macOS 版本、架构和实测结果。在最低支持的 macOS 和当前使用的 macOS 上分别走查。

- [ ] 从公开 Release 下载，核对 SHA-256，解压进「应用程序」，首次打开后能保存隧道、打开菜单和复制 MCP 配置。配置中的可执行路径应指向实际安装位置。
- [ ] 浅色、深色分别检查菜单弹框。覆盖空列表、外部会话、多规则展开及滚动，顶部标题和底部入口完整可见，背景不透出桌面。
- [ ] 点击整行与右侧箭头都能展开和收起。单独点击复制、连接和断开时，折叠状态保持，剪贴板包含所选规则的正确地址。
- [ ] 用 Tab 在菜单、设置和编辑器内移动焦点。焦点应可辨认，失效监听地址应打开「高级选项」并把光标放到「监听地址」。
- [ ] 用 VoiceOver 读取展开状态、规则名称、服务器入口和各个复制操作。开启「减少动态效果」后，三类路径保留方向说明，停止循环动画。
- [ ] 让一条手动隧道和一个 Agent 会话就绪，睡眠并唤醒 Mac。按连接设置验证恢复行为，核对重连状态和实际端口，释放后确认外部 SSH 仍在运行。
