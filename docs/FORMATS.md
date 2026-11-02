# Agent 会话数据源格式调研报告 (docs/FORMATS.md)

本报告详细记录了 macOS 本机运行的四种 AI Agent（Claude Code、Codex、DeepSeek Harness、Antigravity）的数据存储结构、活跃判定依据、状态事件类型以及数据提取规则。

所有分析均基于本机真实数据（Review #1 实测验证），绝不包含任何凭据信息。

---

## 1. 通用原则与状态模型

### 状态定义 (SessionState)
- **`running`**：Agent 正在思考、生成内容或执行工具。
- **`waitingForUser`**：等待用户确认授权（如高风险命令执行、文件修改）或等待用户回答输入（最高优先级）。
- **`completed`**：本轮任务已执行完毕。**由 SessionStore 负责升级**（上一次扫描是 running 或 waitingForUser、这一次是 idle 才升级为 completed；首次扫描 idle 保持 idle）。
- **`idle`**：已查阅或处于静默待命状态。在面板中点击后或首次扫描发现时为 `idle`。
- **过滤规则**：超过 6 小时无更新的会话予以丢弃，不显示在面板中。

---

## 2. Claude Code

### 2.1 文件路径与结构
1. **会话元数据**：`~/.claude/sessions/<pid>.json`
   - 文件名即进程 PID，例如 `45990.json`。
   - 字段规范：
     - `pid` (Int): 进程 PID。
     - `sessionId` (String): 会话 UUID，如 `68660d06-0ce7-42f3-b8a1-7b17a91fbae4`。
     - `cwd` (String): 工作目录，如 `/Users/cy/code/agent-monitor`。
     - `name` (String): 会话名称。
     - `status` (String): 官方原生状态，取值包括 `"idle"`、`"busy"`、`"waiting"`。
     - `waitingFor` (String?): 官方等待原因字段，取值包括 `"dialog open"`、`"input needed"`、`"sandbox request"`、`"goal proposal"` 等。
     - `entrypoint` (String?): 入口形态，如 `"cli"` 或 `"claude-desktop"`。
     - `updatedAt` (Int64): 时间戳（毫秒）。
     - `statusUpdatedAt` (Int64): 状态变更时间戳（毫秒）。
2. **Transcript 日志**：`~/.claude/projects/<slug>/<sessionId>.jsonl`
   - 路径规则：`cwd` 中的 `/` 替换为 `-`。
   - 文件内容：JSON Lines 格式的会话流，仅用来提取自定义标题、命令细节或助手最后一句输出。

### 2.2 活跃与进程判断
- **存活性**：使用 POSIX `kill(pid, 0)` 检测进程是否存在。若返回非 0（`ESRCH`），判定进程已死亡，忽略该会话文件。

### 2.3 状态判定规则
- **`status == "waiting"`**：映射为 **`waitingForUser`**。
  - 若 `waitingFor == "input needed"`，标签为 `"在问你"`。
  - 其他取值（`"sandbox request"` 等），标签为 `"等待授权"`。
  - 详情从 transcript 中按**出现先后顺序**提取最后一个未响应的 `tool_use`。
- **`status == "busy"`**：映射为 **`running`**。
- **`status == "idle"`**：Adapter 报告 **`idle`**（由 `SessionStore` 识别 running -> idle 转换后升级为 `completed`）。
- **兜底**：仅在 `status` 字段缺失时，才使用“5 秒无新内容且存在未闭合 tool_use”作为启发式兜底。

### 2.4 脱敏数据片段示例
`~/.claude/sessions/45990.json`:
```json
{
  "pid": 45990,
  "sessionId": "68660d06-0ce7-42f3-b8a1-7b17a91fbae4",
  "cwd": "/Users/cy/code/agent-monitor",
  "startedAt": 1793479204168,
  "version": "2.1.309",
  "name": "多agent会话监控面板",
  "updatedAt": 1793505883427,
  "status": "idle",
  "statusUpdatedAt": 1793505883427
}
```

