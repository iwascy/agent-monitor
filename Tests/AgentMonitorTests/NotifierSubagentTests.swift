import Foundation
import Testing
import UserNotifications
import AgentMonitorCore
@testable import AgentMonitor

@Suite("Notifier Subagent Tests")
@MainActor
struct NotifierSubagentTests {

    @Test("NotificationFormatter: 子代理 waiting 标题包含父标题")
    func testNotificationFormatterParentTitle() {
        let child = AgentSession(
            id: "dsh:child",
            kind: .dsh,
            title: "分析子任务",
            state: .waitingForUser,
            parentId: "dsh:parent",
            subagentDepth: 1
        )

        let title = NotificationFormatter.formatTitle(for: child, parentTitle: "主会话分析")
        #expect(title.contains("DeepSeek Harness"))
        #expect(title.contains("主会话分析 › 分析子任务"))
    }

    @Test("Notifier: 子代理 completed 不通知；子代理 waiting 通知且标题带父标题")
    func testSubagentNotificationBehavior() {
        let notifier = Notifier()
        notifier.parentTitle = { parentId in
            if parentId == "dsh:parent" {
                return "父主干任务"
            }
            return nil
        }

        var sentRequests: [UNNotificationRequest] = []
        notifier.onNotificationSent = { request in
            sentRequests.append(request)
        }

        let child = AgentSession(
            id: "dsh:child",
            kind: .dsh,
            title: "子任务构建",
            state: .running,
            parentId: "dsh:parent",
            subagentDepth: 1
        )

        // 1. 子代理完成：不应发送通知
        var childCompleted = child
        childCompleted.state = .completed
        notifier.notify(transition: .stateChanged(session: childCompleted, from: .running, to: .completed))
        #expect(sentRequests.isEmpty)

        // 2. 子代理 waiting：应发送通知，且标题带父会话标题
        var childWaiting = child
        childWaiting.state = .waitingForUser
        childWaiting.waitingLabel = "等待授权"
        notifier.notify(transition: .stateChanged(session: childWaiting, from: .running, to: .waitingForUser))

        #expect(sentRequests.count == 1)
        let req = sentRequests[0]
        #expect(req.content.title.contains("父主干任务 › 子任务构建"))
        #expect(req.content.subtitle == "等待授权")

        // 3. 主会话完成：应正常发送通知
        let parentCompleted = AgentSession(
            id: "dsh:parent",
            kind: .dsh,
            title: "父主干任务",
            state: .completed,
            completedDuration: 120
        )
        notifier.notify(transition: .stateChanged(session: parentCompleted, from: .running, to: .completed))
        #expect(sentRequests.count == 2)
        #expect(sentRequests[1].content.title == "DeepSeek Harness · 父主干任务")
    }
}
