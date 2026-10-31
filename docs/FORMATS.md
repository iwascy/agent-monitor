# Agent 会话数据源格式调研报告 (docs/FORMATS.md)

本报告详细记录了 macOS 本机运行的四种 AI Agent（Claude Code、Codex、DeepSeek Harness、Antigravity）的数据存储结构、活跃判定依据、状态事件类型以及数据提取规则。

所有分析均基于本机真实数据验证，绝不包含任何凭据信息。

---

## 1. 通用原则与状态模型

### 状态定义 (SessionState)
- **`running`**：Agent 正在思考、生成内容或执行工具。
- **`waitingForUser`**：等待用户确认授权（如高风险命令执行、文件修改）或等待用户回答输入（最高优先级）。
- **`completed`**：本轮任务已执行完毕，等待用户查看结果。在面板中点击或会话重新进入 running 后降为 `idle`。
- **`idle`**：已查阅或处于静默待命状态。
- **过滤规则**：会话进程已退出且超过 6 小时无更新的会话予以丢弃，不显示在面板中。

---

## 2. Claude Code

### 2.1 文件路径与结构
1. **会话元数据**：`~/.claude/sessions/<pid>.json`
   - 文件名即进程 PID，例如 `45990.json`。
   - 字段规范：
     - `pid` (Int): 进程 PID。
     - `sessionId` (String): 会话 UUID，如 `68660d06-0ce7-42f3-b8a1-7b17a91fbae4`。
     - `cwd` (String): 工作目录，如 `/Users/cy/code/agent-monitor`。
     - `name` (String): 会话名称，如 `"多agent会话监控面板"`。
     - `status` (String): 当前状态，已确认取值包括 `"idle"` 和 `"busy"`。
     - `updatedAt` (Int64): 时间戳（毫秒）。
     - `statusUpdatedAt` (Int64): 状态变更时间戳（毫秒）。
2. **Transcript 日志**：`~/.claude/projects/<slug>/<sessionId>.jsonl`
   - 路径规则：`cwd` 中的 `/` 替换为 `-`，如 `/Users/cy/code/agent-monitor` 对应目录 `-Users-cy-code-agent-monitor`。
   - 文件内容：JSON Lines 格式的会话流。

### 2.2 活跃与进程判断
- **存活性**：使用 POSIX `kill(pid, 0)` 检测进程是否存在。若返回非 0（`ESRCH`），判定进程已死亡，忽略该会话文件。

### 2.3 状态判定规则
- **`busy`**：
  - 检查 transcript 的末尾事件：若最后一条 assistant 消息包含 `tool_use`，且尚未出现对应的 `tool_result`，并且文件修改时间距今已超过约 5 秒无新内容，启发式推断为 **`waitingForUser`**（等待用户在终端确认授权或输入）。
  - 若正在高频写入或不满足上述条件，判定为 **`running`**。
- **`idle`**：
  - 由 `busy` 变为 `idle` 时，映射为 **`completed`**（本轮已结束）。
  - 用户在面板点击该会话后，降为 **`idle`**。

### 2.4 脱敏数据片段示例
`~/.claude/sessions/45990.json`:
```json
{
  "pid": 45990,
  "sessionId": "68660d06-0ce7-42f3-b8a1-7b17a91fbae4",
  "cwd": "/Users/cy/code/agent-monitor",
  "startedAt": 1793479204168,
  "name": "多agent会话监控面板",
  "updatedAt": 1793480388690,
  "status": "idle",
  "statusUpdatedAt": 1793480388690
}
```

---

## 3. Codex (OpenAI Codex CLI / ChatGPT Desktop)

