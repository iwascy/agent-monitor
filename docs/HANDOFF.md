# Agent Monitor 开发交接文档 (Handoff)

本文档面向后续进行 Code Review 或维护扩展的工程师，详细记录 Agent Monitor 的架构实现、Review #1 修复清单落实情况、真实环境探针扫描验证及各 Agent 状态判定细节。

---

## 1. 真实探针运行实测输出 (Live Probe Verification)

运行命令：`swift run probe`（对 macOS 本机真实 Agent 数据目录只读探测）

```text
========================================
 Agent Monitor Probe - Live Agents Scan
========================================
Scanning real user directories at: 2026-11-01 04:23:59 +0000
Max activity age window: 6.0 hours (21600 seconds)

----------------------------------------
Agent Kind: Claude Code [claudeCode]
Watch Paths: /Users/cy/.claude/sessions, /Users/cy/.claude/projects
Scanned sessions count: 1
  [1] ID: claudeCode:68660d06-0ce7-42f3-b8a1-7b17a91fbae4
      Title: 多agent会话监控面板
      CWD: /Users/cy/code/agent-monitor
      State (raw): idle
      Detail (isCommand=false): Review 做完了，结论是**现在还不能用**。程序能编译，8 个测试也全过，但这些测试用的是 Gemini 自己编的样本数据。我拿你本机的真实会话跑了四个 
      Last Activity: 2026-11-01 04:04:43 +0000
      Age: 1156s ago

----------------------------------------
Agent Kind: Codex [codex]
Watch Paths: /Users/cy/.codex/sessions, /Users/cy/.codex/session_index.jsonl
Scanned sessions count: 1
  [1] ID: codex:01a188df-cf09-7763-8796-5609ef455ca1
      Title: 巡检我所有服务器和服务器上的服务是否正常，然后出一份异常的报告给我。
      CWD: /Users/cy/Documents/Codex/2026-10-30/new-chat
      State (raw): idle
      Detail (isCommand=false): <heartbeat>
  <automation_id>automation</automation_id>
  <decision>DONT_NOTIFY<
      Last Activity: 2026-11-01 00:59:38 +0000
      Age: 12261s ago

----------------------------------------
Agent Kind: DeepSeek Harness [dsh]
Watch Paths: /Users/cy/.dsh/sessions
Scanned sessions count: 0

----------------------------------------
Agent Kind: Antigravity [antigravity]
Watch Paths: /Users/cy/.gemini/antigravity/conversation_summaries.db, /Users/cy/.gemini/antigravity/presence, /Users/cy/.gemini/antigravity/brain
Scanned sessions count: 1
  [1] ID: antigravity:1fdaa0a4-51b0-4012-83f8-e0dfb0d5d230
      Title: Fix Document Review Issues
      CWD: /Users/cy/code/agent-monitor
      State (raw): running
      Detail (isCommand=false): 正在运行 run_command…
      Last Activity: 2026-11-01 04:23:38 +0000
      Age: 21s ago

========================================
 SessionStore Aggregation (Initial Scan)
========================================
Total sessions tracked: 3
Initial transitions generated: 3 (suppressed from notifications)
  [1] [AG] Fix Document Review Issues
      ID: antigravity:1fdaa0a4-51b0-4012-83f8-e0dfb0d5d230
      State: running
      Detail: 正在运行 run_command…
      Last Activity: 2026-11-01 04:23:38 +0000
  [2] [CC] 多agent会话监控面板
      ID: claudeCode:68660d06-0ce7-42f3-b8a1-7b17a91fbae4
      State: idle
      Detail: Review 做完了，结论是**现在还不能用**。程序能编译，8 个测试也全过，但这些测试用的是 Gemini 自己编的样本数据。我拿你本机的真实会话跑了四个 
      Last Activity: 2026-11-01 04:04:43 +0000
  [3] [CX] 巡检我所有服务器和服务器上的服务是否正常，然后出一份异常的报告给我。
      ID: codex:01a188df-cf09-7763-8796-5609ef455ca1
      State: idle
      Detail: <heartbeat>
  <automation_id>automation</automation_id>
  <decision>DONT_NOTIFY<
      Last Activity: 2026-11-01 00:59:38 +0000
========================================
```

### 真实会话状态解析说明：
1. **Claude Code (`claudeCode:68660d06-...`)**：
   - **状态**：`idle`。
   - **原因**：进程 PID 45990 存活，`~/.claude/sessions/45990.json` 中原生 `status: "idle"`。在首次扫描时，SessionStore 严格遵循规则保持 `idle`，杜绝冷启动误报已完成；当 Claude 下次执行命令转为 busy 时，将进入 running，执行完毕后触发 running -> idle 转换，自动升级为 completed。
