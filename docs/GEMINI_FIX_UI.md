# 任务：修复菜单栏图标、通知外观，并让面板对齐设计稿

请先读：`docs/GEMINI_PROMPT.md` 里的"UI（已定稿）"和"通知"两节，以及 `docs/design/` 下的三个设计稿：
- `Main.dc.html`：浅色面板
- `Dark.dc.html`：深色面板
- `States.dc.html`：菜单栏图标的各个状态和通知样式

设计稿里的内联样式就是精确规格。硬性原则不变：只读访问、不碰凭据、不联网。每一项单独提交，提交信息里写条目编号，例如 `fix(menubar): render label as NSImage (#1)`。

## 用户实测到的问题

1. 菜单栏只有一块空白，看不到图标。因此面板也打不开。
2. 通知左侧显示的是系统默认的空白占位图标，不是设计稿里的图标。
3. 通知里看不出是哪个 agent、什么状态。设计稿里，状态是靠图标上的彩色圆点表达的。

---

## #1 菜单栏图标是空白的（P0）

**原因**：`MenuBarExtra` 的 label 只会渲染 `Image` 和 `Text`。`MenuBarLabelView` 里的 `Shape`、`Circle`、带背景的胶囊角标，都会被系统丢掉，所以显示成一块空白。

**改法**：
- 新建 `MenuBarIconRenderer`。把图标、状态点、等待数量角标、划线铃铛**全部画进一张 `NSImage`**，label 里只放 `Image(nsImage:)`。
- 各元素的尺寸和坐标照 `States.dc.html` 的 SVG 来：
  - 16pt 的图标：圆角矩形 `x=1.5 y=3.2 w=11 h=10 rx=2.6`，两条横线，线宽 1.4。
  - 状态点：`cx=12.9 cy=3.6 r=2.7`。
  - 角标：高 15pt，最小宽 16pt，底色 `#C2410C`，白色 10.5pt 粗体数字。
  - 铃铛：13pt。
  - 元素间距 5pt。
- 图片要用 `@2x` 绘制，保证 Retina 屏清晰：用 `NSImage(size:flipped:drawingHandler:)`，系统会按屏幕倍率自动重绘。
- **深色和浅色菜单栏都要能看清**：
  - **没有状态点、也没有角标时**：图形用黑色画，并设置 `isTemplate = true`，交给系统着色。
  - **有彩色元素时**：设置 `isTemplate = false`。图形和铃铛在 drawingHandler 里用 `NSColor.labelColor` 画，这样它会在绘制时按菜单栏当前的外观取色。
    - 如果实测发现在 SwiftUI 的 label 里取色不跟随菜单栏外观，就把菜单栏这部分改用 AppKit 的 `NSStatusItem` 实现：图片放在 `button.image` 上，面板改用 `NSPanel` 承载 `MenuView`，风格是无边框、跟随按钮定位、失去焦点后自动关闭。改动面最小的做法优先。
- 删掉 `MenuBarLabelView` 和 `AgentMonitorIconShape`，或者改成只负责调用 renderer。

**验收**：用 `screencapture` 截下菜单栏，截下面这几种状态。截图都放到 `docs/screenshots/`，并在 HANDOFF 里引用。
- 浅色菜单栏、深色菜单栏各截一次；
- 无活动、运行中、已完成、等你（带数量角标）、暂停通知，每种状态各截一次。可以加一个调试环境变量来强制指定状态。

## #2 通知图标（P0）

macOS 规定：通知**左侧的大图标永远是 App 自己的图标**，没法按通知替换。每条通知只能在**右侧**附带一张缩略图。所以要做两件事：

**a. 给 App 做图标**：照 `States.dc.html` 里通知左侧的图标来做。
- 样式：黑色 `#1D1D1F` 圆角方块，里面是白色的同款图形，右上角一个圆点。App 图标只能用一个固定颜色，圆点用橙色 `#F0841C`。
- 在 `scripts/build-app.sh` 里生成，不要依赖 Xcode：
  - 用一个小的 Swift 脚本（`scripts/make-icon.swift`），通过 AppKit 画出 16、32、64、128、256、512、1024 各尺寸的 PNG，放进 `AppIcon.iconset`；
  - 用 `/usr/bin/iconutil -c icns` 转成 `AppIcon.icns`，放到 `Contents/Resources/`；
  - 在 Info.plist 里加上 `CFBundleIconFile = AppIcon`。
  - macOS 的图标圆角规范：内容区域是 824/1024，圆角半径约为 185/1024。
- 改完之后，通知中心可能还缓存着旧图标。在 README 里写上刷新方法：
  - 先执行 `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f build/AgentMonitor.app`；
  - 再退出并重新打开 App。

**b. 每条通知附带对应 agent 的官方图标**：用 `UNNotificationAttachment`。
- 第一次需要时，用 `IconManager` 取到图标，导出成 PNG（128px 以上），缓存到 `~/Library/Caches/com.cy.agentmonitor/icons/<kind>.png`。
- **注意**：系统接收附件时会把文件"移走"。所以每次发通知前，都要把缓存的 PNG 复制一份到临时文件，再用这份副本创建附件；不能直接把缓存文件交出去。
- 附件创建失败时，照常发送不带附件的通知，不能因此丢掉这条通知。

