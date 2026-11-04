# 子代理识别与嵌套显示：实施方案

目标：子代理不再作为独立会话出现在面板里，而是挂在主会话下显示。

效果图（真实 app + 模拟数据渲染）：`docs/screenshots/subagents-mockup.png`
UI 原型代码：`docs/subagents-prototype/`（`SubagentGroup.swift` 和 `prototype.diff`，**不在编译路径里**，实现时搬进 `Sources/` 再按本方案改）

---

## 1. 现状与数据来源

### dsh（本次必须做，问题就出在这里）

dsh 给每个子代理单独建一个会话目录，`DshAdapter` 把它当成普通会话扫出来。子代理事件流的前两行：

```json
{"type":"session","version":4,"id":"<child-uuid>","cwd":"...","parentSession":"session-<parent-uuid>","origin":"subagent","delegationDepth":1, ...}
{"type":"subagent/descriptor","seq":0,"data":{"mode":"continuable","provider":"spawn","label":"<子任务名>","agentModel":"..."}}
```

- `origin == "subagent"`：是子代理
- `parentSession`：父会话的 `id`（就是父会话 `session` 行里的 `id`，目录名也相同，可能带 `session-` 前缀，也可能是裸 UUID，**按字符串原样匹配，不要去前缀**）
- `delegationDepth`：1 = 直接子代理，2 = 孙代理（本机已有 depth 2 的真实样本，父是另一个子代理）
- `subagent/descriptor.data.label`：子代理标题。子代理通常没有 `session/title`，标题优先级：`session/title` > `label` > cwd 末段
- 主会话的 `session` 行没有 `origin`，`delegationDepth == 0`

### Claude Code（不做）

子代理不生成 `~/.claude/sessions/<pid>.json`，所以现在本来就不会被当成独立会话。以后若要显示，需要解析父 transcript 里未闭合的 `Task`/`Agent` tool_use，本次不做。

### Codex（只留口子）

本机 35 个 rollout 的 `session_meta.payload.thread_source` 只有 `user` 和 `onboarding_checklist`，没有子代理样本。`CodexAdapter` 本次不改；模型字段设计成通用的，以后有样本再接。

### Antigravity（不做）

没有发现子代理数据。

---

## 2. 模型改动（`Sources/AgentMonitorCore/Models.swift`）

`AgentSession` 增加：

```swift
public var parentId: String?        // 父会话的完整 id，即 "dsh:<parentSession>"；主会话为 nil
public var subagentDepth: Int       // 0 = 主会话
public var subagents: [AgentSession] // 仅用于显示的嵌套结果，SessionStore 内部始终为空
```

init 参数都给默认值（`nil` / `0` / `[]`），现有调用点不用改。

---

## 3. Adapter 改动（`DshAdapter.swift`）

在 `DshSessionSummary` 加 `parentSession: String?`、`origin: String?`、`delegationDepth: Int`、`subagentLabel: String?`。

`parseDshLines` 里：
- `type == "session"`：额外读取 `parentSession`、`origin`、`delegationDepth`
- 新增 `type == "subagent/descriptor"`：读取 `data.label`

构造 `AgentSession` 时：
- `origin == "subagent"` 且有 `parentSession` → `parentId = "dsh:\(parentSession)"`，`subagentDepth = delegationDepth`
- 标题：`summary.title ?? summary.subagentLabel ?? cwd 末段`

注意：子代理目录同样按 6 小时 mtime 过滤，锁状态判定规则不变。实现后用 `swift run probe` 确认子代理的 parentId 都能对上父会话 id。

---

## 4. 嵌套逻辑：新增纯函数，放在 Core

新文件 `Sources/AgentMonitorCore/SessionTree.swift`：

```swift
public enum SessionTree {
    /// 输入 SessionStore 的扁平列表（含子代理），输出只含顶层会话的列表，子代理挂在 subagents 里
    public static func build(_ flat: [AgentSession]) -> [AgentSession]
}
```

**原则：`SessionStore` 保持扁平不动。** 状态机（running → idle 升级为 completed）、`markAsRead`、transition 都按单个会话 id 照旧工作。嵌套只在交给 UI 前做一次。

规则：

1. **挂载**：`parentId` 能在列表里找到的，挂到父会话的 `subagents` 下。depth 2 挂在它的 depth 1 父节点下（面板最多显示两层，更深的挂到最近一个已显示的祖先下）。子代理按 `stateSince` 升序排列。
2. **孤儿**：找不到父会话时：
   - 子代理处于 running / waitingForUser → 作为顶层会话显示（UI 上标「子代理」）
   - 否则丢弃
3. **父会话的显示状态**取自身和所有后代中最紧急的：waitingForUser > running > completed > idle。
   - 自身不是 waiting、但后代 waiting：显示态改为 `.waitingForUser`，`waitingLabel` = 「子代理等待授权」或「子代理在问你」（取那个子代理的 label 加前缀「子代理」），`detail`/`detailIsCommand` 取那个子代理的
   - 自身 idle/completed、但后代 running：显示态改为 `.running`，`stateSince` 取最早的运行中后代
   - 这只是**显示副本**，不写回 `SessionStore`