2. **Codex (`codex:01a188df-cf09-7763-8796-5609ef455ca1`)**：
   - **状态**：`idle`。
   - **原因**：该会话文件位于 `sessions/2026/10/30/` 目录下，最后写入于 `11-01 08:59`（约 3.4 小时前）。由于全量遍历 `sessions/` 目录且按 mtime 过滤，该跨天会话被正确发现（修复了原先只看今明两天而遗漏的问题）；文件名末尾截取完整的 36 位 UUID 与 `session_index.jsonl` 精准匹配出标题；末尾任务已完成闭合，因此处于 idle 状态。
3. **Antigravity (`antigravity:1fdaa0a4-51b0-4012-83f8-e0dfb0d5d230`)**：
   - **状态**：`running`。
   - **原因**：即当前正在执行本任务的 Antigravity 会话。SQLite 中 `CASCADE_RUN_STATUS_RUNNING`，`presence` 锁持有，transcript 末尾正在执行 `run_command`，状态判定为 `running`，在菜单栏高优先级排在第一位。
4. **DeepSeek Harness (dsh)**：
   - 在默认 6 小时活跃窗口内：无活动（本机最近会话于 9.5 小时前结束，符合过滤规则）。
   - 在 24 小时扩展窗口（`swift run probe --hours 24`）中：成功解析 12 个历史会话。通过全量解压前缀事件，所有会话标题（如“BetterDisplay激活逻辑逆向分析”）完整提取，绝无丢失；且持锁但空闲的会话（`paseo-check`）由于没有 active turn 正确报告为 `idle`，杜绝了此前被误判为运行中的 bug。

---

## 2. Review #1 修复清单与架构演进

