# Review #1（给 Gemini 的修改清单）

审查对象：`964f09d` 及之前的 6 个提交。
审查方式：通读全部源码；`swift build`、`swift test` 通过（8/8）；另外写了一个小程序，用本机**真实数据**跑了四个 adapter，结果和现状对不上的地方都列在下面。

总体评价：工程骨架、模块划分、只读约束、凭据隔离都做对了，UI 代码也基本贴合设计稿。**主要问题在状态判定**：fixture 是按想象中的格式编的，测试通过不代表能识别真实会话。下面的 P0 必须改，改完要用真实数据验证。

---

## P0：状态判定错误（核心功能失效）

### 1. "已完成"是无条件给的，应改为"观察到 running → 结束"才给
- 现状：Claude 只要 `status == "idle"`、Antigravity 只要 `IDLE`、dsh 只要最后有过 `turn/end`，就判为 `completed`。
- 后果：
  - App 一启动，6 小时内所有闲着的会话全都显示"已完成"。
  - 新开一个 Claude 会话（还没聊过）会显示"已完成"，**而且会发一条"已完成"通知**，原因见第 7 条。
  - "已读"只存在内存里，重启 App 后全部又变回"已完成"。
- 改法：adapter 只报告"原始状态"（running / waitingForUser / idle）。由 `SessionStore` 负责升级：**上一次扫描是 running 或 waitingForUser、这一次是 idle**，才变为 `completed`。首次扫描时 idle 一律保持 idle。这样也符合提示词里"busy 变为 idle 映射为 completed"的原意。

### 2. Claude Code：没有使用官方的 `waiting` 状态
- 查证结果：Claude Code CLI（2.1.309）会往 `~/.claude/sessions/<pid>.json` 写入 `status: "idle" | "busy" | "waiting"`，同时写 `waitingFor` 字段，在二进制里看到的取值有 `"dialog open"`、`"input needed"`、`"sandbox request"`、`"goal proposal"`。FORMATS.md 漏掉了这一点。
- 现状的启发式规则是：有未闭合的 `tool_use`，并且 5 秒内没有新内容。这会把**所有执行超过 5 秒的工具**（跑构建、跑测试、子 agent）误判为"等待授权"，并发出通知。这是最严重的误报来源。
- 改法：
  - `status == "waiting"` 映射为 waitingForUser，`waitingFor` 映射为标签。`input needed` 显示为"在问你"，其他显示为"等待授权"。
  - `busy` 映射为 running。
  - 删掉 5 秒启发式；只在 `status` 字段缺失时才作为兜底保留。
  - transcript 只用来取 detail（命令文本、最后一句话）。
  - FORMATS.md 同步更新。
- 附带问题：`pendingToolUses` 是 Dictionary，`.values.last` 取到的是随机一个，应改为按出现顺序取最后一个。

### 3. Codex：真实会话一个都没扫到
在本机实测，返回 0 个会话。但当前确实有一个 3 小时内更新过的会话：`2026/10/30/rollout-...-01a188df-....jsonl`，最后修改时间是 11-01 08:59。原因有三个：
- **只扫描"今天和昨天"两个日期目录**。目录按会话**创建**日期划分，跨天持续的会话会被漏掉。改法：遍历 `sessions/` 下所有 `rollout-*.jsonl`，按 mtime 过滤（6 小时内）。文件数量不多，可以按 `(path, mtime)` 缓存；或者只遍历最近 7 天的目录，再按 mtime 过滤。
- **这些审批事件在 rollout 里根本不存在**：`exec_approval_request` / `apply_patch_approval_request` / `request_user_input` / `elicitation_request`。我统计了本机全部 rollout，`event_msg` 的类型只有 `item_completed`、`token_count`、`agent_message`、`task_started`、`task_complete`、`thread_settings_applied`、`user_message`、`turn_aborted`。也就是说，Codex 的 waitingForUser 永远不会触发。
  - 改法：在 FORMATS.md 里如实写明"Codex 的等待授权无法从 rollout 判断"。
  - 可选的启发式：最后一个 `function_call` 的参数里带 `"sandbox_permissions":"require_escalated"`，没有对应的 `function_call_output`，并且超过 N 秒没有动静，就判为"可能在等授权"。需要标注为启发式。
  - 修 fixture：用真实的事件类型，不要再用想象出来的。
