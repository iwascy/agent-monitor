# AGENTS.md

macOS 菜单栏 app（SwiftUI `MenuBarExtra`，macOS 26），汇总 Claude Code / Codex / dsh / Antigravity 的会话状态。架构和状态判定细节见 `docs/HANDOFF.md`，各 agent 数据格式见 `docs/FORMATS.md`。

## 构建与测试

- `swift test`：单元测试
- `./scripts/build-app.sh`：打包到 `build/AgentMonitor.app`，UI 验证前先跑
- `swift run probe`：只读扫描本机真实 agent 数据

## UI 验证：优先读组件树，不要靠截图和坐标

面板的元素都在辅助功能（AX）树里，按名字找、按名字按，不要写死屏幕坐标：

```bash
swift scripts/panel-probe.swift 运行中 运行中 已完成        # 依次按这些按钮，每步打印窗口尺寸
swift scripts/panel-probe.swift --tree                    # 打印完整 AX 树（角色、名字、位置尺寸）
swift scripts/panel-probe.swift --mock large --idle-expanded --shots <dir> 全部标为已读
```

- 按钮按 AX description 的结尾匹配：筛选胶囊是 `2、运行中`，会话行是 `标题、时间、agent · 目录、…`，另有 `全部标为已读`、`空闲 · N 个会话`、`暂停通知 1 小时`。
- 尺寸、位置、文字、元素是否存在，用 AX 树或窗口尺寸判断，结论要有数字。
- 截图（`--shots`）只用于 AX 看不到的东西：留白、毛玻璃、颜色、对比度。
- 怀疑布局问题时，在视图里临时加 `onGeometryChange` 往 stderr 打日志，`panel-probe` 会把 app 的输出一起打印出来。查完删掉。
- 脚本会结束正在运行的 AgentMonitor，跑完如原来在运行会重新打开；需要终端有「辅助功能」权限（`--shots` 还需「屏幕录制」）。

模拟数据环境变量（只在 mock 下生效，不影响正常运行）：`AGENT_MONITOR_MOCK_DATA=1|large|empty`、`AGENT_MONITOR_FILTER=waiting|completed|running|idle`、`AGENT_MONITOR_IDLE_EXPANDED=1`、`AGENT_MONITOR_COLOR_SCHEME=light|dark`。

整套文档截图用 `scripts/capture-all.swift` 和 `scripts/capture-a11y.swift`（会切换系统深浅色）。

## 已知坑

- `MenuBarExtra` 的窗口在内容变矮时会停在中间高度。`MenuView` 根视图必须保留 `.fixedSize(horizontal: false, vertical: true)`，否则切换筛选后列表上下出现空白。改面板布局后用 `panel-probe` 切几次筛选，确认窗口高度和直接以该筛选启动时一致。
- 没装完整 Xcode 时 `@State` 宏不可用，视图状态用 `@LocalState`（`Sources/AgentMonitor/Panel/LocalState.swift`）。
