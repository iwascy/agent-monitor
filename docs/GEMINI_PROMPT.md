# 任务：Agent Monitor —— macOS 菜单栏 App，监控本机所有 AI agent 会话

你在 `/Users/cy/code/agent-monitor` 里实现一个 macOS 菜单栏 App，用来汇总本机上 Claude Code、Codex、DeepSeek Harness（dsh）、Antigravity 的会话状态。目的是让用户及时知道哪个会话**已完成**、哪个**在等他回复**。完成后会有另一位工程师做 code review，所以请保持代码清晰、可测，并写明你做的假设。

## 环境约束（已确认）
- macOS 27.2，Apple Silicon，Swift 6.4。**只有 Command Line Tools，没有 Xcode**：不要生成 .xcodeproj，用 Swift Package Manager。
- `zstd` 位于 `/opt/homebrew/bin/zstd`。
- 目录当前为空，也不是 git 仓库。先执行 `git init`，每完成一个阶段提交一次。

## 硬性原则
1. **只读**：绝不写入、移动、删除任何 agent 的数据目录，SQLite 一律以只读方式打开（`?mode=ro`，或 `SQLITE_OPEN_READONLY`）。
2. 不要读取、打印或记录凭据文件，例如 `~/.dsh/.credentials.yaml`、`~/.dsh/.env`、`~/.codex/auth.json`、`~/.gemini/*oauth*`。
3. 数据不出本机，不发任何网络请求。
4. 优先监听文件变化，配合低频兜底轮询；空闲时 CPU 接近 0。

## 架构
```
Package.swift                 # macOS 14+，两个 target + 测试
Sources/AgentMonitorCore/     # 纯逻辑，可测试，不依赖 AppKit
  Models.swift                # AgentKind, SessionState, AgentSession
  Adapters/AgentAdapter.swift # protocol AgentAdapter { var kind; var watchPaths: [URL]; func scan() throws -> [AgentSession] }
  Adapters/ClaudeCodeAdapter.swift
  Adapters/CodexAdapter.swift
  Adapters/DshAdapter.swift
  Adapters/AntigravityAdapter.swift
  SessionStore.swift          # 汇总所有 adapter，diff 前后状态，产出 transition 事件
  FileWatcher.swift           # FSEventStream 包装，带去抖（~300ms）
Sources/AgentMonitor/         # App：SwiftUI MenuBarExtra(.window 样式)
  AgentMonitorApp.swift
  MenuView.swift
  Notifier.swift              # UNUserNotificationCenter
Tests/AgentMonitorCoreTests/  # 用 swift-testing；fixtures 放 Tests/.../Fixtures（必须是脱敏的小样本）
scripts/build-app.sh          # swift build -c release → 组装 AgentMonitor.app（Info.plist 含 LSUIElement=YES、CFBundleIdentifier）→ codesign --sign - → 输出到 build/
```
UNUserNotificationCenter 要求有 bundle，所以必须通过 `build-app.sh` 生成 .app 后运行，不能直接 `swift run`。

### 数据模型
```swift
enum SessionState { case running, waitingForUser, completed, idle }
struct AgentSession: Identifiable, Equatable {
  let id: String            // "\(kind):\(nativeId)"
  let kind: AgentKind       // .claudeCode, .codex, .dsh, .antigravity
  var title: String         // 会话名，没有就用 cwd 最后一段
  var cwd: String?
  var state: SessionState
  var stateSince: Date
  var lastActivity: Date
  var detail: String?       // 例如 "等待授权: Bash(rm ...)"、最后一句助手消息的前 80 字
}
```

### 状态语义
- **running**：agent 正在思考或执行工具。
- **waitingForUser**：在等用户授权工具调用，或在向用户提问。优先级最高。
- **completed**：本轮已结束，结果等用户查看。用户在菜单里点过该会话，或该会话重新进入 running 后，降为 idle。"已读"状态保存在内存里即可，用 sessionId 加完成时间作为 key。
- **idle**：已看过，或长时间无活动。
- **会话不再显示的情况**：进程已死，或超过 6 小时无更新（时长可配置）。

## 各 agent 数据源（下面是已观察到的情况，你必须先实地验证）
先做**格式调研**：每种 agent 挑几个最近的会话，弄清楚"运行中 / 等待授权 / 本轮结束"分别长什么样，然后把结论写进 `docs/FORMATS.md`，包括字段名、事件类型、判断规则、示例片段（脱敏后）。**写完 FORMATS.md 并提交之后，再写 adapter。** 判断不了的状态要在文档中明确写出来，不要靠猜。

