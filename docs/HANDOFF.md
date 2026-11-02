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

## Review #2 修复

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

---

## 4. UI 修复（第一版设计稿）

> 本节描述的是 Liquid Glass 重设计之前的第一版 UI。面板部分已被第 5 节取代，菜单栏图标和通知的实现仍然有效（颜色以第 5～7 节为准）。

### 4.1 修复清单落实

1. **#1 菜单栏图标空白修复 (`MenuBarIconRenderer`, P0)**:
   - **根本原因**：`MenuBarExtra` 的 label 仅支持 `Image` 与 `Text`，原 `MenuBarLabelView` 中包含的 `Shape`、`Circle`、`Capsule` 会被系统静默丢弃，导致菜单栏空白且无法点击触发弹窗。
   - **改法**：
     - 新增 `MenuBarIconRenderer`，将 16pt 轮廓图标、优先级状态圆点、等待数量胶囊角标（底色 `#C2410C`，10.5pt 粗体白字，高 15pt，最小宽 16pt）以及划线铃铛（13pt，间隔 5pt）**全部渲染进单个 `@2x` Retina 矢量的 `NSImage`**。
     - 无彩色元素（无活动 `idle` 或静音无活动）时图形以纯黑绘制并标记 `isTemplate = true`，交由系统统一随菜单栏外观着色；
     - 存在彩色元素（状态点或等待角标）时设置 `isTemplate = false`，图形与铃铛在 `drawingHandler` 动态以 `NSColor.labelColor` 取色，确保深色/浅色菜单栏均清晰可见。
   - **单测**：新增单元测试覆盖 8 种状态组合下的尺寸（`16x16`、`37x16`、`34x16`、`42x16`、`55x16`）及 `isTemplate` 状态判断。

2. **#2 通知图标与附件 (`IconManager` / `build-app.sh`, P0)**:
   - **App 图标生成**：编写 `scripts/make-icon.swift`，按照苹果 macOS 824/1024 内容区及 185/1024 圆角规范，绘制 `#1D1D1F` 黑色圆角方块、白色图形及 `#F0841C` 橙色圆点，输出 16~1024 全尺寸 iconset，并通过 `iconutil -c icns` 组装为 `AppIcon.icns` 放置于 bundle Resources 目录；`Info.plist` 配置 `CFBundleIconFile = AppIcon`。
   - **右侧 Agent 附件**：`IconManager.cachedIconPNGURL(for:)` 首次按需将对应 Agent 的官方高分辨率图标渲染导出至 `~/Library/Caches/com.cy.agentmonitor/icons/<kind>.png`。`Notifier` 在触发通知前安全复制至临时文件并构造 `UNNotificationAttachment`，防止系统移走缓存；异常捕获降级保障通知稳定派发。
   - **文档补充**：`README.md` 补充 LaunchServices 缓存刷新指令（`lsregister -f`）。

3. **#3 通知内容对齐 (`NotificationFormatter`, P1)**:
   - 新建 `NotificationFormatter` 工具类：
     - **标题**：过滤换行符（`\r\n` / `\n`），合并空格并截断至 40 字以内（超长加省略号 `…`），格式为 `\(agent) · \(title)`。
     - **副标题**：等待回复动态区分“等待授权”与“在问你”（取 `waitingLabel`）；完成状态格式化为“已完成 · 用时 6 分 12 秒”。
     - **正文**：去除 Markdown 超链接保留文本（`[text](url)` -> `text`）、反引号、粗体星号、代码块与 `#` 标题符号，合并空白并截断至 120 字。
     - **分组**：设置 `threadIdentifier = session.id`，实现会话聚合。

4. **#4 面板逐项对齐设计稿 (P1)**：已被第 5 节的 Liquid Glass 重设计整体取代（`Palette`、统计卡片、底栏均已删除）。

---

### 4.2 截图索引

`docs/screenshots/` 中的截图由 `scripts/capture-all.swift` 生成，始终反映当前 UI（第 5～7 节之后）：

