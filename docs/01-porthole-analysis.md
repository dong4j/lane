# Porthole 项目分析

Porthole 最值得借鉴的是一条 SSH 连接可以承载多条转发，并能区分进程启动、等待认证、监听就绪和重连。重新设计界面时，优先保留这些行为。日常最值得缩短的是从“隧道已连接”到“把地址粘进客户端”这一段。上游已经能复制地址，这次的产品机会是让用户在菜单栏就能完成它。[项目说明][readme] · [规则行][rule-row] · [菜单栏][menu]

## 核查基线

| 项目 | 核查结果 |
| --- | --- |
| 源码 | 2026 年 11 月 27 日核查 `main`，固定在 [`e6fa8c2`][commit]。以下源码链接均指向该提交。 |
| 发布物 | 当日 GitHub Releases 的标签为 `release`，附件为 `Porthole-1.0.0.zip` 和校验文件，发布于 2026 年 11 月 26 日。分析使用的是上述主分支提交。[发布记录][release] |
| 平台与构建 | 上游分发面向 Apple silicon、macOS 14 及以上。SwiftPM 工具版本 6.0，包内 Swift 语言模式为 5。包只声明一个可执行产品，内部另有 `PortholeCore` target。[包清单][package] · [安装与构建说明][readme] |
| 本机核查 | 在独立的上游副本运行 `./scripts/test.sh`。10 种界面语言的检查通过，Swift Testing 的 10 个套件、39 项测试全部通过。覆盖命令构建、转发规则、校验、日志解析、凭据提示分类、代理握手、导入和序列化等。[测试入口][test-script] · [用例][tests] |
| 界面证据 | 对照上游简中详情、编辑器和菜单栏的官方样例截图及其 SwiftUI 源码。未登录真实 SSH 服务，未实测网络恢复、指纹弹窗、VoiceOver 或真实用户任务耗时。[详情截图][shot-detail] · [编辑器截图][shot-editor] · [菜单栏截图][shot-menu] |

## 一条隧道怎样运行

1. **配置与运行状态分开。** `Tunnel` 保存 SSH 主机和多条 `Forwarding` 规则，隧道和规则都有稳定 ID。`TunnelStore` 负责 JSON 读写和导入导出，凭据通过 macOS 钥匙串保存。主窗口和菜单栏从同一个 `AppModel` 取数。[数据模型][models] · [存储][store] · [钥匙串][services] · [应用入口][app]
2. **连接由系统 OpenSSH 执行。** `SSHCommandBuilder` 生成参数，`TunnelManager` 按隧道 ID 找到 `TunnelRuntime`。每条隧道使用一个 SSH 进程，已启用的本地、远程和动态转发规则共用这条连接。应用通过 askpass 接回认证与指纹确认请求。[参数构建][builder] · [运行管理][manager] · [凭据交互][askpass]
3. **界面能知道转发到了哪一步。** 运行时消费 SSH 输出，本地规则跟踪监听，远程规则等待服务器确认，必要时检查本机监听。端口占用检查、等待用户输入、网络恢复和唤醒重连均有代码路径。“已连接”描述 SSH 与转发建立，目标数据库能否接受查询仍要由实际客户端验证。[就绪判断][runtime] · [连接状态][states] · [网络与唤醒][manager] · [OpenSSH 官方说明][ssh-config]
4. **已有 SSH 配置有两种用法。** 用户可以直接填写 SSH 别名，沿用连接配置。若从文件导入，上游只为包含转发规则的具体 Host 条目创建隧道。导入器取一个普通别名，跳过 `Match` 块，没有递归展开 `Include` 的流程。应用还支持跳板机、代理、服务预设和 SSH 命令预览。[编辑器][editor] · [配置导入器][importer] · [项目说明][readme]

## 界面上的具体取舍

