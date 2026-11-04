import Foundation
import Testing
import AgentMonitorCore
@testable import AgentMonitor

@Suite("SessionTree Tests")
struct SessionTreeTests {

    @Test("子代理挂到父会话下，顶层不再出现")
    func testSubagentNesting() {
        let now = Date()
        let parent = AgentSession(
            id: "dsh:parent", kind: .dsh, title: "主任务", state: .running,
            stateSince: now.addingTimeInterval(-200), lastActivity: now
        )
        let child = AgentSession(
            id: "dsh:child", kind: .dsh, title: "子任务", state: .running,
            stateSince: now.addingTimeInterval(-100), lastActivity: now,
            parentId: "dsh:parent", subagentDepth: 1
        )

        let roots = SessionTree.build([parent, child])
        #expect(roots.count == 1)
        #expect(roots.first?.id == "dsh:parent")
        #expect(roots.first?.subagents.count == 1)
        #expect(roots.first?.subagents.first?.id == "dsh:child")
    }

    @Test("depth 2 挂在 depth 1 下")
    func testGrandchildNesting() {
        let now = Date()
        let root = AgentSession(
            id: "dsh:root", kind: .dsh, title: "根任务", state: .running,
            stateSince: now.addingTimeInterval(-300), lastActivity: now
        )
        let depth1 = AgentSession(
            id: "dsh:child1", kind: .dsh, title: "一级子任务", state: .running,
            stateSince: now.addingTimeInterval(-200), lastActivity: now,
            parentId: "dsh:root", subagentDepth: 1
        )
        let depth2 = AgentSession(
            id: "dsh:child2", kind: .dsh, title: "二级子任务", state: .running,
            stateSince: now.addingTimeInterval(-100), lastActivity: now,
            parentId: "dsh:child1", subagentDepth: 2
        )

        let roots = SessionTree.build([root, depth1, depth2])
        #expect(roots.count == 1)
        let r = roots[0]
        #expect(r.subagents.count == 1)
        let c1 = r.subagents[0]
        #expect(c1.id == "dsh:child1")
        #expect(c1.subagents.count == 1)
        #expect(c1.subagents[0].id == "dsh:child2")
    }

    @Test("子代理 waiting → 父显示态 waiting，waitingLabel 带「子代理」前缀，detail 取子代理的")
    func testParentStateEscalationToWaiting() {
        let now = Date()
        let parent = AgentSession(
            id: "cx:parent", kind: .codex, title: "父任务", state: .idle,
            stateSince: now.addingTimeInterval(-300), lastActivity: now.addingTimeInterval(-300)
        )
        let child = AgentSession(
            id: "cx:child", kind: .codex, title: "授权子任务", state: .waitingForUser,
            stateSince: now.addingTimeInterval(-50), lastActivity: now,
            detail: "rm -rf cache", detailIsCommand: true, waitingLabel: "等待授权",
            parentId: "cx:parent", subagentDepth: 1
        )

        let roots = SessionTree.build([parent, child])
        #expect(roots.count == 1)
        let r = roots[0]
        #expect(r.state == .waitingForUser)
        #expect(r.waitingLabel == "子代理等待授权")
        #expect(r.detail == "rm -rf cache")
        #expect(r.detailIsCommand == true)
    }

    @Test("父 idle、子 running → 父显示 running")
    func testParentStateEscalationToRunning() {
        let now = Date()
        let parent = AgentSession(
            id: "ds:parent", kind: .dsh, title: "父任务", state: .idle,
            stateSince: now.addingTimeInterval(-500), lastActivity: now.addingTimeInterval(-500)
        )
        let child = AgentSession(
            id: "ds:child", kind: .dsh, title: "运行中子任务", state: .running,
            stateSince: now.addingTimeInterval(-150), lastActivity: now,
            parentId: "ds:parent", subagentDepth: 1
        )

        let roots = SessionTree.build([parent, child])
        #expect(roots.count == 1)
        let r = roots[0]
        #expect(r.state == .running)
        #expect(r.stateSince == child.stateSince)
    }

    @Test("活跃孤儿保留为顶层，非活跃孤儿丢弃")
    func testOrphanSubagents() {
        let now = Date()
        let activeRunning = AgentSession(
            id: "ds:orphan1", kind: .dsh, title: "运行孤儿", state: .running,
            stateSince: now.addingTimeInterval(-100), lastActivity: now,
            parentId: "ds:missing-parent", subagentDepth: 1
        )
        let activeWaiting = AgentSession(
            id: "ds:orphan2", kind: .dsh, title: "等待孤儿", state: .waitingForUser,
            stateSince: now.addingTimeInterval(-80), lastActivity: now,
            parentId: "ds:missing-parent", subagentDepth: 1
        )
        let inactiveIdle = AgentSession(
            id: "ds:orphan3", kind: .dsh, title: "空闲孤儿", state: .idle,
            stateSince: now.addingTimeInterval(-300), lastActivity: now.addingTimeInterval(-300),
            parentId: "ds:missing-parent", subagentDepth: 1
        )
        let inactiveCompleted = AgentSession(
            id: "ds:orphan4", kind: .dsh, title: "完成孤儿", state: .completed,
            stateSince: now.addingTimeInterval(-400), lastActivity: now.addingTimeInterval(-400),
            parentId: "ds:missing-parent", subagentDepth: 1
        )

        let roots = SessionTree.build([activeRunning, activeWaiting, inactiveIdle, inactiveCompleted])
        let rootIds = Set(roots.map { $0.id })
        #expect(rootIds.contains("ds:orphan1"))
        #expect(rootIds.contains("ds:orphan2"))
        #expect(!rootIds.contains("ds:orphan3"))
        #expect(!rootIds.contains("ds:orphan4"))
        #expect(roots.count == 2)
    }

    @MainActor
    @Test("顶层计数（waitingCount、筛选）不含子代理")
    func testTopLevelCountDoesNotIncludeSubagents() {
        // mockSessionsSubagentsFlat 包含 3 组会话（其中一组子代理在 waiting，一组在 running，一组 completed）+ 1 个独立 running
        let flat = MonitorViewModel.mockSessionsSubagentsFlat()
        let tree = SessionTree.build(flat)

        // 扁平列表共有 13 个会话，但顶层只有 4 个
        #expect(flat.count == 13)
        #expect(tree.count == 4)

        // 顶层 waitingCount 仅计入显示态为 waitingForUser 的顶层会话
        let waitingRoots = tree.filter { $0.state == .waitingForUser }
        #expect(waitingRoots.count == 1)

        // 筛选逻辑基于顶层 tree
        #expect(MonitorViewModel.shouldClearFilter(currentFilter: .waitingForUser, sessions: tree) == false)
        #expect(MonitorViewModel.shouldClearFilter(currentFilter: .idle, sessions: tree) == true)
    }
}
