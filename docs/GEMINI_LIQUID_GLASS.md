# 任务：用 Liquid Glass（液态玻璃）重新设计 Agent Monitor

本文是完整的开发方案，由你（Gemini）实现，Claude 负责 review。

动手前请先通读全文。遇到本文没写清楚的地方，按 Apple HIG 中 Liquid Glass 的原则自行判断，并在 `docs/HANDOFF.md` 里写下你的取舍和理由。

---

## 0. 已经和用户确定的决策（不要更改）

| 项 | 决定 |
|---|---|
| 最低系统版本 | 提到 **macOS 26**，只写一套原生 Liquid Glass 代码，不做 `#available` 降级 |
| 范围 | **弹窗面板 + 菜单栏图标**。系统通知不在本次范围内 |
| 改动深度 | **可以重新组织布局**。信息和功能一项都不能少，但呈现方式可以变 |
| 配色 | **玻璃本身保持中性，颜色只用来点缀**。橙、绿、蓝只出现在状态点、数字、时间、标签文字和图标上，不给大面积玻璃或背景上色 |

## 1. 硬性规则（沿用之前几轮）

- 只读访问 Agent 数据，不碰凭据，不联网。**`Sources/AgentMonitorCore/` 下的 Adapters、SessionStore、Models 的逻辑一律不改**，本次只动 UI。
- 每个条目单独提交，提交信息带上条目编号，例如 `feat(panel): glass filter bar (#3)`。
- `docs/design/*.dc.html` 是旧的视觉稿，**不要删也不要改**。本次以本文为准，旧稿里的颜色和尺寸不再适用。
- 每次提交前都要通过 `swift build` 和 `swift test`。
- 不准自动 `killall` 系统进程。

---

## 2. 设计原则（实现时对照这几条）

1. **两个层级**：
   - **内容层**：会话列表、分组标题、详情文字。这一层**不用玻璃**，直接放在面板背景上。
   - **控件层**：筛选条、头部按钮、底部操作按钮。这一层用玻璃，浮在内容层之上。
   - **不要玻璃叠玻璃**。需要相邻的多块玻璃，一律放进同一个 `GlassEffectContainer`。
2. **语义色代替 hex**：
   - 文字用 `.primary`、`.secondary`、`.tertiary`；
   - 填充用 `.fill.quaternary`、`.quinary` 等；
   - 状态色用系统色 `Color.orange`、`.green`、`.blue`、`.gray`，它们会自动适配深浅色、提高对比度和降低透明度这几种系统设置。
   - 删除 `Palette` 和 `Color(hex:)`。品牌图标除外（例如 dsh 的 `#4D6BFE` 在 `IconManager` 里，不要动）。
3. **同心圆角**：外层面板、内层控件、行的 hover 底色，圆角要层层同心。优先用 `ConcentricRectangle` / `.containerShape`。做不到时，统一用 `RoundedRectangle(cornerRadius:style: .continuous)`，并按「外圆角 − 内边距 = 内圆角」来推算。
4. **动效**：
   - 筛选切换、空闲分组展开、底部按钮出现或消失，都用玻璃的融合/变形动效（`glassEffectID` + `@Namespace`），动画曲线用 `.smooth` 或 `.bouncy`；
   - 不要自己写透明度的淡入淡出来冒充变形效果。

---

## 3. 新的面板布局

宽度保持 **384pt**。整体结构如下：

```
┌──────────────────────────────────────────┐
│ Agent 会话                    (🔔) (⚙︎)   │ ← A 头部：标题 + 右侧玻璃圆形按钮组
│ 5 个活跃 · 4 个 agent                     │
│ (● 2 等你)(● 1 已完成)(● 2 运行中)(2 空闲) │ ← B 筛选条：4 枚玻璃胶囊
├╌╌╌╌╌╌╌╌╌╌╌╌ 柔和的滚动边缘 ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤
│ ● 等你回复                                │ ← C 会话列表（内容层，可滚动）
│ [图标] 重构 Cookie 同步逻辑        4 分钟  │
│        Codex · 115-cookie                │
│        ┌ 等待授权  git push --force … ┐   │    详情浅底框（中性填充）
│ ● 已完成                                  │
│ [图标] Loon 规则整理            12 分钟前  │
│        Antigravity · loon-rea            │
│        ✓ 已生成 3 个文件，测试全部通过    │
│ ● 运行中 …                                │
│ ▸ 空闲 · 2 个会话                          │
│                                          │
│            ( ✓ 全部标为已读 )              │ ← D 底部浮动玻璃胶囊（仅在有已完成会话时出现）
└──────────────────────────────────────────┘
```

和旧版相比的变化：