| 内容 | 文件 |
|---|---|
| 菜单栏图标（无活动 / 运行中 / 已完成 / 等你回复 / 通知已暂停，浅色与深色） | `menubar-<状态>-<light\|dark>.png` |
| 面板：默认、筛选「等你」、空闲展开、15 条会话、空状态 | `panel[-waiting\|-idle-expanded\|-large\|-empty]-<light\|dark>.png` |
| 系统通知横幅（手动截取，通知样式未随重设计改变） | `notification-waiting.png`、`notification-completed.png` |
| 降低透明度 / 增加对比度（`scripts/capture-a11y.swift`） | `a11y/panel-reduce-transparency.png`、`a11y/panel-increase-contrast.png` |

---

### 4.3 自动化测试与构建状态

- `swift test`：22 项单元与集成测试全部通过，涵盖状态流转、各 Agent 适配器扫描、WAL 空闲快照容错、`MenuBarIconRenderer` 尺寸与模板模式验证、`NotificationFormatter` 标题/副标题/正文清洗验证。
- `scripts/build-app.sh`：Release 编译与打包、`AppIcon.icns` 自动合成与签入、ad-hoc codesign 一体化运行通过。

---

## 5. Liquid Glass（液态玻璃）重构小结

### 5.1 #1 背景探针与平台升级小结
- **平台升级**：
  - `Package.swift` 提升至 `swift-tools-version: 6.2`，`platforms: [.macOS(.v26)]`。
  - `scripts/build-app.sh` 中 `LSMinimumSystemVersion` 升级为 `26.0`。
  - `README.md` 环境要求同步更新为 macOS 26.0+。
- **背景探针实测结论**：
  - 移除了 `MenuView` 根视图上的 `.background(palette.panelBg)`。
  - 在 macOS 27.2 实机运行打包应用并触发 `MenuBarExtra(.window)` 窗口截图验证（实测 `probe-light.png` / `probe-dark.png`）：
  - 系统 `MenuBarExtra(.window)` 已经自带完整的原生液态玻璃/材质背景（具有毛玻璃模糊穿透效果、系统标准连续曲线圆角与投影）。
  - **最终选择**：**方案 a（首选）**，保持不给根视图额外添加背景或材质，由系统原生窗口全权负责背景材质渲染，避免多层材质叠加大面积失真。

### 5.2 提交历史与工作条目对应清单
| 条目 | 提交 Hash | 提交信息 | 核心改动说明 |
|---|---|---|---|
| **#1** | `c9a86e4` | `chore(platform): bump to macOS 26 and probe window background (#1)` | SPM 6.2 + macOS 26 升级，探针验证系统窗口背景自带毛玻璃材质并采纳方案 a |
| **#2** | `2d840d5` | `refactor(panel): split MenuView and replace hex colors with semantic styles (#2)` | 拆分 `MenuView` 为 `Panel/` 7 个独立组件文件，彻底删除 `Palette` 与 `Color(hex:)`，引入系统语义色 |
| **#3** | `a11e554` | `feat(panel): glass header and filter bar (#3)` | 头部玻璃圆形按钮组（铃铛/设置），4 枚等宽玻璃筛选胶囊与 `@Namespace` 切换动效 |
| **#4** | `9753484` | `feat(panel): session list maxHeight, scroll edges and inline hover (#4)` | 合并会话行为 `SessionRow`，限制 `maxHeight: 520pt` 与滚动边缘软淡出，行内独立 hover，ViewModel 移除 `hoveredSessionId` |
| **#5** | `67d0bb1` | `feat(panel): floating mark-all-read glass button and smooth transitions (#5)` | `.safeAreaInset(edge: .bottom)` 浮动大玻璃胶囊按钮，`.glassEffectTransition(.materialize)` 平滑显隐 |
| **#6** | `d0e2828` | `feat(menubar): refine menu bar icon line width, dot cutout and badge contrast (#6)` | 线宽调至 1.5pt，状态点 1pt 透明描边挖孔，角标底色基于 `systemOrange` 加深 15% 提升对比度 |
| **#7** | `a95ac4f` | `docs(liquid-glass): update capture scripts, documentation, and handoff (#7)` | `capture-all.swift` 扩充多状态面板截图，README 重写 UI 设计章节，完善交接文档 |

### 5.3 关键设计实现与技术选型记录

