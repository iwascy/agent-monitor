# Agent Monitor 开发交接文档 (Handoff)

本文档面向后续进行 Code Review 或维护扩展的工程师，详细记录 Agent Monitor 的架构实现、启发式规则、已知局限与假设。

---

## 1. 交付物与实现功能汇总

### 1.1 模块架构
- **AgentMonitorCore** (跨平台纯逻辑库，SPM Target):
  - `Models.swift`: 定义 `AgentKind`、`SessionState` (`running`, `waitingForUser`, `completed`, `idle`)、`AgentSession`、`SessionTransition`。
  - `Adapters/AgentAdapter.swift`: `AgentAdapter` 协议，规范各 Agent 的监控路径 (`watchPaths`) 与只读扫描接口 (`scan()`)。
  - `Adapters/ClaudeCodeAdapter.swift`: 适配 Claude Code。
  - `Adapters/CodexAdapter.swift`: 适配 OpenAI Codex CLI。
  - `Adapters/DshAdapter.swift`: 适配 DeepSeek Harness (dsh)。
  - `Adapters/AntigravityAdapter.swift`: 适配 Google Antigravity。
  - `FileWatcher.swift`: 基于 CoreServices `FSEventStream` 封装的文件监控，带 300ms 去抖动机制，实现文件写完后批次刷新。
  - `SessionStore.swift`: 汇总所有 Adapter 的扫描结果，计算状态迁移事件（Added / Removed / StateChanged），维护会话内存已读状态，实现状态排序（等你回复 → 已完成 → 运行中 → 空闲）。
- **AgentMonitor** (macOS 菜单栏 App，SwiftUI Target):
  - `AgentMonitorApp.swift`: `MenuBarExtra` 入口，集成 `FileWatcher` 与后台兜底轮询（15s）。
  - `MenuView.swift`: 严格依据 `docs/design/`（Main.dc.html, Dark.dc.html）实现的 384pt 原生弹窗面板，支持 4 列统计过滤卡片、会话分组、命令详情 monospace 高亮、已读标记与设置菜单。
  - `MenuBarLabelView.swift`: 16pt 矢量圆角矩形菜单栏图标，内置优先级状态指示点、`#C2410C` 等待数量徽标、静音划线铃铛图标。
  - `IconManager.swift`: 运行时动态自提取系统已安装 App 图标（`/Applications/Claude.app`、`/Applications/ChatGPT.app`、`/Applications/Antigravity.app`、dsh 本地安装目录 SVG 鲸鱼图标），并具备双字母色块优雅降级能力。
  - `Notifier.swift`: `UNUserNotificationCenter` 本地通知通知流，抑制冷启动首次扫描通知，30s 相同状态去重防骚扰，1小时静音免打扰切换，点击激活对应 App。
  - `MonitorViewModel.swift`: 连接 Core 与 UI 的视图模型，支持系统开机自启 (`SMAppService.mainApp`)。
- **构建与测试**:
  - `scripts/build-app.sh`: SPM release 编译、组装 `.app` bundle、生成包含 `LSUIElement=YES` 的 `Info.plist` 并执行 codesign。
  - `Tests/AgentMonitorCoreTests/`: 8 个全自动化单元与集成测试，覆盖所有 Agent 的 4 类状态解析、缓存机制与状态机转换，测试均在脱敏 fixture 样本上运行，不读写真实用户目录。

---

## 2. 启发式判断与设计假设 (Heuristics & Assumptions)

### 2.1 Claude Code
- **现象**：Claude Code 在 `~/.claude/sessions/<pid>.json` 中仅暴露 `"idle"` 与 `"busy"` 两种状态；当执行工具等待用户按 `y` 授权时，其状态依然标记为 `"busy"`。
- **启发式规则**：
  1. 通过 `kill(pid, 0)` 确认进程是否存活，进程死亡直接丢弃。
  2. 若 `status == "busy"`，读取对应项目 transcript 文件（`~/.claude/projects/<slug>/<sessionId>.jsonl`）末尾约 64KB 内容。
  3. 若最后一条助手消息中包含 `tool_use`，且在此之后没有找到对应的 `tool_result`，并且文件最后修改时间距今超过 5 秒（`waitingThreshold`），推断为 `waitingForUser`（"等待授权"），并提取命令作为 `detail`。
  4. 当状态由 `busy` 转为 `idle` 时，映射为 `completed`；若用户点击或超过 6 小时无活动则降为 `idle`。

