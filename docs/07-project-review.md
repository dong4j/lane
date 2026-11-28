# Lane 项目审查与迭代清单

审查基线为 2026-11-28 的 `main`，提交 `5b21454`。下一版优先统一手动与 Agent 的连接状态、收紧外部备份的导入范围、补上备份恢复入口，并统一代理连接参数。

本机重新运行了 58 项测试，全部通过，包含真实回环 OpenSSH。另用临时目录、演示数据和独立回环服务核对下列场景。打包后的 stdio 助手完成握手并返回四个工具。同一提交的 GitHub CI 通过 Release 构建与签名校验。菜单点击、VoiceOver 和真实睡眠唤醒留作真机验收。[回环测试入口](../scripts/test-loopback.py) · [本次 CI](https://github.com/dong4j/lane/actions/runs/46093586783)

## 下一版优先修复

### 1. Agent 已连通时，主窗口仍会尝试重复连接

**已复现。** Agent 先打开一条已保存的本地规则，回环 SSH 就绪，主窗口所读的配置状态仍是「已断开」。随后手动连接会报「本机端口已被 ssh 占用」，同一时刻 Agent 仍返回 `ready`。手动连接和 Agent 连接使用不同的运行时编号，当前能够复用的方向是 Agent 借用已存在的手动连接。[运行时归属](../Sources/Lane/Engine/TunnelManager.swift#L61) · [复用逻辑](../Sources/Lane/Agent/AgentAccess.swift#L259) · [菜单状态](../Sources/Lane/Views/LaneMenuBar.swift#L250)

**建议与验收。** 按规则匹配实际监听。在菜单和主窗口显示「Agent 使用中」并允许复制地址。用户选择保持连接时复用现有监听。交换手动和 Agent 的启动顺序，两次都应只建立一个相同的监听。配置有两条规则而 Agent 只启动一条时，另一条要单独显示状态。

### 2. 外部备份可以带入预览中看不到的 SSH 行为

**源码确认。** 备份会保留额外的 OpenSSH 选项，预览列出主机、转发规则和启动时连接标记。用户实际连接时，命令构建器会传入部分可调用本机程序的选项。用户可能只核对了端口，便把文件作者设定的执行行为带进自己的配置。此项通过数据流审查确认，未运行外部命令样本。[备份读取](../Sources/Lane/LaneModel.swift#L175) · [导入预览](../Sources/Lane/Views/UtilitySheets.swift#L29) · [选项传递](../Sources/LaneCore/SSHCommandBuilder.swift#L49)

**建议与验收。** 对外部备份导入明确支持的连接字段，过滤可执行选项，在现有导入预览中列出被忽略项。普通主机、密钥路径和转发规则仍可一次导入。用静态样本验证执行类选项不会进入可启动配置，原备份文件完整保留。

### 3. 备份能导入新隧道，却不能回滚已有隧道

**已复现。** 先备份一条规则，再修改目标端口，导入旧备份时，相同隧道 ID 会被当作重复项跳过。本地配置文件损坏后现有保护会阻止写入，正常导入也无法用于恢复。另用带额外字段的模拟 `version: 2` 文件测试，当前程序接受文件，下一次保存会写回版本 1 并丢掉这个字段。[导入去重](../Sources/Lane/LaneModel.swift#L197) · [写入保护](../Sources/Lane/Engine/TunnelStore.swift#L65) · [文档版本解码](../Sources/LaneCore/Models.swift#L501)

**建议与验收。** 在「设置 → 数据」明确区分「合并导入」和「从备份恢复」。恢复前展示受影响配置并留存原文件，遇到未知版本进入只读状态。分别验证能回滚同一 ID 的端口、能从损坏文件恢复，以及打开新版格式后原文件逐字节不变。

### 4. 代理连接的实际参数、重连判断和诊断命令不一致

**已复现参数差异。** 只更改 SOCKS5 代理用户名，真实运行时生成的启动参数会变化，重连判断却返回 `false`，Agent 路径标识也相同。原因是后两处用了没有代理助手路径的命令构建器。详情页复制命令时也走系统 `nc` 的回退路径，无法表达同一组代理认证条件。[重连判断](../Sources/Lane/Engine/TunnelManager.swift#L113) · [Agent 路径标识](../Sources/Lane/Agent/AgentLease.swift#L53) · [代理命令](../Sources/LaneCore/SSHCommandBuilder.swift#L129) · [复制命令](../Sources/Lane/Views/TunnelDetail.swift#L239)

**建议与验收。** 从同一份有效连接配置判断是否重连、是否可复用及如何展示诊断。需要 Lane 助手的命令在复制前说明依赖条件。修改代理身份后应重新建连，修改名称或备注则保持现有会话。复制结果中不包含密码。

## 改善日常使用与审计

### 5. 让 `lane_list` 提供足够的信息挑选入口

**已核对返回值。** 规则有名称、目标、配置 ID 和规则 ID，缺少本机监听地址。两条命名和目标相同、监听端口不同的规则，客户端仅凭这一列表很难选对。外部转发虽可引用，Agent 目前需要预先知道具体地址。[返回字段](../Sources/Lane/Agent/AgentTool.swift#L186) · [列举与外部核实](../Sources/Lane/Agent/AgentAccess.swift#L183)

**建议与验收。** 在原有 `lane_list` 增加规则的监听地址，并支持按需列出已经核实、可引用的本机 `-L` 入口。以 `m4` 的 `3111`、`3113` 为验收场景，Agent 能选对 `3113`，用完释放自己的引用，原 SSH 进程继续运行。四个工具和一个总开关已经足够。

### 6. 在活动历史中说明失败发生在哪一步

**已复现。** 已接入客户端请求失效的规则 ID 会收到 `route_unavailable`，活动记录增量为 0。建连后的端口冲突则会进入历史，但 MCP 只得到笼统的 SSH 失败原因。历史搜索覆盖本机入口，未单独覆盖 SSH 主机和目标地址。[创建记录前的返回路径](../Sources/Lane/Agent/AgentAccess.swift#L248) · [运行时失败映射](../Sources/Lane/Agent/AgentAccess.swift#L372) · [历史搜索](../Sources/Lane/Views/AgentActivity.swift#L17)

**建议与验收。** 为已认证客户端的有效建连意图保留简短的失败记录，区分规则消失、外部入口消失、端口占用和认证失败。沿用已有审计字段及幂等键，避免重试刷屏。按目标主机或端口搜索，应能找到该次失败和可执行的下一步。

### 7. 让审计历史增长时菜单仍能即时响应

**已测量。** 审计状态改变时，主线程会同步编码并写回整份 `activity.json`。定时任务也每秒遍历租约。用本机 Debug 构建、演示运行时和临时文件测量 `lane_request`，每组取三次中位数。预置 0 条历史约 **1 ms**，预置 5,000 条已结束历史约 **188 ms**。两组都只计本地处理耗时。[调度](../Sources/Lane/Agent/AgentAccess.swift#L57) · [状态更新](../Sources/Lane/Agent/AgentAccess.swift#L329) · [文件写入](../Sources/Lane/Agent/AgentFiles.swift#L36)

**建议与验收。** 定时检查只处理活跃会话，把已结束的历史分开存储或按增量写入。先用同一数据集建立 Release 基线，再测请求耗时和主线程占用。写入失败仍能报告，应用重启后仍能还原历史。

### 8. 让 SSH 配置导入识别拆分文件和多个主机别名

**已核对解析器。** 一个 `Host dev staging` 声明只导出 `dev`。导入入口只读取 `~/.ssh/config` 的正文，单独一条 `Include conf.d/*.conf` 产生 0 个候选项。使用拆分配置的人会看到「没有找到可导入的新隧道」。[文件读取](../Sources/Lane/LaneModel.swift#L161) · [Host 块解析](../Sources/LaneCore/Importers.swift#L22) · [OpenSSH 配置语义](https://man.openbsd.org/ssh_config.5)

**建议与验收。** 支持显式别名和本地包含文件，在预览中显示来源，并说明跳过原因。用一个顶层文件、一个包含文件、两个别名和一条通配规则验收。两个显式别名均可选择，通配规则不会变成虚构主机，反复包含同一个文件可正常结束。

### 9. 让三种转发的标注与复制动作一致

**源码确认。** 多规则菜单把每条远程转发的名称统一显示成「服务器」，用户给规则取的名字消失。远程转发图也把目标固定写成「本机服务」，实际上目标可以是这台 Mac 能访问的另一台机器。两处都影响用户判断地址该交给谁使用。[菜单行](../Sources/Lane/Views/LaneMenuBar.swift#L301) · [路径图](../Sources/Lane/Views/RouteDiagram.swift#L168) · [类型说明](../Sources/Lane/Views/LaneStyle.swift#L112)

**建议与验收。** 优先显示自定义名称，用副标题说明「服务器入口」或「从此 Mac 访问的目标」。保留三种转发的路径动画、静态箭头和备注。创建两条分别命名为「预览站」「回调」的远程规则，展开菜单后应能凭名称选中并复制正确入口。

### 10. 让端口故障直接指向正确的字段和进程

**源码确认。** 编辑器以同一类规则错误处理多个字段；监听地址格式错误会落到监听端口焦点，即使地址还藏在「高级选项」。占用检测先验证了实际绑定地址，查进程名时却只按端口取第一个监听者。同号端口分别用于 IPv4、IPv6 时可能标错进程。[字段定位](../Sources/Lane/Views/TunnelEditor.swift#L351) · [占用者查询](../Sources/Lane/Engine/SystemServices.swift#L76)

**建议与验收。** 让错误携带字段、地址族和端口，统一生成中英文操作提示。地址格式错误时自动展开并聚焦「监听地址」。用两个不同地址上的同号端口验收，占用者只能显示与本次绑定匹配的进程；证据不足时只提示端口冲突。

### 11. 让通用 MCP 客户端在历史里能被区分

**已复现。** 连续两次复制通用配置会得到同一份本地身份文件。两个不同客户端使用这些配置时，审计都显示 `Generic`，会话归属也相同。Codex 和 Claude Code 的专用入口已有各自的身份。[通用配置名称](../Sources/Lane/Views/AgentSettings.swift#L5) · [身份复用](../Sources/Lane/Agent/AgentAccess.swift#L110) · [会话归属](../Sources/Lane/Agent/AgentAccess.swift#L192)

**建议与验收。** 有多个通用客户端时，先让历史展示握手中可取得的客户端自报名称，并注明来源。如果还需隔离会话，可由 Lane 一键出具独立配置，后台分配身份，继续沿用总开关。用两个不同客户端验收来源显示；展示名称不得参与鉴权。

## 发布与长期验收

### 12. 给开源用户一个稳定的安装入口

**已核对发布状态。** 审查时 GitHub Releases 列表为空。README 引导用户登录 GitHub 下载 CI 产物，工作流保留 30 天，只提供标为 `arm64` 的包，构建脚本使用临时签名。[安装说明](../README.md#get-lane) · [打包签名](../scripts/build-app.sh#L17) · [产物保留期](../.github/workflows/macos.yml#L45)

**建议与验收。** 按版本发布 Release，提供固定下载入口、校验值、架构和最低系统说明。面向普通用户分发时加入 Developer ID 签名和公证。用干净的 Mac 从公开页面下载，首次启动后能保存规则、打开菜单栏并生成指向安装位置的 MCP 配置。[Apple 分发说明](https://developer.apple.com/developer-id/)

### 13. 把容易回归的交互和 MCP 接入放入发布验收

**覆盖缺口。** 已有原生预览渲染、真实 SSH 测试和打包助手的协议自检。外部 MCP 客户端测试依赖可选环境变量，当前 CI 未配置这一项。真实菜单展开后的窗口边界、键盘焦点、VoiceOver 和系统睡眠唤醒，在项目清单中仍待真机验收。[菜单窗口尺寸](../Sources/Lane/Views/LaneMenuBar.swift#L434) · [可选客户端验证](../Tests/LaneCoreTests/ManagedOpenSSHTests.swift#L208) · [现有 CI](../.github/workflows/macos.yml#L32) · [真机清单](03-implementation-plan.md#需要真机走一遍的场景)

**建议与验收。** CI 用一个固定版本的 MCP SDK，从通用 JSON 走完列举、建连、取址和释放。菜单验收覆盖空列表、多条规则展开、浅深色与键盘操作，确认顶底完整、整行可切换、独立复制按钮不会触发行折叠。发布前在最低支持的 macOS 和当前系统分别走查，并记录真机唤醒结果。