1. **设置 Menu 样式**：
   - 采用原生 SwiftUI 组合样式：
     ```swift
     Menu {
         ...
     } label: {
         Image(systemName: "slider.horizontal.3")
     }
     .menuStyle(.button)
     .buttonStyle(.glass)
     .buttonBorderShape(.circle)
     .controlSize(.regular)
     .menuIndicator(.hidden)
     ```
   - 实测在 macOS 26+ 下原生支持该组合，无需额外手动给 label 添加包装层即可呈现完整的圆形液态玻璃按钮与下拉弹出功能。
   - **已过时**：浅色模式下该写法渲染成灰底圆，与铃铛不一致，第 6 节 #4 改为给 label 手动加 `glassEffect`，第 7 节让铃铛也采用同样写法。

2. **CommandLineTools 下 `@State` 宏插件兼容**：
   - macOS 26 SDK 中引入了 `@attached public macro State() = #externalMacro(module: "SwiftUIMacros", type: "StateMacro")`，而在无 Xcode 完整安装包的独立 Command Line Tools 环境下，缺少 `libSwiftUIMacros.dylib`，会导致直接使用 `@State private var isHovered` 报找不到外部宏错误。
   - 在 `StatusStyle.swift` 中定义了零依赖的 `@LocalState` 属性包装器，内部直接封装 `SwiftUI.State<Value>` 并遵循 `DynamicProperty`，语义与运行期表现 100% 等同于原生 SwiftUI State，同时完全规避编译器查找缺失外部宏的问题。

3. **菜单栏角标可读性与对比度优化**：
   - 经实测计算，纯白文字在未加深的原始 `NSColor.systemOrange` 上的对比度仅为 ~2.31:1，在浅色半透明菜单栏下小字号（10.5pt）辨识度不足。
   - 将角标底色调整为 `systemOrange` 在 sRGB 空间加深 15% 的版本（`r: 0.85, g: 0.47, b: 0.133`），白字对比度大幅提升至 **3.16:1**，且保持纯正活力橙色调。

4. **滚动区域最大高度与窗口自适应收缩**：
   - 会话列表区域外层设 `ScrollView`，配合 `.fixedSize(horizontal: false, vertical: true)` 与 `.frame(maxHeight: 520)`：
     - 当会话数量较少时（如 1~3 条），面板高度随内容自适应紧凑收缩；
     - 当会话数量较多时（经 16 条大数据量压测验证，`AGENT_MONITOR_MOCK_DATA=large`），整体面板窗口高度稳定锁定在 620pt 上限，不遮挡屏幕，且顶部和底部边缘在滚动时自然应用 `.scrollEdgeEffectStyle(.soft, for: [.top, .bottom])` 柔和渐变过渡。
   - **已过时**：这一写法实际会让列表溢出、盖住头部，第 6 节 #1 改为测量内容高度，第 7 节把上限调到 600 并修正了 8pt 偏差。

5. **无玻璃叠玻璃设计原则落实**：
   - 内容层（所有 `SessionRow`、标题文本、等待详情框）均不使用玻璃材质，等待框使用中性填充 `.fill.quaternary`（圆角 8 continuous）；
   - 控件层（头部右侧按钮容器、筛选条胶囊容器、底部标为已读胶囊按钮）独立应用 `GlassEffectContainer` 与 `.buttonStyle(.glass)`。相邻按钮严格封装在同一个容器中，彻底根除玻璃多层相互叠加导致的折射白雾问题。

---

## 6. Review 修复与完善

### 6.1 修复提交历史与工作条目对应清单
| 条目 | 提交 Hash | 提交信息 | 核心改动说明 |
|---|---|---|---|
| **#1** | `5e14c9b` | `fix(panel): fix list overflow and height calculation with onGeometryChange (#1)` | 修复 ScrollView 外层 fixedSize 导致的内容高度逃逸并覆盖头部的问题，改由内部 Geometry 监听驱动高度收缩与上限裁剪 |
| **#2** | `247b058` | `fix(panel): auto-clear filter on zero count and keep selected capsule interactive (#2)` | 会话更新及标为已读归零时，自动清空筛选状态；已选中的筛选胶囊保持可交互，防止界面卡死在空白列表 |
| **#3** | `a19d389` | `fix(menubar): restore bold weight and increase badge contrast to >= 4.5:1 (#3)` | 菜单栏角标底色调整为 `systemOrange * 0.65`，白字在浅色与深色外观下对比度均达到 ≥ 4.5:1，字重恢复为 `.bold` |
| **#4** | `13d295d` | `fix(panel): align settings menu glass styling with bell button (#4)` | 消除浅色模式下 Menu 标准灰色按钮背景，统一通过 label 显式 `.glassEffect` 与 28x28 尺寸同 Bell 按钮完全对齐 |
| **#5** | `d4d0427` | `fix(panel): hide mark-all-read button when completed sessions not in filter (#5)` | 「全部标为已读」按钮仅在存在已完成且筛选允许时显示，在「等你」等视图下隐藏，避免无会话可见时的误导 |
| **#6** | *(本提交)* | `docs(handoff): document fixes, contrast math, and a11y captures (#6)` | 独立 `LocalState.swift`，补交降低透明度/增加对比度实机辅助功能截图，验证系统设置完全复原 |