### 2.2 Codex
- **现象**：Codex 会话按年月日组织（`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`），文件中不包含宿主进程 PID。
- **启发式规则**：
  1. 只扫描当天与前一天的目录（最多 2 天），避免全盘递归巨型历史数据。
  2. 结合 `pgrep -f codex` 全局探测 Codex 进程是否存在。若文件在最近活跃窗口内且进程存活，认定为活跃会话。
  3. 末尾事件检查：
     - 若出现 `exec_approval_request` 或 `apply_patch_approval_request` 且未收到响应，映射为 `waitingForUser`（"等待授权"）。
     - 若出现 `request_user_input`，映射为 `waitingForUser`（"在问你"）。
     - 若出现 `task_complete`，映射为 `completed`。
  4. 标题从 `~/.codex/session_index.jsonl` 中依据 session ID 关联提取。

### 2.3 DeepSeek Harness (dsh)
- **现象**：dsh 会话位于 `~/.dsh/sessions/<slug>/<uuid>/session.v4.jsonl.zstd`，活跃会话同目录下有 `session.lock`。日志以 zstd 追加写格式存储。
- **启发式规则与只读锁探测**：
  1. **锁探测**：使用 `open(path, O_RDONLY)` 打开 `session.lock`，调用非阻塞独占锁探测 `flock(fd, LOCK_EX | LOCK_NB)`。若返回 `EWOULDBLOCK` / `EAGAIN`，表明 dsh 进程正在运行并持有排他锁；若锁定成功则表明无活跃进程，立即调用 `flock(fd, LOCK_UN)` 释放。**全程未对文件写入任何字节**。
  2. **日志解压**：通过 `/opt/homebrew/bin/zstd -dc` 管道流式解压末尾内容。为杜绝 CPU 浪费，采用 `(mtime, fileSize)` 复合键在内存中做 LRU 缓存，文件无变化时不触发子进程。
  3. **状态判断**：持有锁时，检查末尾是否处于 `ask_user_question`（"在问你"）或活动 turn；未持有锁但末尾已产生 `turn/end` 时映射为 `completed`。

### 2.4 Antigravity
- **现象**：Antigravity 将会话摘要记录在 `~/.gemini/antigravity/conversation_summaries.db`（SQLite WAL 模式），并在 `presence/<id>.lock` 放置锁文件。
- **启发式规则**：
  1. **只读与 WAL 并发安全**：SQLite 数据库以只读 URI `file:...db?mode=ro&immutable=0` 打开，配合 `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI` 及 `sqlite3_busy_timeout(db, 300)`。既能让 SQLite 读取共享内存中的最新 WAL 提交，又绝不发生任何磁盘写操作或锁升级。
  2. **会话过滤**：剔除 `killed == 1` 的会话。
  3. **提问状态推断**：当 `status == "CASCADE_RUN_STATUS_RUNNING"` 时，检查 `brain/<id>/.system_generated/logs/transcript.jsonl` 末尾事件。若最后一个响应是模型调用 `ask_question`，且无后续完成步骤，推断为 `waitingForUser`（"在问你"）。

---

## 3. 未验证项目 (Unverified Items)

由于本地受控沙盒环境及真实 Agent 运行边界，以下项目需在后续实际使用中持续观察验证：
1. **Claude Code 官方 Hook 协议**：若未来版本 Claude Code 在 `~/.claude/settings.json` 中原生支持状态事件 Hook，应优先接入该 Hook 机制以替代 5 秒启发式等待检测。
2. **巨型会话日志下的内存占用**：当单个 session 文件超过数百兆字节时，当前实现通过读取尾部 64KB 及 zstd 流式管道截断保证了响应速度，但在极极端文件系统高频刷写时的 CPU 占用仍需观察。
3. **多终端多屏点击唤起**：点击会话行拉起对应应用时，当前通过 `NSWorkspace.shared.openApplication(at:...)` 激活官方 App 或终端。在配置了多个虚拟桌面 (Spaces) 或跨屏幕场景下的窗口聚焦表现取决于 macOS Window Server 的调度。

---

## 4. 已知问题与边界条件 (Known Issues)

1. **SwiftUI Command Line Tools 宏兼容**：在只有 Command Line Tools 的机器上编译时，`SwiftUIMacros` 中的 `@State` 语法插件不可用。为保证 100% 编译通过，所有 UI 视图状态（如悬浮项、折叠状态、过滤选项）均规范统一定义在 `@ObservedObject var viewModel: MonitorViewModel` 中。
2. **DispatchSourceTimer 析构陷阱**：在 Dispatch 框架中，未处于 resume 状态的定时器在 deinit 时会触发内核 trap (`Release of an inactive object`)。`SessionStore` 中定时器被设计为在 `start()` 时创建并立即 resume，在 `deinit` 中正确 `cancel()`。
3. **权限免侵入**：App 运行时仅请求本地通知权限（第一次启动时弹窗），绝不申请 macOS Accessibility (辅助功能) 或 Full Disk Access (完全磁盘访问) 权限，确保用户数据安全与隐私合规。