| 任务 | 当前界面里的证据 | 对日常使用的影响 | Lane 的处理 |
| --- | --- | --- | --- |
| 取得数据库入口 | 默认窗口 1080 × 700 pt。详情先画路线，再逐行列出相同端点，复制控件位于规则行右侧。已有本机转发复制及部分 Web 服务的打开动作。[窗口][app] · [详情构成][detail] · [规则行][rule-row] | 路线图便于第一次理解路径。每天复用同一条规则时，仍需要从图下方找复制入口。 | 展开一条规则，把本机地址和“复制地址”并排。其他规则收为一行，也可以直接复制。 |
| 从菜单栏临时使用 | 菜单栏逐条显示状态、摘要及开关，最多取两条规则生成一行摘要。双击行打开主窗口。底部有两个批量操作。[菜单栏][menu] | 两个以上的端点既难分辨，也不能在这个面板上直接取用。 | 按隧道展开具体规则，每个地址旁都有复制动作。常用位置留给单条隧道。 |
| 新建第一条规则 | 固定 680 × 640 pt 的编辑器划分为服务器、转发、连接、高级四页。它已有预设、字段校验、保存时跳到错误页，以及“仅创建”和“创建并连接”两种意图。[编辑器][editor] | 最简单的本地转发也要在服务器和转发两页之间切换。 | 同页填写 SSH 主机、本机端口和目标服务。高级配置折叠，保留两种保存意图及字段级校验。 |
| 修复端口冲突 | 引擎能够查询占用端口的进程，失败横幅统一提供重试、日志、编辑设置。[端口检查][services] · [失败横幅][banner] | 已知端口被占时，直接重试通常会遇到同一问题，通用编辑入口还要重新找对应规则。 | 直接进入失败规则的端口字段。保留重试，供用户自行释放端口后使用。 |
| 查看连接细节 | 详情还会展示概览、连接信息和最近活动，路线动效已有“减少动态效果”适配。[详情构成][detail] · [路线动效][motion] | 这些内容在排障时有价值，健康连接长期占用同样的视觉层级。 | 诊断集中展示最近事件、SSH 命令和按需查看的路径。连接失败时把可执行的修正动作带回首屏。 |

表中的使用影响属于对静态界面和调用路径的设计判断，没有把它们作为用户研究结果。设计指标和后续验证任务见 [实现路线](03-implementation-plan.md)。

## 复用判断

**建议独立仓库、独立 UI，按模块复用上游核心及其测试。** 直接换皮会继续受原有四页编辑器和详情排序约束。全部重写则要重新验证远程转发确认时序、口令提示和重连等已有行为。`PortholeCore` 没有对外声明 library product，`TunnelRuntime` 又依赖应用层的管理器和提示服务，因此不能把现有引擎当成即插即用的 SwiftPM 库。[包清单][package] · [运行管理][manager] · [运行时][runtime]

上游采用 MIT，版权所有者是 `bryan31`。Lane 按这份方案引入了部分 SSH 核心源码和测试，并随源码及应用保留上游版权与许可文本。具体范围见[实现记录](03-implementation-plan.md#本地实现与验收)。[上游许可证][license]

[commit]: https://github.com/bryan31/porthole/commit/e6fa8c263798f71d1b98c4993051665b68d18800
[readme]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/README.zh-CN.md
[release]: https://github.com/bryan31/porthole/releases/tag/release
[license]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/LICENSE
[package]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Package.swift
[app]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Sources/Porthole/App/PortholeApp.swift#L9-L28
[models]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Sources/PortholeCore/Models.swift#L283
[store]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Sources/Porthole/Engine/TunnelStore.swift#L109-L178
[builder]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Sources/PortholeCore/SSHCommandBuilder.swift#L26
[manager]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Sources/Porthole/Engine/TunnelManager.swift#L39-L116
[runtime]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Sources/Porthole/Engine/TunnelRuntime.swift#L275-L357
[states]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Sources/PortholeCore/TunnelState.swift#L3-L54
[askpass]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Sources/Porthole/Engine/AskpassServer.swift
[services]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Sources/Porthole/Engine/SystemServices.swift#L10-L115
[importer]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Sources/PortholeCore/Importers.swift#L22-L79
[detail]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Sources/Porthole/Views/TunnelDetailView.swift#L10-L37
[rule-row]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Sources/Porthole/Views/TunnelDetailView.swift#L219-L291
[banner]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Sources/Porthole/Views/TunnelDetailView.swift#L84-L119
[menu]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Sources/Porthole/Views/MenuBarPanel.swift#L35-L142
[editor]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Sources/Porthole/Views/TunnelEditorView.swift#L5-L180
[motion]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Sources/Porthole/Views/RouteDiagram.swift#L569-L614
[test-script]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/scripts/test.sh
[tests]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/Tests/PortholeCoreTests/CoreTests.swift
[shot-detail]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/website/assets/img/shots/zh-hans/detail-light-top.webp
[shot-editor]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/website/assets/img/shots/zh-hans/editor-forwarding.webp
[shot-menu]: https://github.com/bryan31/porthole/blob/e6fa8c263798f71d1b98c4993051665b68d18800/website/assets/img/shots/zh-hans/menubar.webp
[ssh-config]: https://man.openbsd.org/ssh_config.5#ExitOnForwardFailure