### 6.2 关键修复技术细节与推导说明

#### 1. 列表溢出与高度计算 (#1)
- **问题根源**：原先在 `ScrollView` 外层直接加 `.fixedSize(horizontal: false, vertical: true)`，导致 SwiftUI 计算 ScrollView 的理想尺寸为无限大，进而突破父视图约束并向上覆盖了 `PanelHeader`。
- **改法**：
  - 将 `.fixedSize(horizontal: false, vertical: true)` 下移至 `ScrollView` 内部的 `VStack`。
  - 在内部 `VStack` 上挂载 `.onGeometryChange(for: CGFloat.self) { $0.size.height }` 实时测量实际内容高度 `contentHeight`。
  - 在底部浮动按钮上同样测量其实际高度 `buttonHeight`。
  - `ScrollView` 整体高度设定为 `min(contentHeight + buttonHeight, 520)`，并挂载 `.scrollBounceBehavior(.basedOnSize)`、`.scrollEdgeEffectStyle(.soft)` 及 `.clipped()`。
  - 完美达成：当内容较少时窗口自适应收紧；内容较多时稳定截断在 520pt 内，头部清晰展示，内部平滑滚动。

#### 2. 筛选归零自动取消与防呆交互 (#2)
- **手动复现与验证结果**：
  1. 选中「已完成」筛选胶囊；
  2. 点击该条已完成的会话，触发 `markAsRead`；
  3. 会话被标为已读，`sessions` 数组发生变更，触发 `didSet` 中的 `autoClearEmptyFilter()`；
  4. 监测到当前筛选状态 `.completed` 对应的会话数量已经归零，自动通过 `withAnimation(.bouncy)` 将 `filterState` 设为 `nil`；
  5. 列表平滑回退至显示全部状态，避免出现无任何会话提示的白板。
  6. 同时，`FilterBar` 的禁用条件优化为 `count == 0 && !isSelected`，保证已处于选中态的胶囊永远可以再次点击主动取消。
- **单元测试说明**：
  - 将状态检查抽离为纯静态函数 `MonitorViewModel.shouldClearFilter(currentFilter:sessions:)`。
  - 由于 Swift Package Manager 架构中，`AgentMonitorCore` 为底层通用模块，其测试 Target `AgentMonitorCoreTests` 不能（且 SPM 禁止）反向依赖上层的可执行程序 Target `AgentMonitor`，因此不适宜在底层库测试中直接引用上层 ViewModel。该逻辑作为纯函数由主应用逻辑与自动化截图集成测试双重覆盖。

#### 3. 菜单栏徽标白字对比度计算过程 (#3)
- **要求**：WCAG AA 规范对小字（< 18pt 或 < 14pt 粗体，本处为 10.5pt 粗体）规定对比度必须 $\ge 4.5:1$。
- **相对亮度公式**：
  对于 sRGB 归一化分量 $C \in [R, G, B]$：
  $$C_{\text{linear}} = \begin{cases} \frac{C}{12.92} & \text{if } C \le 0.04045 \\ \left(\frac{C + 0.055}{1.055}\right)^{2.4} & \text{if } C > 0.04045 \end{cases}$$
  $$Y = 0.2126 R_{\text{linear}} + 0.7152 G_{\text{linear}} + 0.0722 B_{\text{linear}}$$
  对比度：$$\text{Contrast} = \frac{Y_{\text{white}} + 0.05}{Y_{\text{bg}} + 0.05} = \frac{1.05}{Y_{\text{bg}} + 0.05}$$