- 旧的 4 张彩色统计卡片，改成一行**玻璃筛选胶囊**。
- 铃铛和设置按钮从底栏移到**头部右侧**。
- 底栏的分隔线和整条底栏删除。「全部标为已读」改成**浮在列表上方的玻璃胶囊**。

### A. 头部 `PanelHeader`
- 左侧：
  - 标题「Agent 会话」用 `.headline`；
  - 副标题「N 个活跃 · N 个 agent」用 `.caption`，颜色 `.secondary`；
  - 两行竖排，计算逻辑保持不变。
- 右侧：两个圆形图标按钮，放在同一个 `GlassEffectContainer(spacing: 8)` 里。
  - 两个按钮都用 `.buttonStyle(.glass)`、`.buttonBorderShape(.circle)`、`.controlSize(.regular)`。
  - **铃铛**：
    - 正常状态显示 `bell`；
    - 暂停时显示 `bell.slash.fill`，图标染 `.orange`。这是唯一允许有颜色的按钮，只给图标着色，玻璃本身不要 tint。
    - 保留 `.help(...)` 文字提示。
    - 加上 `accessibilityLabel`，文字为「暂停通知 1 小时」或「恢复通知」。
  - **设置**：
    - 显示 `slider.horizontal.3`，点击弹出 `Menu`，内容和现在一样：开机启动 Toggle、分隔线、退出。
    - `Menu` 用 `.menuStyle(.button)` + `.buttonStyle(.glass)` + `.menuIndicator(.hidden)`。
    - 如果实测 `Menu` 不吃这套样式，改为给 label 手动加 `.glassEffect(.regular.interactive(), in: .circle)`。用了哪种写法，在 HANDOFF 里注明。

### B. 筛选条 `FilterBar`
- 4 枚胶囊等宽排开，放在一个 `GlassEffectContainer(spacing: 6)` 里。
- 每枚胶囊的内容为 `● 数字 标签`：
  - 圆点 6pt，用状态色；空闲用 `.gray`。
  - 数字用 `.callout`、semibold、`.monospacedDigit()`，用状态色。
  - 标签用 `.caption`，颜色 `.secondary`。
- 胶囊形状为 `.capsule`。
  - 未选中：`.glassEffect(.regular.interactive(), in: .capsule)`。
  - 选中：`.glassEffect(.regular.tint(状态色.opacity(0.18)).interactive(), in: .capsule)`，标签变成 `.primary` + semibold。这是配色上唯一允许的「轻度上色」，透明度不要超过 0.2。
- 点击行为不变：点一次筛选该状态，再点一次取消。
  - 切换时用 `withAnimation(.bouncy)`。
  - 每枚胶囊挂上 `glassEffectID(state, in: ns)`，让选中态平滑变形过去。
- 数量为 0 的胶囊仍然显示，但整体降到 `.tertiary` 并禁用点击。

### C. 会话列表 `SessionList`
- 列表外层是 `ScrollView`。
  - **给面板设最大高度**：列表区域 `maxHeight` 设为 520pt。会话少时高度随内容收缩，多时滚动。现在 `fixedSize` 的写法在会话很多时会把面板撑出屏幕，这次一并修掉。
  - 加 `.scrollEdgeEffectStyle(.soft, for: [.top, .bottom])`，让内容滚到筛选条和底部按钮下面时自然淡出。
- **分组标题**：
  - 6pt 圆点（状态色）+ `.caption`、semibold、`.secondary`。
  - 分组顺序不变：等你回复 → 已完成 → 运行中 → 空闲。
- **合并会话行**：把现在 4 个几乎一样的 `waitingRow`、`completedRow`、`runningRow`、`idleRow` 合并成一个 `SessionRow(session:)`。共同部分包括：
  - 图标 34pt；
  - 标题用 `.body` / 13pt semibold，单行；
  - 右上角时间；
  - 副标题「Agent · 目录名」。

  每种状态不同的部分，用一个 `@ViewBuilder accessory` 来分支：
  - **等你回复**：
    - 详情浅底框的背景用 `.fill.quaternary`，圆角 8 continuous。**不要用橙色底**。
    - 框里「等待授权」或「在问你」这几个字用 `.orange` semibold；
    - 命令用 `.system(.callout, design: .monospaced)`，单行，中间截断（`.truncationMode(.middle)`）。
    - 右上角时间用 `.orange`。
  - **已完成**：
    - 前面放 `checkmark.circle.fill`，`.symbolRenderingMode(.palette)` 用白色加 `.green`，或者直接用 `.green`；
    - 详情用 `.secondary`；
    - 时间用 `.secondary`。
  - **运行中**：
    - 前面放脉冲点，保留 `PulsingDotView`，颜色改成 `.blue`；
    - 详情或「正在思考…」用 `.secondary`；
    - 时间用 `TimelineView` 每秒刷新，`.blue`，`monospacedDigit`。
  - **空闲**：只显示标题、副标题和时间，整行文字降一级（标题用 `.secondary`）。