---

## 3. Codex (OpenAI Codex CLI / ChatGPT Desktop)

### 3.1 文件路径与结构
1. **会话文件**：`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
   - 文件名格式：`rollout-<ISO8601-Timestamp>-<sessionId>.jsonl`。
   - 扫描策略：全量遍历 `sessions/` 下所有 `rollout-*.jsonl`，按最后修改时间（mtime < 6 小时）过滤。严禁只扫描“今天和昨天”两日目录，以保证跨天持续的会话不被遗漏。
   - ID 提取：文件名末尾固定为 36 字符标准 UUID，直接截取最后 36 个字符作为会话 ID，保证在文件超出 64KB 尾部读不到 `session_meta` 时 ID 绝对稳定不突变。
2. **会话索引**：`~/.codex/session_index.jsonl`
   - 每行包含 `id`, `thread_name`, `updated_at`，通过 36 位 UUID 精确关联标题。

### 3.2 活跃与进程判断
- **主会话与后台子会话**：`session_meta.payload.id` 优先于旧字段 `session_id`。Codex Desktop 的 guardian 审核日志中，`id` 是审核会话自身 ID，`session_id` 却可能是主会话 ID；混用会让审核完成覆盖主会话运行状态。带 `source.subagent`、`source: "subagent"`、`parent_thread_id` 或 `thread_source: "guardian_review"` 的日志不作为独立会话展示、聚合或通知。
- **注意**：`pgrep -f codex` 在系统安装了 ChatGPT.app 时由于其内置的 `Codex Framework.framework` 多个 helper 进程而永远返回真，不能作为活跃判据。
- **判据**：改用 `task_started` 后是否有 `task_complete` / `turn_aborted` 闭合，结合 mtime 新鲜度（10 分钟内未写入视为已中断/退出，判为 idle）。

### 3.3 事件类型与状态判定
- **真实事件类型说明**：统计本机全部 rollout，真实 `event_msg` 只有：
  - `task_started`、`task_complete`、`turn_aborted`、`agent_message`、`user_message`、`token_count`、`item_completed`、`thread_settings_applied`。
  - **重要**：rollout 中**根本不存在** `exec_approval_request`、`apply_patch_approval_request`、`request_user_input` 或 `elicitation_request` 等审批事件。Codex 的等待授权无法从 rollout 原生判断。
- **启发式等待判定**：
  - 若最后一个 `function_call` / `custom_tool_call` 的参数中包含 `"sandbox_permissions":"require_escalated"`，且没有对应的 `function_call_output` / `custom_tool_call_output`，且文件在 10 分钟内有写入，启发式判定为 **`waitingForUser`**（"等待授权"）。**注意**：本机全部 rollout 中，`require_escalated` 只出现在工具定义（`additional_tools`）里，真实 tool call 中一次都没有出现，所以这条规则实际上不会触发。
- **状态映射**：
  - 若处于未闭合的 `task_started` 且距上次修改在 10 分钟内：判定为 **`running`**。
  - 若出现 `task_complete`、`turn_aborted` 或超时（>10分钟）：Adapter 报告 **`idle`**。只有明确的 `task_complete` 允许升级为已完成；中止、超时或缺少完成证据时设置 `suppressCompletion`，不推送完成通知。
  - 从末尾 64KB 开始读取，缺少生命周期事件时扩大窗口，直到读到 `task_started` / `task_complete` / `turn_aborted` 或文件开头；忽略末尾尚未换行的记录，避免超长工具输出或写入中的 JSON 丢失运行状态。
  - **定时任务（automation）**：每次运行同样是 `task_started` → `task_complete`，最后一条助手消息以 `<heartbeat>` 开头（内含 `<decision>DONT_NOTIFY</decision>` 等）。Adapter 对这类回合设置 `suppressCompletion`，`SessionStore` 不会升级为 completed，也不发通知；detail 置空，不显示原始 XML。
  - **`session_meta`** 是文件第一行，可能远超尾部 64KB 窗口。Adapter 单独读取第一行取 `session_id` / `cwd`，按文件路径缓存（第一行尚未写完时不缓存）。

---

## 4. DeepSeek Harness (dsh)

### 4.1 文件路径与结构
1. **会话目录**：`~/.dsh/sessions/<path-slug>/<uuid>/`
   - 文件：
     - `session.lock`：用于并发锁。
     - `session.v4.jsonl.zstd`：Zstandard 压缩的 JSON Lines 事件流。
2. **解压机制与标题防丢失**：
   - 使用 `/opt/homebrew/bin/zstd -dc` 解压整份文件，解析前几十行提取真实的 `session`（ID 与 CWD）及 `session/title`（完整会话标题），杜绝因截断最后 100 行导致标题丢失或退化为 slug。
   - 采用 `(path, mtime, fileSize)` 复合键在内存中做 LRU 缓存，避免重复解压。

### 4.2 锁状态判定顺序与并发安全
- **竞态预防**：探测锁必须在**按 mtime 过滤之后**执行，只对最近活跃窗口内的会话探测。
- **只读共享探测**：使用 `flock(fd, LOCK_SH | LOCK_NB)`。若返回 `EWOULDBLOCK` / `EAGAIN`，表明 dsh 进程正在运行并持有排他锁；使用共享锁绝不会干扰 dsh 恢复会话，杜绝 `SessionAlreadyOwnedError`。

### 4.3 真实事件类型与字段规范
- **`tool/result`**：真实字段是 **`data.toolCallId`** 或 **`data.message.source.callId`**（绝无 `data.callId`）。
- **`tool/call`**：命令并不在 `data.command`，而在 **`data.arguments`**（JSON 字符串）中，需二次反序列化提取 `command`。
- **`turn/end`**：必须校验 **`data.reason.kind == "completed"`**，区分正常完成与异常中止。非 `completed`（中止、出错）时设置 `suppressCompletion`，不升级为 completed、不通知；无论哪种结束，detail 都改为最后一条助手文本。
- **解压容错**：dsh 正在写入时，最后一个 zstd frame 可能不完整，`zstd -dc` 的输出可能停在多字节字符或 JSON 行中间。解码时使用宽松 UTF-8 解码，并丢弃末尾没有换行的那一行。
- **无活动 turn 防误判**：若会话持有锁但既无活跃 turn 也无等待提问（例如常驻 `--profile paseo`），判定为 **`idle`**，严禁误判为 running。

---

## 5. Antigravity

### 5.1 文件路径与结构
1. **全局对话摘要库**：`~/.gemini/antigravity/conversation_summaries.db` (SQLite)
   - 数据库是 **WAL 模式**（文件头第 18–19 字节为 `02 02`）。Antigravity 执行任务时存在 `-wal` / `-shm`；空闲时会 checkpoint 并删除这两个文件。此时 `mode=ro` 连接无法创建 `-shm`，打开失败（`SQLITE_CANTOPEN`）。
   - 打开顺序：先用 `file:...db?mode=ro`；失败且 `-wal` 不存在时，改用 `file:...db?mode=ro&immutable=1`（没有 WAL 时主库文件就是完整快照，可安全只读）。配置 `sqlite3_busy_timeout(db, 300)`。
   - 打开、查询失败时 adapter **抛错**，`SessionStore` 保留上一轮结果，不移除会话。
   - **时间格式规范**：`last_modified_time` 真实格式为 `2026-10-31 21:25:25.830068+00:00`。DateFormatter 必须配置 `locale = Locale(identifier: "en_US_POSIX")` 及 UTC 时区。解析失败时直接跳过会话，严禁使用 `Date()` 导致会话永不过期。
2. **会话日志**：`~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl`
   - 当 `preview == title` 或 preview 为空时，从日志末尾提取最后一条 `PLANNER_RESPONSE` 的 `content` 前 80 字作为详情，避免标题重复显示。

### 5.2 状态判定规则
- `CASCADE_RUN_STATUS_RUNNING` 且日志末尾有未完成的 `ask_question`：判定为 **`waitingForUser`**（"在问你"）。
- `CASCADE_RUN_STATUS_RUNNING` 且无提问：判定为 **`running`**。
- `CASCADE_RUN_STATUS_IDLE`：Adapter 报告 **`idle`**（由 SessionStore 负责升级为 completed）。

---

## 6. 启发式与未验证状态汇总说明
1. **Codex 等待授权：目前无法识别**。rollout 里没有 approval/input 事件；`require_escalated` 启发式在本机数据中从未命中，仅作保留。
2. **UTF-8 边界容错**：tail 读取文件时，必须丢弃第一个 `\n` 之前的截断片段，并使用 `String(decoding:as: UTF8.self)`，杜绝解码 nil 导致的会话抖动。
3. **SessionStore 升级法则**：只有在观察到会话从 `running` 或 `waitingForUser` 切换到 `idle` 时才晋升为 `completed`；首次扫描一律保持 `idle`。

---

## 7. Claude Code Hooks 事件源规范 (v2 新增)

### 7.1 事件文件存储与格式
- **路径**：`~/Library/Application Support/AgentMonitor/events/claude.tsv`
- **写入机制**：由 `~/Library/Application Support/AgentMonitor/hooks/cc-event.sh` 静默追加。
- **行格式**：`<unix 秒>\t<hook 的 stdin JSON>\n`。
- **公共字段**：`session_id`、`transcript_path`、`cwd`、`hook_event_name`。
- **事件类型与字段**：
  - `PermissionRequest`：`tool_name`、`tool_input`。
  - `Notification`：`message`、`title`、`notification_type`（如 `permission_prompt`、`idle_prompt`、`elicitation_dialog` 等）。
  - `Stop`：`last_assistant_message`。
  - `StopFailure`：执行失败事件。
  - `SessionStart`：`source`（startup / resume / clear / compact / fork）。
  - `SessionEnd`：会话结束。
- **状态覆盖映射**：
  当 hook 事件时间晚于 `sessions/<pid>.json` 的 `statusUpdatedAt - 1s` 时生效：
  - `PermissionRequest` -> `waitingForUser`（"等待授权"，详情展示工具命令或路径）。
  - `Notification` + `permission_prompt` -> `waitingForUser`（"等待授权"）。
  - `Notification` + `elicitation_dialog` -> `waitingForUser`（"在问你"）。
  - `Stop` -> `idle`（可由 Store 晋升为 `completed`）。
  - `StopFailure` -> `idle`（设置 `suppressCompletion = true`）。
  - `SessionEnd` -> `idle`（设置 `suppressCompletion = true`）。

---

## 8. Token 用量数据源规范 (v2 新增)

### 8.1 Claude Code
- **数据源**：`~/.claude/projects/<slug>/<sessionId>.jsonl`
- **聚合规则**：按 `message.id` 去重；排除 `isSidechain == true`；去重后的消息累计求和 `inputTokens`、`cachedInputTokens`、`cacheWriteTokens`、`outputTokens`。
- **当前上下文**：取最后一条非 sidechain assistant 消息的 `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`。

### 8.2 Codex
- **数据源**：`~/.codex/sessions/**/rollout-*.jsonl`
- **读取规则**：读取文件尾部 64KB，提取 `type == "event_msg"` 且 `payload.type == "token_count"` 的记录（忽略 `payload.info == nil`）。
- **当前上下文**：`last_token_usage.input_tokens`；窗口大小取 `model_context_window`。模型名取最后出现的 `"model": "..."`。

### 8.3 Antigravity
- **数据源**：`~/.gemini/antigravity/conversation_summaries.db`
- **读取规则**：读取 `step_count` 作为步数，不统计 token。

### 8.4 DeepSeek Harness (dsh)
- **数据源**：`session.v4.jsonl.zstd` 本地不含 token 字段，不显示用量。