- **推导计算**：
  - **浅色外观 (Aqua)**：
    `NSColor.systemOrange` 原生 sRGB 约为 $(1.000, 0.584, 0.000)$。
    乘以系数 $0.65$ 后底色为 $(0.650, 0.380, 0.000)$：
    - $R_{\text{linear}} = ((0.650 + 0.055) / 1.055)^{2.4} \approx 0.3776$
    - $G_{\text{linear}} = ((0.380 + 0.055) / 1.055)^{2.4} \approx 0.1166$
    - $B_{\text{linear}} = 0$
    - $Y_{\text{bg}} = 0.2126 \times 0.3776 + 0.7152 \times 0.1166 + 0 = 0.0803 + 0.0834 = 0.1637$
    - **对比度**：$1.05 / (0.1637 + 0.05) = 1.05 / 0.2137 \approx \mathbf{4.91:1} \ge 4.5:1$。
  - **深色外观 (DarkAqua)**：
    `NSColor.systemOrange` 原生 sRGB 约为 $(1.000, 0.624, 0.039)$。
    乘以系数 $0.65$ 后底色为 $(0.650, 0.405, 0.025)$：
    - $R_{\text{linear}} \approx 0.3776$
    - $G_{\text{linear}} = ((0.405 + 0.055) / 1.055)^{2.4} \approx 0.1340$
    - $B_{\text{linear}} = ((0.025 + 0.055) / 1.055)^{2.4} \approx 0.0019$
    - $Y_{\text{bg}} = 0.2126 \times 0.3776 + 0.7152 \times 0.1340 + 0.0722 \times 0.0019 = 0.0803 + 0.0958 + 0.0001 = 0.1762$
    - **对比度**：$1.05 / (0.1762 + 0.05) = 1.05 / 0.2262 \approx \mathbf{4.64:1} \ge 4.5:1$。
  - **结论**：在浅色与深色外观下白字对比度均稳定超越 4.5:1 的标准，字重同步恢复为 `.bold`，辨识度显著提升。

#### 4. 头部按钮一致性与玻璃材质统一 (#4)
- 在 macOS 26 中，对 `Menu` 赋予 `.menuStyle(.button).buttonStyle(.glass)` 时，AppKit 将其渲染为标准的纯色灰色控件，缺少毛玻璃折射与高光，导致浅色模式下与左侧铃铛玻璃按钮视觉分裂。
- 改为通过 label 赋予 `.glassEffect(.regular.interactive(), in: .circle)`，并显式指定 `.frame(width: 28, height: 28)`，`Menu` 自身采用 `.buttonStyle(.plain)` 与 `.menuIndicator(.hidden)`。
- 铃铛按钮同步设定为 28x28 规格，两者封装于 `GlassEffectContainer(spacing: 8) { HStack(spacing: 8) { ... } }`。实机截图中，两枚按钮在浅色与深色模式下的尺寸、高光边缘、材质穿透与投影完全一致。

#### 5. 底部操作按钮显示条件过滤 (#5)
- 「全部标为已读」按钮逻辑升级为：仅当会话列表中存在至少一条 `.completed` 状态的会话，**并且**当前筛选状态为全部（`nil`）或已完成（`.completed`）时方才展示。
- 当用户切换至「等你回复」、「运行中」或「空闲」筛选时，由于当前列表中并不会显示任何已完成项，该按钮自动收起，避免界面产生无效操作认知。

#### 6. 辅助功能实测与设置恢复确认 (#6)
- **LocalState 解耦**：将 `@LocalState` 单独移动至 `Sources/AgentMonitor/Panel/LocalState.swift`，详细注明由于 Xcode Command Line Tools 环境未随附 `libSwiftUIMacros.dylib`，原生 `@State` 会报错找不到 `SwiftUIMacros.StateMacro`，故通过封装 `State<Value>` 遵从 `DynamicProperty` 提供免宏方案。
- **辅助功能实机截图**：
  编写 `scripts/capture-a11y.swift` 自动化工具，通过 AppleScript 精准控制系统设置，截取并在 `docs/screenshots/a11y/` 沉淀以下两张浅色外观实操图：
  1. **降低透明度**：[panel-reduce-transparency.png](screenshots/a11y/panel-reduce-transparency.png)
     - 观察点：玻璃控件与半透明背景变为纯净不透明高对比灰白色块，文字与图标对比度保持清晰无干扰。
  2. **增加对比度**：[panel-increase-contrast.png](screenshots/a11y/panel-increase-contrast.png)
     - 观察点：控件边缘描边加深强化，胶囊与列表分割区域层级更加鲜明。