- **`pgrep -f codex` 永远为真**：ChatGPT.app 的 `Codex Framework.framework` 下有一堆 helper 进程，名字里都带 codex。所以这个检查等于没有。改法：去掉全局进程判断，改用 `task_started` 之后有没有 `task_complete` / `turn_aborted`，再加 mtime 新鲜度（例如超过 10 分钟没写入就视为已中断，判为 idle）。

### 4. Codex：session id 不稳定
- 文件超过 64KB 以后，尾部读不到 `session_meta`，就会退回 `extractIdFromFilename`。这个函数只取最后一个 `-` 之后的部分，比如 `7b78776c9a55`，不是完整的 UUID。
- 后果：同一个会话在文件变大后 id 会变，触发 removed + added，进而重复通知；同时 `session_index.jsonl` 的标题也匹配不上。
- 改法：文件名格式固定为 `rollout-YYYY-MM-DDTHH-MM-SS-<uuid>.jsonl`，直接取最后 36 个字符作为 id。

### 5. dsh：字段名和真实格式对不上
用真实文件核对的结果：
- `tool/result` 里没有 `data.callId`，真实字段是 `data.toolCallId`，以及 `data.message.source.callId`。所以 pending 集合永远清不掉；一旦调用过 `ask_user_question`，在 `turn/end` 之前会一直显示"在问你"。
- `tool/call` 里也没有 `data.command`，命令在 `data.arguments`（JSON 字符串）里，需要先解析出 `command`。
- **"既没有活跃 turn 也没有完成的 turn"时，持锁会话被判为 running**（第 129-131 行）。实测有两个 10-28、10-29 的会话因此显示"运行中"：它们的 dsh 进程（`--profile paseo`）一直开着并持有锁，但早就空闲了。改法：这种情况应判为 idle。
- **只保留最后 100 行**，导致开头的 `session` 和 `session/title` 丢失。实测大量会话的标题退化成了 `rea`。改法：解压时完整扫描一遍，只记录需要的字段（title、cwd、id 和最后状态），不要截断后再解析；或者把 title / cwd 单独缓存，因为它们只会出现在前几十行。
- `turn/end` 的 `data.reason.kind` 可能不是 `completed`（比如中止或出错），应该区分处理，不能一律算作完成。

### 6. Antigravity
- 所有 IDLE 会话都判为 completed，问题同第 1 条。
- `preview` 在真实数据里和 `title` 一样，导致 detail 重复显示标题。改法：preview 等于 title 时不显示；改为取 transcript 最后一条 `PLANNER_RESPONSE` 的 `content` 前 80 字。
- `last_modified_time` 的真实格式是 `2026-10-31 21:25:25.830068+00:00`。`ISO8601DateFormatter` 解析不了，靠的是 fallback；而 fallback 的 `DateFormatter` 没有设置 `locale = en_US_POSIX`，在某些系统设置下会解析失败。解析失败时用的是 `now`，结果是会话永远不会过期。改法：设置 POSIX locale，并且解析失败时跳过该会话，而不是用 now。

## P1：通知与状态机

### 7. `added` 事件发通知会产生误报
`Notifier` 对 `.added` 且状态为 completed / waitingForUser 的会话也会发通知。以下几种情况都会触发：
- 新会话出现（例如上面说的新开的 Claude 会话）；
- 第 3 条里 Codex 文件跨过 64KB 导致 id 变化；
- 尾部截断落在多字节字符中间，`String(data:encoding:)` 返回 nil，会话在这一轮被丢掉，下一轮又被加回来。实测 Codex rollout 每次扫描约有 2% 的概率发生。

改法：
- `.added` 只在状态是 waitingForUser 时才通知。
- 截断读取时跳过开头不完整的 UTF-8 字节；更简单的办法是丢掉第一个 `\n` 之前的内容，再用 `String(decoding:as: UTF8.self)` 解码。
- adapter 某一轮解析失败时，保留上一轮的结果，不要把会话移除。