4. 顶层排序沿用现有规则（waiting → completed → running → idle），按显示状态排。

调用点：`MonitorViewModel` 收到 `onSessionsUpdated` 时 `self.sessions = SessionTree.build(updated)`。这样 `highestState`、`waitingCount`、筛选计数、`shouldClearFilter` 自动只算顶层会话，不用另改。

---

## 5. 已读与通知

- **标为已读**：`markAsRead(id:)` 点主会话时，同时对它所有后代 id 调 `sessionStore.markAsRead`。`markAllAsRead` 本来就遍历全部，不用改。
- **点子代理行**：和点主会话一样，跳转到主会话（子代理没有独立窗口），并标记主会话及后代已读。
- **通知**（`Notifier.notify` / `NotificationFormatter`）：
  - `parentId != nil` 的会话变成 completed：**不发通知**（只在主会话完成时通知）
  - 子代理变成 waitingForUser：照常发，标题格式「父会话标题 › 子代理标题」。Notifier 需要能按 id 查父会话标题：给 `Notifier` 加一个 `parentTitle: (String) -> String?` 闭包，由 `MonitorViewModel` 从 store 的扁平列表里查
  - 点通知：标记那个子代理和它的主会话已读

---

## 6. UI（原型已完成，照搬）

参考 `docs/subagents-prototype/SubagentGroup.swift`，效果见截图。

- **位置**：`SessionRow` 的 `accessoryView` 下方，`subagents` 非空时显示 `SubagentGroup`
- **汇总条**：`⑂ N 个子代理 · x 等你 · y 运行中 · z 完成`，等你用橙色、运行中用蓝色；全部结束时为「N 个子代理已完成」。右侧 chevron
- **展开规则**：有后代 running/waiting 时默认展开，否则收起；用户点击后以用户选择为准（`@LocalState`，面板关闭后重置即可）
- **子代理行**：不显示大图标；左边状态标记（运行中 `PulsingDotView`、等你橙点、完成绿勾、空闲灰点），12pt medium 标题，右侧计时（运行中 m:ss 蓝色 / 等你橙色时间 / 其余「完成」），下一行 11pt 详情；等你时详情前加橙色「等待授权」/「在问你」
- **层级**：左侧 1.5pt 竖线（`.separator`）；depth 2 再缩进 14pt
- **对齐**：带子代理的 running 行，主图标要顶部对齐（原型里已改：`session.state == .running && session.subagents.isEmpty ? .center : .top`）
- **孤儿子代理**作为顶层行时，副标题改为「`<agent> · 子代理 · <目录>`」
- **AX**：汇总条 accessibilityLabel 为「子代理 · N 个」，子代理行要能被 `panel-probe` 按标题找到

---

## 7. 模拟数据

`prototype.diff` 里有 `MonitorViewModel.mockSessionsSubagents()` 和 `AGENT_MONITOR_MOCK_DATA=subagents` 分支，保留进正式代码。正式实现后 mock 应改成**扁平列表 + parentId**，再经过 `SessionTree.build`，这样 mock 也能覆盖嵌套逻辑。

三种场景：子代理等你（Codex 父）、子代理运行中含孙代理（dsh 父）、全部完成（收起）。另加一个无子代理的普通会话做对照。

---

## 8. 测试（`swift test`）

`Tests/AgentMonitorTests/` 新增：

- `SessionTreeTests`
  - 子代理挂到父会话下，顶层不再出现
  - depth 2 挂在 depth 1 下
  - 子代理 waiting → 父显示态 waiting，waitingLabel 带「子代理」前缀，detail 取子代理的
  - 父 idle、子 running → 父显示 running
  - 活跃孤儿保留为顶层，非活跃孤儿丢弃
  - 顶层计数（`waitingCount`、筛选）不含子代理
- `DshAdapter` 测试：用临时目录造一个父会话 + 一个 `origin: subagent` 的子会话（zstd 压缩，可参考现有 dsh 测试的造数据方式），断言 `parentId`、`subagentDepth`、标题取自 `label`
- 通知：子代理 completed 不通知；子代理 waiting 通知且标题带父标题

---

## 9. 验收

1. `swift test` 全过
2. `./scripts/build-app.sh` 后：
   ```bash
   swift scripts/panel-probe.swift --mock subagents --shots /tmp/sub
   ```
   截图和 `docs/screenshots/subagents-mockup.png` 一致
3. 展开/收起后窗口高度要跟着变，且不留空白（`MenuView` 的 `.fixedSize` 不能动）：用 `panel-probe` 依次按「子代理 · N 个」，打印的窗口高度应该随之变化，切回来后恢复原值
4. `swift run probe` 读真实 dsh 数据：子代理都带 parentId，面板里不再作为独立会话出现
5. 改完更新 `docs/FORMATS.md`（dsh 一节补子代理字段）和 `docs/HANDOFF.md`