- **hover**：
  - 改成**行内**的 `@State isHovered`。
  - 底色为 `.fill.quaternary`，圆角 12 continuous（和面板圆角同心）。
  - hover 状态不再放到 `MonitorViewModel.hoveredSessionId` 里。现在鼠标每移动一行，都会让整个面板重绘，这次一起修掉。
  - 修完后从 ViewModel 里删掉 `hoveredSessionId`。
- **点击**：行为保持不变，执行 `markAsRead` + `activateApp(...)`。`activateApp` 函数原样保留。
- **空闲分组**：
  - 折叠头是一行「▸ 空闲 · N 个会话」，chevron 旋转 90° 表示展开状态，用 `.rotationEffect` 加动画。
  - 展开时子行使用 `.transition(.opacity.combined(with: .move(edge: .top)))`。
  - 筛选为「空闲」时强制展开，这个逻辑保持不变。
- **空状态**：
  - 用 `ContentUnavailableView`，标题「暂无活跃会话」，图标 `rectangle.stack`，描述「各 agent 启动后将在此处自动汇总」。
  - 如果在 384pt 宽度下显示得太大，就按 SF Symbol 加两行文字自己搭一个。

### D. 底部「全部标为已读」
- 用 `.safeAreaInset(edge: .bottom)` 把一个玻璃胶囊按钮浮在列表底部，居中放置：
  - `Label("全部标为已读", systemImage: "checkmark")`；
  - `.buttonStyle(.glass)`、`.controlSize(.large)`。
- **只在有 `.completed` 会话时显示**。`SessionStore.markAllAsRead()` 只处理 completed 状态，没有已完成会话时这个按钮没有意义。
- 出现和消失用 `.glassEffectTransition(.materialize)`，并包在 `withAnimation` 里。

### E. 面板背景
- 删除 `palette.panelBg` 这层半透明纯色。
- **先做第 4 节的「#1 背景探针」**，根据实测结果决定背景的处理方式。

---

## 4. 工作条目（按顺序做，一项一提交）

### #1 背景探针 + 升级平台（P0，先做）

1. `Package.swift`：
   - `swift-tools-version` 升到 **6.2**；
   - `platforms` 改为 `.macOS(.v26)`。
   - 本机 SDK 已确认支持：`v26` 需要 tools 6.2。
2. `scripts/build-app.sh`：`LSMinimumSystemVersion` 改为 `26.0`。
3. README 里「环境要求」改为 macOS 26.0+。
4. 在 `MenuView.body` 上**只删掉** `.background(palette.panelBg)`，其他都不动。然后打包、截图，看看 macOS 26/27 下 `MenuBarExtra(.window)` 默认画出来的窗口背景是什么效果。根据结果三选一：
   - **a. 系统已经画了玻璃或材质背景**：就保持不加背景，这是首选。
   - **b. 背景是空的或者不透明**：给根视图加 `.background(.regularMaterial)`（这是内容层的材质，**不要**给整个面板加 `glassEffect`）。
   - **c. 系统背景的圆角和内容不同心**：记录系统窗口的圆角，作为第 2 节第 3 条的外圆角。

   把截图和最终选的是哪一项写进 HANDOFF，然后再进行后续条目。

### #2 拆文件 + 语义样式（P0）

先做纯结构重构，保证视觉不出大偏差，方便单独 review。

- 把 `MenuView.swift`（728 行）拆成以下文件：
  ```
  Sources/AgentMonitor/Panel/
    MenuView.swift          // 根视图，只负责组合各部分 + 强制配色的环境变量
    PanelHeader.swift
    FilterBar.swift
    SessionList.swift
    SessionRow.swift        // 合并后的单一行视图
    StatusStyle.swift       // SessionState -> 颜色 / 标题 / 时间格式
    PulsingDotView.swift
  ```
- `StatusStyle` 统一提供这几样：
  - `extension SessionState { var tint: Color; var title: String; var shortTitle: String }`；
  - `formattedTime` 的逻辑，挪进去时**原样保留**，包括「刚刚」「N 分钟」「N 分钟前」「m:ss」这几种格式。
- 删除 `Palette` 和 `Color(hex:)`。先在 `rg 'Color\(hex' Sources` 里确认，除 `IconManager` 外已经没有其他调用。
- 保留 `AGENT_MONITOR_COLOR_SCHEME`、`AGENT_MONITOR_MOCK_DATA`、`AGENT_MONITOR_MENU_STATE` 这几个环境变量的行为，截图脚本要靠它们。

### #3 头部 + 筛选条（P0）
按第 3 节 A、B 实现。