## #3 通知内容对齐设计稿（P1）

设计稿里的通知（`States.dc.html`）是这样的：
- 标题：`Codex · 重构 Cookie 同步逻辑`，超长时单行截断；
- 副标题：`等待授权`，或 `已完成 · 用时 6 分 12 秒`；
- 正文：detail；等待授权时是命令。

现在的实现结构基本是对的，但要修正下面几点：
- **标题**：agent 的显示名加上会话标题。会话标题要先 trim，并且**去掉换行**。dsh 有的标题是 prompt 的开头，会带换行，比如"你是 macOS 原生逆向分析员。任…"，要截到 40 字以内。
- **副标题**：等你回复的通知要区分"等待授权"和"在问你"，取 `waitingLabel`。
- **正文**：去掉 Markdown 符号（`**`、反引号、`#` 标题、`[文字](链接)` 只保留文字），合并多余的空行，截到 120 字以内。现在的正文里会直接出现 `**` 和 `[docs/...](file://...)` 这类原文。
- 设置 `threadIdentifier = session.id`，同一个会话的通知归为一组。

## #4 面板逐项对齐设计稿（P1）

#1 修好后才能打开面板。下面是对照设计稿发现的偏差。颜色一律照设计稿取值，浅色和深色分别用两套。建议在 `MenuView` 里集中定义一个 `Palette`，按 `colorScheme` 选用。

| 位置 | 设计稿（浅色 / 深色） | 现状 |
|---|---|---|
| 面板背景 | `rgba(248,248,250,0.8)` / `rgba(38,38,42,0.78)`，加毛玻璃；描边 0.5pt；阴影 `0 20 50 rgba(30,30,50,0.22)` | 用的是 `.ultraThinMaterial`。另外 `MenuBarExtra(.window)` 自己已经带了窗口背景和圆角，会和这层叠在一起。需要确认没有出现双层背景或双层圆角：只保留一层，并且外观以设计稿为准 |
| 已完成卡片文字 | `#1A6E30` / `#5FDC7E`（标签用 `#8DE6A2`） | 用的是 `#248A3D`，对比度不够 |
| 空闲卡片 | 背景 `rgba(0,0,0,0.05)` / `rgba(255,255,255,0.07)`；数字 `#48484A` / `#D1D1D6` | 背景是灰色 14% |
| "等你"卡片标签 | `#8A3604` / `#FFC27A`，数字 `#9A3C05` / `#FFB24D` | 数字和标签用了同一个颜色 |
| 运行中卡片标签 | `#0052B3` / `#9CCBFF` | — |
| 分组标题 | `#636366` / `#A1A1A6`，内边距 `6 8 0` | 用的是 `.secondary`，基本可以 |
| 行内时间："等你" | `#9A3C05` / `#FFB24D`，字重 500 | 用的是 `#F0841C`，在浅色背景上对比度不够 |
| 行内时间："运行中" | `#0052B3` / `#6CB4FF` | 用的是 `#0A84FF` |
| 行内时间："已完成" | 显示"12 分钟**前**" | 少了"前"字 |
| 行内时间："等你" | 显示**已经等了多久**，用 `stateSince` 计算 | 用的是 `lastActivity` |
| 等你框 | 背景 `rgba(255,149,0,0.12)` / `rgba(255,159,10,0.14)`；标签 `#9A3C05` / `#FFB24D`；详情 `#3A3A3C` / `#E5E5EA`；上边距 4pt | 标签颜色写死成浅色模式的值，深色模式下看不清；上边距是 2pt |
| 已完成行的结果文字 | `#3A3A3C` / `#E5E5EA`；对勾圆点 12pt，里面是白色勾 | 用的是 `.primary.opacity(0.85)`，可以接受 |
| 运行中行 | 整行垂直居中，内边距 `7 8`；圆点 6pt，外圈 1.8s 的扩散光环 | 顶部对齐，内边距 8 |
| agent 图标 | 34pt 的框加上 `-2pt` 外边距，视觉上是 30pt。官方 App 图标自带透明留白，放大一点才和设计稿一样大 | 30pt，看起来偏小 |
| 底部按钮 | 30×28pt，圆角 7pt；hover 时背景 `rgba(0,0,0,0.06)`；图标颜色 `#48484A` / `#C7C7CC` | 28×26pt |
| 标题和 cwd | 单行截断 | 要确认 dsh 那种带换行的标题会先去掉换行（同 #3） |

## 验收

1. `swift build`、`swift test` 通过；新增 `MenuBarIconRenderer` 的单元测试，覆盖各状态下图片的尺寸，以及 `isTemplate` 的取值。
2. 用 `scripts/build-app.sh` 打包后启动 App，然后截图：
   - 菜单栏各状态，深色、浅色各一套；
   - 面板的浅色和深色各一张；
   - 一条"已完成"通知、一条"等你"通知。可以加一个调试命令或环境变量，用来直接触发测试通知。

   截图放到 `docs/screenshots/`。截图要和设计稿放在一起，逐张对比后写进 HANDOFF。

   截图需要"屏幕录制"权限。如果没有这个权限，就停下来，在 HANDOFF 里写明，不要跳过。
3. 不准修改 `docs/design/` 里的文件。