### 2.1 P0：状态判定与核心逻辑修复
1. **完成状态升级模型 (#1)**：
   - 4 个 Adapter 仅报告真实底层状态：`running`、`waitingForUser`、`idle`。
   - 由 `SessionStore` 负责状态提升：仅当观察到会话从 `running` 或 `waitingForUser` 切换到 `idle` 时，才将状态置为 `completed`；首次扫描发现的会话若为 idle 则一律保持 `idle`。
2. **Claude Code 官方 waiting 状态 (#2)**：
   - 提取 `~/.claude/sessions/<pid>.json` 中的 `status: "waiting"` 及 `waitingFor` 字段；`input needed` 映射为“在问你”，其他（如 `sandbox request`）映射为“等待授权”。
   - 彻底废除 5 秒启发式等待检测，仅在缺少 `status` 字段时作为最后兜底。
   - `pendingToolUses` 修正为严格按照出现顺序提取最新工具调用。
3. **Codex 发现、UUID 与事件重构 (#3, #4)**：
   - 扫描策略改为遍历 `sessions/` 下所有 `rollout-*.jsonl` 并按 mtime 过滤，彻底覆盖跨天持续会话。
   - 文件名截取末尾固定 36 字符标准 UUID，杜绝巨型文件尾部缺少 `session_meta` 导致的 ID 截断突变与标题失配。
   - 去除永远为真的 `pgrep -f codex`，改用未闭合 `task_started` + 10 分钟新鲜度推断。
   - 如实记录并修改 fixture：Codex rollout 不存在 `exec_approval_request` 等审批事件，增加对 `sandbox_permissions: require_escalated` 的工具调用启发式等待检测。
4. **dsh 字段规范与解压完整性 (#5, #10)**：
   - `tool/result` 适配 `data.toolCallId` 及 `data.message.source.callId`，保证 pending 集合正确清空。
   - `tool/call` 从 `arguments` JSON 字符串中二次解析 `command`。
   - `turn/end` 校验 `data.reason.kind == "completed"`。
   - 杜绝无活跃 turn 时持锁误判为 running，判为 idle。
   - 解压读取全部行，保证开头几十行的 `session` / `session/title` 完整捕获，彻底解决标题退化为 `rea` 的问题。
   - 锁探测先按 mtime 过滤，且采用 `LOCK_SH | LOCK_NB` 共享锁探测，彻底避免探测竞争导致 dsh 恢复会话报 `SessionAlreadyOwnedError`。
5. **Antigravity 日志与日期格式规范 (#6)**：
   - SQLite `last_modified_time` 增加针对 `yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ` 的 POSIX locale 解析器；解析失败直接丢弃，严禁使用 `now`。
   - 当 `preview == title` 时，detail 改为提取 transcript 最后一条 `PLANNER_RESPONSE` 的前 80 字。

### 2.2 P1：通知与状态机
1. **防止通知误报 (#7)**：
   - `Notifier` 中 `.added` 仅在状态为 `waitingForUser` 时触发通知，新发现的 completed / idle 会话绝不推送。
   - 公共工具 `FileUtils.readTailLines` 采用 `String(decoding:as: UTF8.self)` 并丢弃首个截断行，杜绝 UTF-8 中间截断返回 nil 导致的状态抖动。
   - `SessionStore` 在 Adapter 某轮 scan 抛错时保留现有会话，不触发误删。
2. **用时与动态计时 (#8)**：
   - `SessionStore` 精确维护 `stateSince`（状态未变时继承旧值，状态变更时更新为 now）。
   - 进入 running 时记录开始时间；升级为 completed 时精确计算实际运行耗时 `completedDuration`。
   - `MenuView` 中运行状态采用 `TimelineView(.periodic(from: .now, by: 1))` 每秒动态走动。
3. **无阻塞首次扫描与定时器解耦 (#9)**：
   - `SessionStore.start()` 将首次 refresh 异步派发至 `workQueue`，菜单栏秒开不卡死。
   - `SessionStore` 内部记录 `isInitialScan`，首次刷新完全抑制通知派发，彻底消除 1 秒 sleep 的脆弱机制。

### 2.3 P2：体验与工程优化
1. **图标深浅色缓存 (#11)**：`IconManager` 缓存键增加 `isDark` 维度。
2. **静音到期自动恢复 (#12)**：`MonitorViewModel` 增加到期自动调度，1 小时免打扰结束后铃铛划线自动恢复。
3. **应用激活与通知已读联动 (#13)**：
   - Claude CLI 会话激活终端（`com.apple.Terminal` / `com.googlecode.iterm2`），而非 Claude 桌面端。
   - Codex 对应 bundle ID 修正为 `com.openai.chat`。
   - 点击通知自动将对应会话在 SessionStore 中标记为已读。
4. **代码复用与构建规范 (#14, #15)**：
   - 抽取公共 `FileUtils.readTailLines`。
   - `scripts/build-app.sh` 移除冗余 `--deep` 签名参数。

---

## 3. 测试覆盖验证

当前测试套件包含 12 个自动化测试，全部通过（`swift test`）：
- `testSessionStoreInitialScanDoesNotPromoteToCompleted`：验证首次扫描 idle 保持 idle 且不发通知。
- `testSessionStoreRunningToIdlePromotion`：验证 running -> idle 转换正确提升为 completed 并记录用时。
- `testSessionStoreMarkedAsReadDoesNotRevertOnActivityChange`：验证已读后 mtime 变动不会再次变回 completed。
- `testSessionStoreRetainsSessionsWhenAdapterFails`：验证 adapter 抛出错误时现有会话不被删除。
- 4 个 Agent 的真实格式全量状态扫描测试（Claude、Codex、DSH、Antigravity）。

---

## Review #2 修复（见 docs/REVIEW-2.md）

- **A. Antigravity 空闲时数据库打不开**：WAL 模式下 `-wal` / `-shm` 被删除后，`mode=ro` 打开失败。现改为失败且无 `-wal` 时用 `immutable=1` 重试；打开或查询失败时抛错，由 `SessionStore` 保留上一轮结果。测试 `Antigravity: WAL database without -wal/-shm is still readable` 复现了真实的空闲状态（把 fixture 转为 WAL 并关闭连接）。真实数据验证：
  - Antigravity 运行中（存在 `-wal`）：probe 扫描到会话；
  - 空闲（只复制主库文件，不带 `-wal` / `-shm`）：`mode=ro` 打开失败，修复后能读出 9 个会话，且不会创建任何文件。
- **B. Codex 定时任务**：最后一条助手消息以 `<heartbeat>` 开头的回合设置 `AgentSession.suppressCompletion`，`SessionStore` 不升级为 completed、不通知。
- **C. dsh 解压**：宽松 UTF-8 解码，丢弃末尾不完整的一行。
- **D.**
  - Codex `.waitingEscalation` 也套用 10 分钟新鲜度上限；
  - Codex 从文件第一行读取 `session_meta`，补上 cwd 和完整 id；
  - dsh 中止的回合设置 `suppressCompletion`，detail 刷新为最后一条助手文本；
  - CLI 会话（Claude `entrypoint == "cli"` 和 dsh）激活终端时，优先激活正在运行的终端（Ghostty / iTerm / Warp / WezTerm / kitty / Alacritty / Terminal），都没运行时才启动第一个已安装的。