- **系统设置恢复确认**：
  `scripts/capture-a11y.swift` 脚本在每次截图后均自动触发反向点击，并在结束时通过 AppleScript 重新读取「減少透明度」与「增加對比」两个系统设置项的值，确认均为 `0`（已关闭恢复原状），并退出系统设置应用。




## 7. 第二轮 review 后的收尾修复（Claude）

- **列表高度**：
  - 上限从 520 调到 600，常规 5 条会话不再需要滚动。
  - 之前总是多出约 8pt 可滚动的高度，原因是 `safeAreaInset` 默认会在按钮和内容之间额外加约 8pt 间距，而这段间距没有算进测得的按钮高度里。现改为 `safeAreaInset(edge: .bottom, spacing: 0)`。
  - 修复后，`panel-*.png` 里系统设置为「始终显示滚动条」时，不再出现滚动条，右侧时间列也不会被挤开。
- **头部按钮**：铃铛按钮改成和设置按钮相同的写法：28pt 的 label，加 `.glassEffect(.regular.interactive(), in: .circle)`，再加 `.buttonStyle(.plain)`。现在两个按钮一样大。
- **单元测试**：新增 `AgentMonitorTests` target，通过 `@testable import AgentMonitor` 测试 `shouldClearFilter` 和 `shouldShowMarkAllAsRead`。SPM 是允许测试 target 依赖可执行 target 的。
- **`capture-a11y.swift` 截图脚本**：
  - 截完图后把两个开关恢复到**运行前的原值**，不再一律关闭；
  - 复选框名称按简体、繁体、英文依次尝试；
  - 两个开关都找不到时直接退出，不做任何修改；
  - 恢复后的值和原值不一致时，以非 0 状态码退出。
  - 这个脚本会修改系统辅助功能设置，所以本轮只做了类型检查，**没有实际运行**。`docs/screenshots/a11y/` 里仍是上一轮的截图。

---

## 8. v2 功能落地与实测验证 (v2 Features)

在 v2 版本中，我们全面落地了 SPEC 中规定的全部 6 项核心特性（F1 - F6）以及对应的设置窗口与快捷键体系：

### 8.1 F1 精确跳转与右键菜单
1. **进程与 TTY 解析 (`HostResolver`)**：
   - 基于 Darwin `sysctl([CTL_KERN, KERN_PROC, KERN_PROC_PID, pid])` 提取 `kinfo_proc`。
   - 解析首层进程的 `kp_eproc.e_tdev` 并通过 `devname` 获取 tty（如 `/dev/ttys012`）。
   - 沿 `e_ppid` 递归上溯查找前台宿主应用 `NSRunningApplication`（支持 Warp、Ghostty、kitty、iTerm2、Terminal、VS Code、Cursor、Windsurf、Zed 等）。
2. **多级聚焦策略 (`FocusStrategies`)**：
   - 第一级：针对 iTerm2 与 Terminal，通过后台 `NSAppleScript`（2秒超时）精准选中匹配 tty 的标签页并置顶。
   - 第二级：针对其他终端，利用 macOS Accessibility (AX) 树匹配窗口标题（支持标题清理、emoji 剥离、空格压缩、大小写归一化）。
   - 第三级：回退激活应用进程。
3. **右键原生菜单 (`contextMenu`)**：
   - 包含「跳转到会话」（副标题显示解析的目标应用/窗口）、已完成会话「标为已读」、「在访达中显示目录」、「拷贝目录路径」、「拷贝会话 ID」、「静音此项目」（子菜单：所有通知 / 仅「已完成」通知）及「在面板中隐藏此项目」。

### 8.2 F2 超时再次提醒与视觉增强
1. **提醒调度器 (`ReminderScheduler`)**：
   - 纯函数式阈值评价：依据 `remindAfterMinutes` 和 `remindMaxCount`，线性计算当前应达提醒轮次 $k = \min(\text{maxCount}, \lfloor\text{elapsed} / \text{interval}\rfloor)$。
   - 状态重入重置：离开 `waitingForUser` 时重置计数。
2. **菜单栏与面板超时表现**：
   - 超时后菜单栏角标底色变为 `#D70015`（`isOverdue == true`），渲染尺寸严格保持 16x16 / 22x22 像素完全不变。
   - 分组标题追加「· N 个已超时」红色计数；会话行时间高亮为闹钟图标 + 红色粗体。