### 8. "用时"永远是 1 秒；运行计时也是错的
- 所有 adapter 都把 `stateSince` 设成了和 `lastActivity` 一样的值，所以通知里的"已完成 · 用时 X"永远显示 1 秒。
- 面板里"运行中"那一行的计时用的是 `lastActivity`，表示的是"距离上次写文件过了多久"，不是"已经运行了多久"，而且数字不会走动。
- 改法：
  - 由 `SessionStore` 维护 `stateSince`：状态没变时沿用旧值，状态变了才更新为 now。
  - 完成时的用时 = 本次 completed 的时间 − 上一段 running 的开始时间。
  - 运行计时用 `TimelineView(.periodic(from: .now, by: 1))` 每秒刷新。

### 9. 初次扫描阻塞主线程，且抑制通知靠的是 sleep 1 秒
- `MonitorViewModel.init` 里调用的 `store.start()` 会在主线程上同步执行 `refresh()`。实测 dsh 扫描要 0.3–2 秒（需要启动 zstd 子进程解压整个文件），这期间菜单栏会卡住。
- 改法：
  - `start()` 里把首次 refresh 放到 `workQueue` 上执行。
  - "首次扫描不通知"改由 `SessionStore` 实现：第一次 refresh 不产生 transition，或者给 transition 加一个 `isInitial` 标记。不要依赖 1 秒的 sleep。

### 10. dsh 锁探测的顺序
`isLockHeld` 对**所有**会话目录（几十个）每轮都会探测一次，之后才按 mtime 过滤。探测时会短暂持有 `LOCK_EX`。如果恰好这时 dsh 在恢复这个会话，它的非阻塞 flock 会失败（`SessionAlreadyOwnedError`）。
改法：先按 mtime 过滤，只探测最近活跃的会话；或者改用 `LOCK_SH | LOCK_NB` 探测，这样两个探测者之间不会互相冲突。在 HANDOFF 里注明这个竞态。

## P2：小问题

11. `IconManager` 的缓存 key 只有 kind，没有区分深浅色。切换外观后，Codex 图标不会跟着换。缓存 key 应加上 isDark。
12. 暂停通知 1 小时到期后，`isNotificationsPaused` 这个 @Published 值不会自动变回 false，菜单栏的铃铛划线会一直显示。需要在到期时刷新它。
13. 点击会话行或通知时，按 bundle id 激活 App：
    - Claude 用的是 `com.anthropic.claudefordesktop`。对 `entrypoint == "cli"` 的终端会话，这会打开 Claude 桌面版，打开的是错的窗口。CLI 会话应该激活 Terminal / iTerm；拿不到具体窗口就什么都不做。
    - `com.openai.codex` 这个 bundle 在本机不存在，ChatGPT 的 bundle id 是 `com.openai.chat`。
    - 点击通知后应该同时把该会话标为已读。
14. 多处用到的 `readTailLines` 实现完全一样，抽到一个公共工具函数里。
15. `scripts/build-app.sh` 里的 `codesign --deep` 不需要，去掉 `--deep` 即可。

## 验收要求（这一轮）

1. 修正 fixture，**必须用真实格式**：从本机文件里截取片段并脱敏。dsh 用 `toolCallId`，Codex 不要再写不存在的审批事件。
2. 增加一个调试入口：比如 `AgentMonitor --dump`，或者一个 `swift run probe` 目标，把四个 adapter 对真实目录的扫描结果打印出来。在 HANDOFF 里贴一次输出，并说明每个会话的状态为什么是这样。
3. 增加 `SessionStore` 的测试，覆盖这几种情况：
   - 首次扫描不升级为 completed；
   - running 变为 idle 时升级为 completed；
   - 已读之后不会因为 `lastActivity` 变化再次变回 completed；
   - adapter 某一轮失败时不移除会话。
4. 更新 FORMATS.md：补上 Claude 的 `waiting` / `waitingFor`；写明 Codex 的审批事件不在 rollout 里；改正 dsh 的字段名。
5. 每一项单独提交，提交信息里写上对应的条目编号（例如 `fix(claude): use status=waiting (#2)`）。

UI 视觉部分这一轮没有截图核对（本机没有给终端开屏幕录制权限）。状态逻辑修好后，我再看界面。
