# Review #2（复核 REVIEW-1 的修复）

复核范围：`59ddec4..f864698`，共 16 个提交。
验证方式：
- 逐条对照 diff；
- `swift build`、`swift test` 通过（12/12）；
- 用 `.build/release/probe --hours 48` 扫描本机真实数据，并和数据库、日志文件逐条核对。

## 结论

REVIEW-1 的 15 条里，大部分已经修好，状态机的设计也对了。但 **Antigravity 现在完全扫不到会话**，原因见下面第 A 条，这是新引入的问题，必须修。另外还有 3 个小问题。

## 已确认修好

| 条目 | 结果 |
|---|---|
| #1 completed 只在 running/waiting → idle 时升级 | ✅ 由 `SessionStore` 统一处理，首次发现时保持 idle，已读后不会再变回 completed |
| #2 Claude 使用 `status=waiting` 和 `waitingFor` | ✅ 5 秒启发式只在 `status` 字段缺失时兜底；pending 按出现顺序取 |
| #3 Codex 会话发现 | ✅ 能扫到 8 个真实会话，包括之前漏掉的 10-30 那个；`pgrep` 已删除 |
| #4 Codex id 稳定 | ✅ 取文件名末尾 36 位 |
| #5 dsh 字段名 | ✅ `toolCallId`、`arguments` 解析、`reason.kind`；标题恢复正常（不再显示 `rea`）；之前误判"运行中"的两个会话现在是 idle |
| #7 `.added` 只在 waiting 时通知；UTF-8 截断 | ✅ |
| #8 `stateSince`、用时、运行计时 | ✅ 计时用了 `TimelineView` |
| #9 首次扫描放到后台线程、不发通知 | ✅ |
| #10 先按 mtime 过滤再探测锁，改用 `LOCK_SH` | ✅ |
| #11–#15 | ✅ |

## 必须修

### A. Antigravity：数据库在空闲时打不开，导致一个会话都扫不到（P0）
- 现象：probe 扫描结果是 **0 个会话**，而数据库里有 13 条，最新一条是 8 分钟前。
- 原因：`conversation_summaries.db` 是 WAL 模式（文件头第 18–19 字节为 `02 02`）。Antigravity 空闲时会做 checkpoint，并删掉 `-wal` 和 `-shm` 文件。这时用 `mode=ro` 打开会失败，报 `SQLITE_CANTOPEN`，因为只读连接没法创建 `-shm`。我用 `sqlite3` 命令行试过，结果一样。
  - HANDOFF 里那次 probe 能扫到会话，是因为当时 Antigravity 正在执行任务，这两个文件恰好存在。
- 后果：Antigravity 在跑任务时能看到会话，一空闲就看不到，而且是**时有时无**。会话每消失再出现一次，已完成状态就丢一次；等待中的会话还会重复发通知。
- 改法：
  1. 先尝试 `mode=ro`。如果报 `SQLITE_CANTOPEN`，并且 `-wal` 文件不存在，就改用 `file:...?immutable=1` 打开。没有 WAL 文件时，主库文件就是完整的快照，这样读是安全的。
  2. `readSummaries` 打开或查询失败时要 **throw**，不要返回 `[]`。这样 `SessionStore` 会保留上一轮的结果（这个机制已经有了），不会把会话移除。
  3. 补一个测试：fixture 数据库设成 WAL 模式，并且不带 `-wal` / `-shm`，验证能读出数据。
  4. FORMATS.md 第 122 行同步更新。

## 建议修（P1/P2）

### B. Codex 定时任务（automation）每跑一次都会发"已完成"通知
真实会话 `01a188df…`（"巡检我所有服务器……"）是一个 Codex 定时任务，最近 2.5 天跑了 5 次。每次都是 `task_started` 然后 `task_complete`，会被判为"已完成"并发通知。可它最后一条助手消息是：
```
<heartbeat><automation_id>automation</automation_id><decision>DONT_NOTIFY</decision>...
```
改法：最后一条助手消息以 `<heartbeat>` 开头时，这一轮不升级为 completed。如果其中包含 `DONT_NOTIFY`，更不应该通知。detail 也不要显示原始 XML。

### C. dsh 解压结果在 UTF-8 不完整时会被整个丢掉
`decompressZstdTail` 里仍然用的是 `String(data:encoding:.utf8)`。dsh 正在写入时，最后一个 frame 可能不完整，解压输出的末尾就可能停在多字节字符中间。这时整个结果会被丢掉，会话在这一轮消失，已完成状态也跟着丢失。
改法：和 `FileUtils` 一样，改用 `String(decoding:as: UTF8.self)`，再丢掉最后一行不完整的内容。

### D. 小问题，可以顺手改
- **Codex 审批启发式不会触发**：`require_escalated` 在本机 rollout 里只出现在工具定义（`additional_tools`）中，所有真实的 tool call 里一次都没有。这一条是我上一轮建议错了。现在的代码无害，但要在 FORMATS 里如实写明"Codex 的等待授权目前无法识别"。
  - 另外，`.waitingEscalation` 没有套用 `activeThreshold` 时间上限。会话中断后可能会一直显示"等你"，最长 6 小时，建议加上。
- **Codex 大部分会话的 CWD 为空**（8 个里有 7 个）：`session_meta` 不在文件末尾 64KB 内。建议开头也读一次，只读第一行就够了，然后按 `(path)` 缓存。
- **dsh 的 detail 可能过时**：一轮被中止后，detail 还停留在"正在运行 bash · …"。`turn/end` 时，不管 `reason` 是什么，都应该把 detail 改成最后一条助手文本。
- **终端激活**：`entrypoint == "cli"` 时，代码优先找 iTerm，只要装了就用它，没有判断它是否正在运行。应该优先激活正在运行的那个终端。

## 验收

修完 A 之后：
1. 在 Antigravity **空闲时**跑一次 probe，能扫到最近 6 小时的会话。
2. 再在它执行任务时跑一次，同样能扫到。
3. 两次的输出都贴到 HANDOFF 里。

UI 还没有截图核对，因为终端没有屏幕录制权限。等 A 修完，我会让你打开面板截一张图，或者给终端开权限，然后对照设计稿核对一次。