### #4 会话列表 + 行（P0）
按第 3 节 C 实现，包括最大高度、滚动边缘、行内 hover，以及删除 `hoveredSessionId`。

### #5 底部浮动按钮 + 动效（P1）
按第 3 节 D 实现，同时统一检查第 2 节第 4 条的动效。

### #6 菜单栏图标微调（P1）

macOS 26 的菜单栏是透明的，图标需要在任意壁纸上都看得清。改动只限 `MenuBarIconRenderer`：

- **主图形**：
  - 线宽 1.4 改成 **1.5**，和 SF Symbols 在 regular 字重、菜单栏尺寸下的观感对齐；
  - 其他几何尺寸不变。
- **状态点**：
  - 改用系统色 `NSColor.systemOrange`、`.systemGreen`、`.systemBlue`；
  - 在点的外圈「挖」出 1pt 透明描边，用 `.clear` 混合模式擦除。这样点在任何背景上都和主图形分得开（类似 SF Symbols 里 badge 的做法）。
- **等待数徽标**：
  - 底色由 `#C2410C` 改为 `NSColor.systemOrange`；
  - 文字仍为白色，改用 `.semibold`；
  - 高度 15、最小宽度 16 不变。
  - 改完核对一下在浅色菜单栏上，白字对橙底的对比度是否足够。如果不够，把底色改成 `systemOrange` 再加深 15% 的版本，并在 HANDOFF 里说明。
- **template 规则不变**：没有颜色时用 template 图，有颜色时用非 template 图。
- **测试**：
  - `size(...)` 和 `isTemplate(...)` 的现有测试必须原样通过（几何尺寸没变）；
  - 如果有测试断言了具体颜色，按新的系统色更新，并在提交说明里写清楚。

### #7 截图脚本 + 文档（P1）

- `scripts/capture-all.swift` 增加这几种面板截图：
  - 筛选「等你」时的状态，新增环境变量 `AGENT_MONITOR_FILTER=waiting|completed|running|idle`，由 `MonitorViewModel.init` 读取；
  - 空闲分组展开，新增 `AGENT_MONITOR_IDLE_EXPANDED=1`；
  - 空状态，新增 `AGENT_MONITOR_MOCK_DATA=empty`。
  - 每种都要有浅色和深色两张。
- 重新生成 `docs/screenshots/` 下的全部截图。
- README 的「UI 与交互设计」一节按新设计重写。
- 在 `docs/HANDOFF.md` 追加本轮小结，内容包括：
  - 每个条目对应的提交；
  - #1 选了哪种背景方案；
  - `Menu` 样式用的是哪种写法；
  - 已知问题。

---

## 5. 验收清单（Claude review 时会逐条检查）

**功能不退化**
- [ ] 4 种状态的分组、排序、计数和旧版一致。
- [ ] 筛选：点一次筛选，再点一次取消；筛选为空闲时自动展开。
- [ ] 点击会话行：标为已读，并拉起对应的 App。
- [ ] 暂停通知、开机启动、退出都能正常使用。
- [ ] 运行中的计时每秒刷新。
- [ ] 跟随系统切换深浅色时，面板不会被锁定在旧外观（之前修过的 #3 不能回退）。

**视觉**
- [ ] 控件层（筛选条、头部按钮、底部按钮）用的是真正的 `glassEffect` 或 glass 按钮样式；内容层的行**没有**用玻璃。
- [ ] 没有玻璃叠玻璃。相邻的玻璃都在 `GlassEffectContainer` 里。
- [ ] `Sources/AgentMonitor` 里除 `IconManager` 外，没有残留的 hex 颜色。
- [ ] 浅色和深色模式下截图都清晰可读。在「系统设置 › 辅助功能 › 显示」里打开「降低透明度」和「增加对比度」后，再各截一张图检查，这几张截图放在 HANDOFF 里，不进 `docs/screenshots`。
- [ ] 会话很多时（可以临时把 mock 数据加到 15 条以上），面板高度不超过上限，可以滚动，滚动边缘有柔和过渡。

**工程**
- [ ] `swift build`、`swift test`、`./scripts/build-app.sh` 全部通过，没有新增警告。
- [ ] `AgentMonitorCore` 只有 `MenuBarIconRenderer` 有改动。
- [ ] 每个条目一个提交，提交信息带编号。

## 6. 不要做的事

- 不要给会话行、分组或者整个面板加 `glassEffect`。
- 不要给玻璃上大面积状态色。唯一的例外是第 3 节 B 里选中筛选胶囊时那层 ≤0.2 的淡色。
- 不要引入第三方依赖。
- 不要修改通知（`Notifier.swift`、`NotificationFormatter`）和 App 图标（`make-icon.swift`）。
