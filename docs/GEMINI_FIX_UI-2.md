# 任务：UI 修复第二轮

这份任务基于对 `aa02374..a7beba9` 这 5 个提交的 review。

菜单栏图标、面板、通知的文字内容这几项，都已经和设计稿基本一致，做得不错。

下面这些问题还要修。规则和上一轮一样：
- 每一项单独提交，提交信息写上条目编号，例如 `fix(notification): ... (#1)`；
- 遵守硬性原则：只读访问、不碰凭据、不联网；
- 不准修改 `docs/design/` 里的文件。

## #1 通知左侧仍然是系统默认的占位图标（P0）

截图 `docs/screenshots/notification-*.png` 里，左侧仍然是灰色的占位图。我检查过 `AppIcon.icns`，文件本身没问题（黑底、白色图形、橙点，各尺寸都齐全），`Info.plist` 里也写了 `CFBundleIconFile`。

原因是：这个 bundle id 第一次发通知时还没有图标，通知中心和 LaunchServices 把那时的结果缓存了下来。只在 README 里写一条手动命令是不够的。

改法：
1. `scripts/build-app.sh` 每次打包时，把 `CFBundleVersion` 设成递增值，比如 `date +%Y%m%d%H%M%S`。系统按版本号缓存图标，版本号变了就会重新读取。
2. 签名之后，在脚本里自动执行一次：
   ```
   lsregister -f build/AgentMonitor.app
   ```
   `lsregister` 的完整路径见 README 第 56 行。
3. 验收：打包，启动，触发 `AGENT_MONITOR_TEST_NOTIFICATION=completed`，截图确认左侧显示的是 App 图标。
   - 如果仍是占位图，在 HANDOFF 里写明，并记录试过哪些方法。
   - **不要**自动 `killall` 任何系统进程。

## #2 DeepSeek 鲸鱼图标是黑色的，应该是 DeepSeek 蓝（P1）

原因：dsh 的 `favicon.svg` 里写死的是 `fill="#000"`，没有 `currentColor`。所以 `IconManager.loadDshIcon` 里替换 `currentColor` 的那一步什么都没改到。

改法：
- 不要做字符串替换。先把 SVG 画到一张透明图上，再用 `.sourceAtop` 合成方式铺满 `#4D6BFE`。这样无论 SVG 原本是什么颜色，都能染上色。
- **磁盘缓存要失效**：`~/Library/Caches/com.cy.agentmonitor/icons/dsh.png` 已经存成了黑色版本，而 `cachedIconPNGURL` 只要文件存在就直接用。
  - 改法：缓存文件名带上版本号，比如 `<kind>-v2.png`；
  - 或者每次启动后的第一次调用时，重新生成一次。

## #3 面板会被锁死在启动时的深色或浅色模式（P1）

`MenuView.body` 末尾无条件地调用了：

```swift
.preferredColorScheme(isDark ? .dark : .light)
```

而 `isDark` 本身又是从环境里的 `colorScheme` 读出来的。这样一来，第一次渲染时是浅色，就会一直强制浅色。之后用户切换到深色模式，`colorScheme` 读到的仍然是被强制的浅色，面板永远不会跟着变。

改法：只有设置了 `AGENT_MONITOR_COLOR_SCHEME` 环境变量时，才调用 `.preferredColorScheme`；正常运行时完全跟随系统。

验收：App 运行期间，在"系统设置"里切换深色和浅色，面板要跟着变。可以用 `osascript` 切换，但测试结束后**必须恢复成原来的设置**（见 #5）。

## #4 通知正文会误删命令里的星号（P1）

`NotificationFormatter.cleanBody` 会对所有正文做 Markdown 清理，包括等待授权时的命令。比如：
- `rm *.log && ls *.txt` 会被当成斜体，变成 `rm .log && ls .txt`；
- `__init__` 这类内容也会被改掉。

改法：
- `session.detailIsCommand == true` 时，不做 Markdown 清理，只合并空白、截断长度。
- 另外，adapter 把 detail 截到了 80 个字符，链接可能被截成一半，比如 `[docs/x.md](file:///Us`。遇到这种没闭合的链接，要保留 `[` 里的文字，去掉后面不完整的部分。
- 给这两种情况都补上单元测试。

## #5 截图脚本会改动用户的系统设置（P1）

`scripts/capture-all.swift` 有三个问题：
- 它会切换系统的深色模式，结束时**固定恢复成浅色**。如果用户原本用的是深色，就被改掉了。
- 它用 `pkill -9 -x AgentMonitor` 杀掉用户正在用的实例，结束后也不会重新启动。
- 菜单栏的浅色、深色两组截图完全一样。原因是在这台机器的系统版本上，菜单栏的外观跟随壁纸，而不是跟随系统的深色模式，所以"浅色菜单栏"这个场景其实没有测到。

改法：
1. 开始前读取当前的深色模式设置，结束时恢复原值。
2. 开始前记录 AgentMonitor 是否在运行；如果在运行，结束后用 `open build/AgentMonitor.app` 重新启动它。
3. 在文件头部注释里写明：这个脚本会临时切换外观、重启 App。
4. 浅色菜单栏要验证的是：在浅色外观下，图标的线条是深色的。给 `MenuBarIconRenderer` 补一个单元测试：
   - 分别在 `NSAppearance(named: .aqua)` 和 `.darkAqua` 下调用 `performAsCurrentDrawingAppearance`，把图片画成位图；
   - 取图形线条上的一个像素（例如圆角矩形左边线的中点），断言浅色外观下是深色、深色外观下是浅色；
   - 删掉那组重复的"浅色菜单栏"截图，或者在 HANDOFF 里说明它为什么和深色一样。

## 验收

- `swift build`、`swift test` 通过。
- 重新截图：至少要有通知（确认左侧是 App 图标）和面板，包括 DeepSeek 图标染蓝之后的样子。截图更新到 `docs/screenshots/`。
- 在 HANDOFF 里追加本轮记录，逐条说明。