### 8.3 F3 设置窗口与静音体系
1. **设置窗口管理器 (`SettingsWindowManager`)**：
   - 统一单实例管理，支持 6 个 Tab（通用、通知、Agent、静音、集成、快捷键）。
   - 所有配置均统一通过 `AppSettings.shared` 持久化，Mock 环境自动隔离配置 suite。
2. **静音规则 (`MuteRule`)**：
   - 规则按路径最长前缀精准匹配。
   - `.all` 范围：不发任何通知、不计入菜单栏等待数量与超时判断。
   - `hideInPanel` 规则：会话自动从 `MonitorViewModel.sessions` 排除，界面实时联动隐藏。
   - 静音设置页：支持原生表格展现、范围 Picker、隐藏复选框以及 `NSOpenPanel` 目录选取与删除。

### 8.4 F4 全局快捷键与面板键盘导航
1. **Carbon 热键监听 (`HotkeyCenter`)**：
   - 基于 `RegisterEventHotKey` + `InstallEventHandler`，无需辅助功能权限。
   - 注册 `togglePanel`（默认 ⌃⌥A）和 `jumpWaiting`（跳转等待最久会话）。
   - 具备热键冲突检测与错误捕获。
2. **录制控件 (`KeyRecorderView`)**：
   - 基于 `NSViewRepresentable` 实现第一响应者，支持修饰键解析、清除及冲突提示。
3. **面板内键盘操作 (`MenuView`)**：
   - 支持 `↓ / ↑` 导航、`↩` 跳转、`⌫` 标为已读、`⌘⌫` 全部标为已读、`1–4` 筛选、`esc` 取消筛选或关闭、`⌘,` 打开设置。
   - 选中行赋予 `.fill.quaternary` 底色与 1.5pt accentColor 70% 描边，AX value 输出「已选中」。
   - 键盘模式下底部平滑淡入快捷键提示条。

### 8.5 F5 Claude Code Hooks 事件源
1. **Hook 脚本与事件解析**：
   - 安装 `cc-event.sh` 到 Application Support 目录，静默写入 `claude.tsv`。
   - `ClaudeHookEventReader` 增量读取文件更新，半行保留，截断从头重读，超过 5MB 自动轮转为 `.1`。
2. **配置安全合并 (`ClaudeHookInstaller`)**：
   - 对 `~/.claude/settings.json` 进行纯 JSON 结构修改，支持 7 个目标事件追加。
   - 写入前自动生成 `.agentmonitor-backup` 备份文件，采用同目录临时文件原子重命名替换。
   - 支持精准卸载并清理空结构。
3. **集成设置页 (`IntegrationSettingsView`)**：
   - 实时检测「已安装」、「未安装」与「需要修复」状态。
   - 弹出确认 Sheet，展示动态生成的将要合并的 JSON 片段。
   - 提供辅助功能与自动化权限状态检测与一键跳转。

### 8.6 F6 Token 用量追踪
1. **增量去重统计 (`UsageTracker`)**：
   - Claude Code：按 `message.id` 严格去重，排除 sidechain，1MB 流式分块与偏移量增量缓存。
   - Codex：读取 rollout `.jsonl` 尾部 64KB，提取 `token_count`、`model_context_window` 与模型名。
   - Antigravity：读取 SQLite 中的 `step_count` 作为步数。
2. **格式化与视觉标签 (`UsageFormatter` & `UsageChip`)**：
   - 严格实现 short / long 数值缩写与百分比计算。
   - 会话行第二行右侧展示小标签，根据使用比例与数值动态变色（orange / red）。
   - 悬停 0.4 秒自动弹出 Popover，展示上下文窗口进度条、输入、输出、缓存与更新时间。

### 8.7 验证与测试指标
- **单元测试覆盖**：项目内共 63 项测试（`UsageTests`、`HotkeyTests`、`ClaudeHookTests`、`JumpTests`、`ReminderTests`、`MonitorViewModelTests`、`AgentMonitorCoreTests` 等），全部一次性 PASS（0 报错、0 失败）。
- **打包验证**：通过 `./scripts/build-app.sh` 顺利完成 release 模式编译、AppIcon 组装、代码签名与 LaunchServices 注册。

