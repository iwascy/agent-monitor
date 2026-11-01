# 任务：Liquid Glass 重设计 · 修复轮

这份任务基于对 `c9a86e4..a95ac4f` 这 7 个提交的 review，对应的原方案是 `docs/GEMINI_LIQUID_GLASS.md`。

整体方向做对了，有几处做得不错：
- 拆分文件、换用语义色、行内 hover、合并后的 `SessionRow`、筛选胶囊的变形动效，都符合方案；
- 用 `@LocalState` 绕开 CLT 环境下缺少 `SwiftUIMacros` 的问题，这一点我实测过，是对的。

下面这些问题还要修。规则和上一轮一样：
- 每一项单独提交，提交信息写上条目编号，例如 `fix(panel): ... (#1)`；
- 遵守硬性原则：只读访问、不碰凭据、不联网；
- `AgentMonitorCore` 里除了 `MenuBarIconRenderer`，其他文件一律不改；
- 每次提交前都要通过 `swift build` 和 `swift test`。

---

## #1 会话多时，列表溢出并盖住头部（P0）

**现象**：看你自己生成的截图 `docs/screenshots/panel-idle-expanded-dark.png`：
- 「等你回复」分组画到了标题和筛选条上面；
- 列表底部被截掉了；
- 「全部标为已读」按钮也不见了，虽然 mock 数据里有已完成的会话。

HANDOFF 里写的「16 条数据压测，高度稳定在 620pt」和截图对不上。

**原因**：问题出在 `SessionList.swift` 末尾的这段写法：

```swift
.fixedSize(horizontal: false, vertical: true)
.frame(maxHeight: 520)
```

`fixedSize` 让 ScrollView 不再接受外面给的高度，直接按内容的完整高度来画。外层的 `frame(maxHeight:)` 只能限制框本身的大小，限制不住里面的内容，所以内容会上下溢出，也就不会出现滚动。

**改法**：
1. 删掉 ScrollView **外层**的 `.fixedSize(...)`。内层 VStack 上的那个可以保留。
2. 用 `onGeometryChange` 量出内容的实际高度，存到 `@LocalState private var contentHeight: CGFloat = 0`。
3. 给 ScrollView 设 `.frame(height: min(contentHeight, 520))`。这样会话少时面板收紧，会话多时固定为 520 并且可以滚动。
4. 量出的高度要把 `safeAreaInset` 里底部按钮的高度也算进去，否则最后一行会被按钮挡住。要么在量高度时把按钮高度一起算上，要么滚到底时给列表留出一段等高的空白。
5. 加上 `.scrollBounceBehavior(.basedOnSize)`，内容不够长时就不要有回弹。

**验收**：
- `capture-all.swift` 增加一组 `panel-large` 截图（`AGENT_MONITOR_MOCK_DATA=large` 加 `AGENT_MONITOR_IDLE_EXPANDED=1`），浅色和深色各一张；
- 重新生成 `panel-idle-expanded-*` 截图；
- 截图里头部和筛选条完整不被覆盖，列表可以滚动，「全部标为已读」可见；
- 同时确认会话少的 `panel-*` 截图里，面板仍然随内容收紧，没有出现大块空白。

## #2 筛选会卡死，没办法取消（P1）

**复现**：
1. 选中「已完成」筛选；
2. 点击那条已完成的会话；
3. 会话被标为已读，「已完成」的数量变成 0；
4. `FilterBar` 里 `.disabled(count == 0)` 把这枚**仍然处于选中状态**的胶囊禁用了，没法再点一次取消；
5. 列表一片空白，连空状态提示都不显示。

`filterState` 存在 ViewModel 里，所以重新打开面板还是卡在这个状态。

**改法**（两处都要改）：
1. 在 `MonitorViewModel` 里，`sessions` 每次更新后都检查一下：如果当前 `filterState` 对应状态的数量是 0，就把 `filterState` 设为 `nil`，并用 `withAnimation(.bouncy)` 包起来。这里说的「更新」包括 `onSessionsUpdated`、`markAsRead`、`markAllAsRead` 这几条路径。最好在 `sessions` 的 `didSet` 里统一处理。
2. 在 `FilterBar` 里，只有在「数量为 0 **而且**没有被选中」时才禁用胶囊。

