# Agent Monitor

macOS 原生菜单栏常驻应用，用于实时汇总并监控本机所有 AI Agent 会话（**Claude Code**、**Codex**、**DeepSeek Harness (dsh)**、**Antigravity**）的运行状态。

在多 Agent 并行执行编程任务时，帮助你第一时间获知：
- **等你回复 (waitingForUser)**：哪些会话正在等待命令执行授权或等待用户输入。
- **已完成 (completed)**：哪些会话已完成本轮思考与工具执行，等待查看结果。
- **运行中 (running)**：哪些会话正在执行工具（如 Bash / 编译）或模型思考。
- **空闲 (idle)**：已查看或长时间无活动的会话。

---

## 核心原则

1. **绝对只读**：严禁向任何 Agent 数据目录写入、修改或删除文件。SQLite 数据库统一以 `?mode=ro&immutable=0` 及只读标记打开；锁探测仅使用只读描述符非阻塞 `flock(fd, LOCK_EX | LOCK_NB)`，探测后立即释放。
2. **零凭据接触**：代码严格不读取、不打印、不泄露任何凭据文件（如 `~/.dsh/.credentials.yaml`、`~/.dsh/.env`、`~/.codex/auth.json`、`~/.gemini/*oauth*` 等）。
3. **数据不出本机**：零网络请求，会话元数据全部在本地内存与文件系统处理。
4. **极低资源开销**：基于 macOS `FSEventStream` 文件变化去抖（~300ms）监听，辅以低频（15s）兜底轮询，空闲时 CPU 占用 < 0.1%。

---

## 环境要求

- **操作系统**：macOS 26.0+ (Apple Silicon / Intel)，在 macOS 27.2 Apple Silicon 上验证通过。
- **编译工具**：Swift 6.4+ / Xcode Command Line Tools（无需安装完整 Xcode，纯 SPM 构建）。
- **外部依赖**：Homebrew `zstd`（位于 `/opt/homebrew/bin/zstd`，用于 DSH 压缩日志流式解压）。

---

## 构建与运行

由于 macOS 的 `UNUserNotificationCenter` 本地通知要求可识别的 Application Bundle，本项目通过轻量构建脚本打包签名。

### 1. 运行测试
```bash
swift test
```
*执行 8 个集成与单元测试，覆盖 4 种 Agent 的 running / waitingForUser / completed 状态判断及 SessionStore 排序与已读迁移。*

### 2. 编译并打包 App
```bash
./scripts/build-app.sh
```
该脚本会：
- 执行 `swift build -c release`
- 在 `build/AgentMonitor.app` 组装 Contents 目录与 `Info.plist`（配置 `LSUIElement=YES` 实现无 Dock 图标纯菜单栏常驻）
- 进行 ad-hoc 代码签名 (`codesign --force --deep --sign -`)

### 3. 启动应用
```bash
open build/AgentMonitor.app
```

> **提示（通知中心图标刷新）**：若系统通知中心缓存了旧的占位图标，可通过以下命令重新向 LaunchServices 注册：
> ```bash
> /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f build/AgentMonitor.app
> ```
> 随后退出并重新打开 App 即可生效。

---

## 各 Agent 状态判定规则