1. **Claude Code**
   - `~/.claude/sessions/<pid>.json`：已有字段 `pid, sessionId, cwd, name, kind, entrypoint, status, updatedAt, statusUpdatedAt`。已观察到 `status` 取值有 `"idle"` 和 `"busy"`，请查清楚是否还有表示等待授权的值。
   - 用 `kill(pid, 0)` 判断进程是否存活，进程已死的会话丢弃。
   - transcript 位于 `~/.claude/projects/<cwd 中的 / 替换成 ->/<sessionId>.jsonl`。如果 `status` 无法区分"等授权"，就看 transcript 的最后一条：assistant 的 `tool_use` 没有对应的 `tool_result`，且超过约 5 秒没有新内容，可推断为 waitingForUser（需在 FORMATS.md 里说明这是启发式判断）。
   - `busy` 映射为 running；`busy` 变为 `idle` 映射为 completed。
   - 这一版**不要**修改 `~/.claude/settings.json`，也不要安装 hooks。但 adapter 要设计成以后能接入 hook 事件。
2. **Codex**
   - 会话文件：`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`，每行带 `type`（`event_msg`、`response_item` 等）和 `payload.type`。
   - 已观察到本轮结束时会写 `payload.type == "task_complete"`。请查找等待审批对应的事件类型（例如 exec/patch approval request），以及审批完成后对应的事件。
   - 标题取自 `~/.codex/session_index.jsonl`（`id`, `thread_name`, `updated_at`），用文件名里的 id 关联。
   - 没有 pid 文件。活跃判断依据文件 mtime，再结合是否存在 codex 进程（`pgrep -f codex` 或 `sysctl` 进程列表）。只扫描最近 2 天的目录，不要全量遍历。
   - 不要读 `~/.codex/*.sqlite`，除非 jsonl 确实不够用，并且要在 FORMATS.md 里说明理由。
3. **DeepSeek Harness（dsh）**
   - 会话文件：`~/.dsh/sessions/<路径 slug>/<uuid>/session.v4.jsonl.zstd`，同目录下有 `session.lock` 时可能表示活跃（请验证 lock 的含义：里面是否有 pid、会不会残留）。
   - 文件处于追加写状态，可能由多个 zstd frame 组成。用 `zstd -dc` 流式解压，只解析末尾若干条事件；如果解压失败（最后一个 frame 还没写完），就忽略残缺部分，不要报错。为了性能，按 mtime 缓存解析结果。
   - 可参考 `dsh --help` 了解它的运行方式。
4. **Antigravity**
   - 对话库：`~/.gemini/antigravity/conversations/<id>.db`（SQLite，包含 `steps`、`trajectory_meta`、`trajectory_metadata_blob`、`executor_metadata` 等表，可能带 WAL）。另有 `presence/<id>.lock` 和 `brain/<id>/` 目录。
   - 用只读加 `immutable=0` 的方式打开，能读到 WAL 中的内容，读取遇到锁冲突时要重试。部分字段可能是 protobuf blob，只需提取判断状态所必需的信息。
   - 标题可以试着从 `conversation_summaries.db` 或 `trajectory_meta` 中取。

## UI（已定稿，必须按此实现）
设计稿源码在 `docs/design/`：`Main.dc.html` 是浅色面板，`Dark.dc.html` 是深色面板，`States.dc.html` 是图标状态与通知。这些文件是带模板语法的 HTML，不能直接打开预览，但里面的内联 style 就是精确的尺寸、颜色和字号，示例数据在文件底部的 `renderVals()` 里。实现时以这些文件和下面的规格为准。整体追求 macOS 原生质感：毛玻璃、系统字体、系统颜色，同时自动适配浅色和深色模式。

### 菜单栏图标（`MenuBarExtra` 的 label）
- 用自绘的单色模板图标（16pt）：圆角矩形，里面两条横线，右上角一个状态点。不要用 emoji。
- 状态点的颜色取所有会话中优先级最高的状态：等你 → 系统橙 `#F0841C`；已完成 → 系统绿 `#34C759`；运行中 → 系统蓝 `#0A84FF`；无活动时不显示状态点。
- 有"等你"的会话时，图标右侧显示数量角标：底色 `#C2410C`，白字，10.5pt 粗体，胶囊形状，高 15pt。
- 暂停通知期间，图标旁边额外显示一个划线铃铛。