**验收**：
- 在 HANDOFF 里写清楚按上面步骤手动复现的结果；
- 如果方便，把「数量归零时清空筛选」这段逻辑抽成纯函数，并补一个单元测试。不方便就在 HANDOFF 里说明原因。

## #3 菜单栏徽标对比度不够（P2）

**现象**：白字对 `systemOrange` 加深 15% 后的底色，对比度大约只有 3:1，而且字重从 bold 降成了 semibold。10.5pt 属于小字，按要求对比度至少要 4.5:1。原来的 `#C2410C` 大约是 5:1。

方案里写的「加深 15%」本身就不够，这是方案的问题，不是你的问题。

**改法**：
- 底色改成 `systemOrange` 的 sRGB 分量乘以 **0.65**。
  - 我估算的结果：浅色外观约 4.9:1，深色外观约 4.6:1。
  - 注意 0.70 不够，只有约 4.3:1。
- 或者直接恢复 `#C2410C`，约 5.2:1。
- 选其中一个，要求浅色和深色两种外观下白字对比度都 ≥ 4.5:1。`systemOrange` 是动态色，两种外观下的值不一样，两种都要算。把计算过程写进 HANDOFF。
- 字重恢复为 `.bold`。

**验收**：重新生成 `menubar-waiting-*` 和 `menubar-paused-*` 截图；`MenuBarIconRenderer` 的现有测试全部通过。

## #4 浅色模式下两个头部按钮长得不一样（P2）

**现象**：在 `panel-light.png` 里：
- 铃铛是白色的玻璃圆，带高光；
- 设置菜单是灰底的圆，没有玻璃质感。

HANDOFF 里说 `Menu` 套用 glass 样式「原生支持」，但截图显示效果并不一样。

**改法**：按原方案里写的备选写法来做：
- `Menu` 的 label 手动加 `.glassEffect(.regular.interactive(), in: .circle)`，尺寸和铃铛按钮对齐（先实测铃铛按钮的大小，再给 label 设同样的 `frame`）；
- `Menu` 本身改用 `.menuStyle(.button)` + `.buttonStyle(.plain)`，避免叠两层背景；
- 确保这两个按钮仍然在同一个 `GlassEffectContainer` 里。

**验收**：在 `panel-light.png` 和 `panel-dark.png` 里，两个按钮的大小、材质、阴影看起来一致。

## #5 筛选时底部按钮的显示条件（P3）

在「等你」筛选下，「全部标为已读」仍然会显示，但这时列表里一条已完成的会话都看不到，用户会不知道这个按钮作用在什么上。

**改法**：显示条件改成：存在已完成会话，**并且** `filterState` 为 `nil` 或 `.completed`。

**验收**：`panel-waiting-*` 截图里不再出现这个按钮。

## #6 小修与补材料（P3）

- 把 `LocalState` 从 `StatusStyle.swift` 移到单独的 `Panel/LocalState.swift`，并在注释里说明为什么不用 `@State`：CLT 环境缺少 `SwiftUIMacros` 插件。
- HANDOFF 5.2 节里 #7 的提交号写错了，`d95b18d` 应该是 `a95ac4f`。改正，并按同样格式追加本轮的提交表。
- 补交原方案验收清单要求的辅助功能截图：
  - 在「系统设置 › 辅助功能 › 显示」里分别打开「降低透明度」和「增加对比度」，各截一张浅色面板图；
  - 截图放在 `docs/screenshots/a11y/` 下，在 HANDOFF 里引用。
  - 这两个开关需要你手动切换，**截完图要恢复原设置**，并在 HANDOFF 里注明已经恢复。

---

## 验收总表（Claude review 时会逐条检查）

- [ ] `panel-large-*` 截图：头部不被覆盖，列表可以滚动，底部按钮可见。
- [ ] 会话少时，面板随内容收紧。
- [ ] 筛选「已完成」后把唯一一条标为已读，筛选会自动取消，不会卡死。
- [ ] 菜单栏徽标白字对比度 ≥ 4.5:1，HANDOFF 里有计算过程。
- [ ] 浅色和深色模式下，头部两个按钮外观一致。
- [ ] `panel-waiting-*` 截图里没有「全部标为已读」按钮。
- [ ] 辅助功能截图已提交，系统设置已恢复。
- [ ] `swift build`、`swift test`、`./scripts/build-app.sh` 全部通过。
- [ ] 每个条目一个提交，提交信息带编号。