| Agent | 数据源 | 活跃判定依据 | 等待回复 (waitingForUser) | 已完成 (completed) | 运行中 (running) |
|---|---|---|---|---|---|
| **Claude Code** | `~/.claude/sessions/<pid>.json`<br>`~/.claude/projects/*/<sessionId>.jsonl` | `kill(pid, 0)` 确认进程存活 | `status == "busy"` 且 transcript 末尾存在未配对的 `tool_use`，超过 5s 无后续事件（等待工具授权） | `status == "idle"` 且由 `busy` 转换而来，或 transcript 末端为 assistant 文本 | `status == "busy"` 且处于活动工具调用或思考期 |
| **Codex** | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`<br>`~/.codex/session_index.jsonl` | 最近 2 天目录 mtime 结合 `pgrep -f codex` | tail 包含未响应的 `exec_approval_request`、`apply_patch_approval_request` 或 `request_user_input` | tail 包含 `task_complete` | tail 包含运行中工具调用或助手流式输出，且 codex 进程活跃 |
| **dsh** | `~/.dsh/sessions/<slug>/<uuid>/session.v4.jsonl.zstd`<br>`session.lock` | 只读打开 `session.lock` 并进行 `flock(LOCK_EX \| LOCK_NB)` 探测锁占用 | 持有 lock 且末尾 tool 调用为 `ask_user_question`、`ask_question` 或存在未确认工具授权 | lock 释放且末尾事件为 `turn/end`，或最后一次为 assistant 总结回复 | 持有 lock，事件处于 `turn/start` 与工具执行中 |
| **Antigravity** | `~/.gemini/antigravity/conversation_summaries.db`<br>`presence/<id>.lock`<br>`brain/<id>/.../transcript.jsonl` | 只读 SQLite 查询且 `killed == 0`，配合 `presence/<id>.lock` 文件锁 | `CASCADE_RUN_STATUS_RUNNING` 且 transcript 最新事件中含有 `ask_question` 工具调用参数 | `CASCADE_RUN_STATUS_IDLE` 或 turn 完成 | `CASCADE_RUN_STATUS_RUNNING` 且正在执行工具或规划生成中 |

---

## UI 与交互设计

采用 macOS 原生 **Liquid Glass（液态玻璃）** 设计规范重新构建，严格遵循分层渲染与系统语义色彩系统：

- **菜单栏图标**：
  - 16pt Retina 矢量轮廓图标，主图形线宽升级为 **1.5pt**，完美对齐 SF Symbols 在 regular 字重下的视觉比重。
  - 状态指示点改用系统语义色（`systemOrange` 等你回复 / `systemGreen` 已完成 / `systemBlue` 运行中），外圈以 `.clear` 混合模式挖出 1pt 物理级透明间隔圈，在 macOS 透明菜单栏及任意动态壁纸上均清晰分明。
  - 等待数胶囊角标底色基于 `systemOrange` 计算最佳可读性对比度，底色为 `systemOrange` 压暗至 0.65 倍，搭配 10.5pt `.bold` 白字，浅色与深色外观下对比度均 ≥ 4.5:1。
  - 静音/暂停期间平滑展示划线铃铛图标。
- **Liquid Glass 原生面板 (384pt)**：
  - **控件层与内容层分离**：底层会话列表承托于原生系统窗口材质，绝不玻璃叠玻璃；操作与筛选控件作为浮层采用原生液态玻璃材质。
  - **头部 (PanelHeader)**：左侧标题与会话/Agent 计数竖排；右侧 `GlassEffectContainer` 容纳两枚 28pt 圆形玻璃按钮（label 加 `.glassEffect(.regular.interactive(), in: .circle)`），包含免打扰切换与设置菜单（开机启动 Toggle、退出）。
  - **筛选条 (FilterBar)**：4 枚等宽玻璃胶囊（等你 / 已完成 / 运行中 / 空闲），挂载 `@Namespace` 与 `glassEffectID` 实现平滑融合形变切换动效；选中态注入轻度高光（≤0.18 透明度状态色），0 会话且未选中的胶囊降至 `.tertiary` 并禁用；当前筛选的会话数归零时自动取消筛选。
  - **会话列表 (SessionList & SessionRow)**：
    - 合并为单一行架构，采用行内独立 `@LocalState` 悬停动效与 12pt continuous 同心圆角；
    - 等你回复命令浅底框采用 `.fill.quaternary` 中性底色，命令单行中间截断；
    - 列表区域限制 `maxHeight: 600pt`，随内容自然收缩，超出时平滑滚动并搭配 `.scrollEdgeEffectStyle(.soft, for: [.top, .bottom])` 柔和淡出边缘。
  - **底部浮动操作胶囊**：仅在存在已完成会话、且筛选为全部或「已完成」时，通过 `.safeAreaInset(edge: .bottom, spacing: 0)` 浮动展示「全部标为已读」大尺寸玻璃胶囊（`.controlSize(.large)`），配合 `.glassEffectTransition(.materialize)` 平滑显隐。
  - **系统语义色适配**：全面废除 Hex 调色盘，原生适配系统深浅色切换、降低透明度与增加对比度辅助功能设置。

---

## 已知局限与说明

1. **Claude Code 授权检测启发式**：Claude Code 当前版本在 `sessions/<pid>.json` 中将等待授权和运行中均标记为 `"busy"`。等待授权通过解析 transcript tail 的 `tool_use` 是否缺少 `tool_result` 并在 5 秒阈值内无写入进行推断。
2. **Codex 进程粒度关联**：Codex 的 rollout 文件中未记录单进程 PID。活跃判定采用文件 mtime 窗口结合全局 `codex` 进程存在性探测。
3. **DSH 锁异常残留容错**：如果 dsh 被 `kill -9` 强制终止，内核会自动释放 `session.lock` 上的文件锁，AgentMonitor 的非阻塞 flock 探测能准确感知锁已解除，自动将其归入 completed 或 idle。
4. **Antigravity WAL 模式**：通过只读 URI 参数 `?mode=ro&immutable=0`，使 SQLite 在只读挂载下依然能够感知 WAL 共享内存更新，并结合 300ms busy_timeout 防止并发访问冲突。