### 弹出面板（`MenuBarExtra(.window)`）
- 宽 384pt，内边距 10pt，圆角 14pt。背景用 `.ultraThinMaterial` 或 `NSVisualEffectView(.popover)`，加 0.5pt 描边和柔和阴影。
- **头部**："Agent 会话"（14pt bold），右侧显示"N 个活跃 · M 个 agent"（11pt，次要色）。
- **统计卡片**：4 列等宽网格，间距 6pt，从左到右依次为"等你 / 已完成 / 运行中 / 空闲"。每张卡片上方是数字（18pt bold，等宽数字），下方是标签（11pt）。卡片背景用对应状态色的 12–16% 透明度，文字用同色系的深色，深色模式下改用浅色，以保证对比度不低于 4.5:1。点击卡片按该状态筛选，再点一次取消。
- **分组**：顺序为"等你回复 → 已完成 → 运行中"，每组标题是 11pt semibold 次要色，前面带 6pt 状态色圆点。空闲组折叠成一行"空闲 · N 个会话 ›"，点击展开。
- **会话行**：整行是一个按钮，内边距 8pt，圆角 9pt，hover 时显示 5% 的前景色底。
  - 左侧是 agent 官方图标，30pt（见下节）。
  - 右侧第一行：标题（13pt semibold，单行截断）+ 右对齐的时长（11pt，等宽数字）。"等你"的时长用橙色，"运行中"用蓝色，其余用次要色。
  - 第二行：`agent 名 · cwd 最后一段`（11pt 次要色）。
  - **等你**：第三行是橙色 12% 透明度的圆角浅底框，里面是"等待授权 / 在问你"标签（橙色 semibold）加详情。如果详情是命令，用 `SF Mono` 等宽字体。
  - **已完成**：第三行是绿色对勾圆点，加上最后一句结果。
  - **运行中**：第二行改为带脉冲动画的蓝点，加上"正在运行 Bash · xxx"或"正在思考…"。
  - 点击会话行：标为已读，并尝试激活对应的 App（P1）。
- **底部**：0.5pt 分隔线，左边是"全部标为已读"文字按钮，右边是暂停通知（铃铛图标，点击后暂停 1 小时）和设置（滑杆图标）。设置菜单里包括开机启动（`SMAppService.mainApp`）和退出。

### agent 图标：用官方图标，运行时从本机读取，不要打包进 App
| Agent | 来源（按顺序尝试） |
|---|---|
| Claude Code | 用 `NSWorkspace.shared.icon(forFile:)` 读 `/Applications/Claude.app` 的图标 |
| Codex | `/Applications/ChatGPT.app/Contents/Resources/icon-codex-light.png`，深色模式下用 `icon-codex-dark-color.png`；都没有就读 ChatGPT.app 的图标 |
| Antigravity | `/Applications/Antigravity.app` 的图标 |
| DeepSeek Harness | dsh 安装目录里的 `node_modules/@deepseek-ai/dsh-web-frontend/dist/favicon.svg`。安装目录通过 `~/.local/bin/dsh` 解析符号链接找到，本机是 `~/.local/lib/node_modules/@deepseek-ai/dsh`。用 `NSImage(contentsOf:)` 加载 SVG，把鲸鱼染成 `#4D6BFE`，放在白色圆角块上（带 0.5pt 浅灰描边），做出和其他 App 图标一致的外观 |
- App 路径优先用 bundle id 通过 `NSWorkspace.urlForApplication(withBundleIdentifier:)` 查找，找不到再用上表的固定路径。
- 任何一个图标读取失败时，回退为字母色块（CC / CX / DS / AG）。图标只加载一次，缓存在内存里。

## 通知
- 状态变为 waitingForUser 或 completed 时发送通知。通知标题为 `Codex · 会话名`；副标题为"等待授权"或"已完成 · 用时 6 分 12 秒"；正文为 detail。
- **App 启动时的第一次扫描不发通知**。同一个会话在 30 秒内的相同状态变化不重复通知。暂停期间不发任何通知。
- 点击通知后打开面板，或激活对应的 App（P1）。不要为此申请辅助功能权限。

## 交付顺序（每一步都提交）
1. `docs/FORMATS.md`：格式调研结论。
2. Core，加上 Claude Code 和 Codex 两个 adapter，以及测试（用 fixtures 覆盖每个状态的判定）。
3. App：菜单栏、通知、`build-app.sh`。
4. dsh 和 Antigravity 两个 adapter，以及测试。
5. `README.md`：构建与运行方法、各 agent 的状态判断规则、已知局限。

## 验收标准
- `swift build` 和 `swift test` 都能通过。
- `scripts/build-app.sh && open build/AgentMonitor.app` 后，菜单栏出现图标，面板列出当前真实存在的会话，且状态与实际一致。
- 在 Claude Code 里发起一个需要授权的命令后，2 秒内显示"等你"并发出通知；本轮结束后显示"已完成"并发出通知。Codex 同样如此。
- 空闲时 App 的 CPU 占用 <1%。
- 全程没有对任何 agent 目录进行写操作。

完成后，在 `docs/HANDOFF.md` 中列出：实现了什么、哪些状态是靠启发式判断的、哪些未验证、已知问题。