### 3.1 文件路径与结构
1. **会话文件**：`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
   - 文件名格式：`rollout-<ISO8601-Timestamp>-<sessionId>.jsonl`，例如 `rollout-2026-11-01T00-24-07-01a192c6-76d1-7a20-8d79-7b78776c9a55.jsonl`。
   - 扫描策略：仅扫描最近 2 天目录，按文件最后修改时间排序，避免全量扫描性能消耗。
2. **会话索引**：`~/.codex/session_index.jsonl`
   - 每行包含 `id`, `thread_name`, `updated_at`。通过 `id` 关联会话标题。
3. **数据库声明**：不需要读取 `~/.codex/*.sqlite`，因为 JSON Lines 和 `session_index.jsonl` 已具备完整事件流和元数据。

### 3.2 活跃与进程判断
- Codex 会话本身不包含 PID 文件。活跃判定依据：
  1. 通过系统进程列表检查是否存在 `codex` 进程。
  2. 结合会话文件的最近修改时间（mtime < 6 小时）。

### 3.3 事件类型与状态判定
Codex 内部 `codex_protocol::protocol` 定义的事件流：
- **`event_msg`**：
  - `payload.type == "task_started"`：本轮任务启动。
  - `payload.type == "task_complete"`：本轮任务完成。
  - `payload.type == "turn_aborted"`：本轮中止。
  - `payload.type == "exec_approval_request"`：等待执行命令审批。
  - `payload.type == "apply_patch_approval_request"`：等待补丁修改审批。
  - `payload.type == "request_user_input"`：等待用户回答输入。
  - `payload.type == "elicitation_request"`：等待交互式选项澄清。
- **`response_item`**：
  - `payload.type == "custom_tool_call"` / `"function_call"`：工具发起。
  - `payload.type == "custom_tool_call_output"` / `"function_call_output"`：工具输出。
  - `payload.type == "message"`：助手回复文本。

### 状态映射：
- 若末尾未闭合的事件为 `exec_approval_request`、`apply_patch_approval_request`、`request_user_input` 或 `elicitation_request`：判定为 **`waitingForUser`**。
- 若末尾已写 `task_complete`：判定为 **`completed`**。
- 若处于 `task_started` 且无结束事件，且进程存活：判定为 **`running`**。
- 其余情况：**`idle`**。

### 3.4 脱敏数据片段示例
```json
{"type":"event_msg","payload":{"type":"task_started"}}
{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"call_123"}}
{"type":"event_msg","payload":{"type":"exec_approval_request","call_id":"call_123","command":"git push --force origin main"}}
{"type":"event_msg","payload":{"type":"task_complete"}}
```

---

## 4. DeepSeek Harness (dsh)

### 4.1 文件路径与结构
1. **会话目录**：`~/.dsh/sessions/<path-slug>/<uuid>/`
   - `<path-slug>`：工作目录路径的编码（如 `--Users-cy-code-mac-rea-display-rea--`）。
   - 文件：
     - `session.lock`：用于并发写锁。
     - `session.v4.jsonl.zstd`：Zstandard 压缩的 JSON Lines 事件流。
2. **zstd 解压机制**：
   - 使用 `/opt/homebrew/bin/zstd -dc` 流式解压。
   - 文件为追加写入，可能包含多个拼接的 zstd frame；解压时若遇到末尾残缺 frame，容错丢弃残缺行，不抛出异常。
   - 为了性能，使用 `(mtime, fileSize)` 作为缓存键。

### 4.2 活跃与进程判断
- **验证结论**：`session.lock` 文件在每个会话结束后仍然保留在磁盘上（大小为 0）。
- **锁状态判定**：dsh 进程在运行时通过 POSIX `flock` 独占锁定 `session.lock`。因此以只读方式打开该文件后执行非阻塞锁测试 `fcntl.flock(fd, LOCK_EX | LOCK_NB)`：
  - 若返回 `EWOULDBLOCK` (Errno 35)，表明 dsh 进程正在运行且持有锁，会话处于活跃状态。
  - 若加锁成功，表明进程已退出或未持有锁，会话已停止运行（随即释放锁）。

### 4.3 事件类型与状态判定
- **事件类型**：
  - `session`：包含 `id`, `createdAt`, `cwd`。
  - `session/title`：包含 `data.title`。
  - `turn/start`：回合开始。
  - `step/start` / `step/end`：单步执行。
  - `tool/call`：工具调用（如 `read`, `bash`, `ask_user_question`）。
  - `tool/result`：工具返回结果。
  - `turn/end`：回合结束。
- **状态映射**：
  - 若持有文件锁，且最新工具调用为 `ask_user_question` 且没有 `tool/result`：判定为 **`waitingForUser`**。
  - 若持有文件锁，且处于 `turn/start` 之后且未出现 `turn/end`：判定为 **`running`**。
  - 若最新事件为 `turn/end`：判定为 **`completed`**。
  - 其余情况：**`idle`**。

### 4.4 脱敏数据片段示例
```json
{"type":"session","id":"2ec8c74f-f25a-4960-bd5c-92ccc6c6abde","createdAt":1793465276850,"cwd":"/Users/cy/code/mac-rea/display-rea"}
{"type":"session/title","data":{"title":"macOS 原生逆向分析"}}
{"type":"turn/start","seq":20,"time":1793465280000}
{"type":"tool/call","data":{"name":"bash","command":"pnpm test"}}
{"type":"turn/end","seq":45,"time":1793465300000}
```

---

## 5. Antigravity

### 5.1 文件路径与结构
1. **全局对话摘要库**：`~/.gemini/antigravity/conversation_summaries.db` (SQLite)
   - 以 `file:...db?mode=ro` 只读打开。
   - 包含表 `conversation_summaries`：
     - `conversation_id` (TEXT PRIMARY KEY)
     - `title` (TEXT)
     - `preview` (TEXT)
     - `workspace_uris` (TEXT): JSON 数组，如 `["file:///Users/cy/code/agent-monitor"]`
     - `status` (TEXT): 取值包括 `"CASCADE_RUN_STATUS_RUNNING"`、`"CASCADE_RUN_STATUS_IDLE"`
     - `not_fully_idle` (INTEGER): `1` 表示运行中，`0` 表示空闲
     - `killed` (INTEGER): `1` 表示被终止
     - `last_modified_time` (datetime)
2. **活跃锁**：`~/.gemini/antigravity/presence/<id>.lock`
   - Antigravity 在当前会话打开时，对 `presence/<id>.lock` 持有 `flock`。
   - 测试 `flock(fd, LOCK_EX | LOCK_NB)`：若返回 `EWOULDBLOCK`，说明窗口/会话仍处于打开状态。
3. **会话日志与详细库**：
   - 日志：`~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl`
   - 对话库：`~/.gemini/antigravity/conversations/<id>.db`（只读打开 `?mode=ro&immutable=0`）

### 5.2 状态判定规则
- **`CASCADE_RUN_STATUS_RUNNING`**：
  - 检查 transcript 日志末尾：若最后一个步骤包含未完成的 `ask_question` 工具调用，判定为 **`waitingForUser`**。
  - 否则判定为 **`running`**。
- **`CASCADE_RUN_STATUS_IDLE`**：
  - 若从 `RUNNING` 转为 `IDLE`（或带有未查阅完成标记），判定为 **`completed`**。
  - 用户查看后判定为 **`idle`**。
- **标题与工作目录提取**：
  - 标题直接取 `conversation_summaries.db` 中的 `title`。
  - `cwd` 解析 `workspace_uris` 中的首个 `file://` URI。

### 5.3 脱敏数据片段示例
```json
{
  "conversation_id": "445fd320-2238-4d23-8cf6-6586d4cd966e",
  "title": "Gemini Prompt Implementation",
  "workspace_uris": "[\"file:///Users/cy/code/agent-monitor\"]",
  "status": "CASCADE_RUN_STATUS_RUNNING",
  "not_fully_idle": 1,
  "killed": 0
}
```

---

## 6. 启发式与未验证状态说明 (Heuristics & Limitations)
1. **Claude Code 等待授权判定**：`~/.claude/sessions/<pid>.json` 中只有 `"busy"` 和 `"idle"`。判断 `waitingForUser` 依赖于检测 transcript 尾部未闭合的 `tool_use` 且静止超过 5 秒，此为启发式推断。
2. **Codex 进程关联**：Codex 会话文件不记录 PID，因此通过 `pgrep -f codex` 和 mtime 联合推断活跃性。
3. **dsh 残缺 frame 容错**：由于 zstd 为追加流式写入，遇到未写完的最后一个 frame 必须静默忽略并保留上一有效状态。
