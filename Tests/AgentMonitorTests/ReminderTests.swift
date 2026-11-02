import Foundation
import Testing
@testable import AgentMonitor
@testable import AgentMonitorCore

@Suite("ReminderScheduler Tests")
struct ReminderTests {

    @Test("ReminderScheduler: evaluation threshold, max count, re-entry and jump-over")
    @MainActor
    func testReminderSchedulerEvaluation() {
        let scheduler = ReminderScheduler(remindAfterMinutes: 5, remindMaxCount: 2)
        let t0 = Date(timeIntervalSince1970: 10000)
        var session = AgentSession(
            id: "test:s1",
            kind: .claudeCode,
            title: "Test",
            state: .waitingForUser,
            stateSince: t0
        )

        // 1. Before threshold (e.g. 4 minutes in): no reminder
        let t4m = t0.addingTimeInterval(4 * 60)
        let r1 = scheduler.evaluate(sessions: [session], now: t4m)
        #expect(r1.isEmpty)

        // 2. Cross first threshold (5 minutes in): fires index 1
        let t5m = t0.addingTimeInterval(5 * 60)
        let r2 = scheduler.evaluate(sessions: [session], now: t5m)
        #expect(r2.count == 1)
        #expect(r2.first?.1 == 1)

        // 3. Same threshold repeat evaluate: does not re-fire
        let r3 = scheduler.evaluate(sessions: [session], now: t5m.addingTimeInterval(30))
        #expect(r3.isEmpty)

        // 4. Cross second threshold (10 minutes in): fires index 2
        let t10m = t0.addingTimeInterval(10 * 60)
        let r4 = scheduler.evaluate(sessions: [session], now: t10m)
        #expect(r4.count == 1)
        #expect(r4.first?.1 == 2)

        // 5. Beyond max count (15 minutes in, max is 2): does not fire
        let t15m = t0.addingTimeInterval(15 * 60)
        let r5 = scheduler.evaluate(sessions: [session], now: t15m)
        #expect(r5.isEmpty)

        // 6. Leaving waiting then re-entering: resets count
        session.state = .running
        session.stateSince = t15m
        let r6 = scheduler.evaluate(sessions: [session], now: t15m)
        #expect(r6.isEmpty)

        // Re-enter waiting
        let t16m = t15m.addingTimeInterval(60)
        session.state = .waitingForUser
        session.stateSince = t16m

        // Jump over 3 intervals (e.g. 18 minutes after t16m): fires once with index min(maxCount, 3) = 2
        let t34m = t16m.addingTimeInterval(18 * 60)
        let r7 = scheduler.evaluate(sessions: [session], now: t34m)
        #expect(r7.count == 1)
        #expect(r7.first?.1 == 2)

        // When remindMaxCount >= 3, jump over 3 intervals fires once with index 3
        let scheduler3 = ReminderScheduler(remindAfterMinutes: 5, remindMaxCount: 3)
        let r8 = scheduler3.evaluate(sessions: [session], now: t34m)
        #expect(r8.count == 1)
        #expect(r8.first?.1 == 3)
    }

    @Test("P0-2: Reminder suppression must advance counter so suppressed intervals do not backfire")
    @MainActor
    func testSuppressedRemindersDoNotBackfire() {
        let scheduler = ReminderScheduler(remindAfterMinutes: 5, remindMaxCount: 2)
        let t0 = Date(timeIntervalSince1970: 20000)
        let session = AgentSession(
            id: "test:p02",
            kind: .claudeCode,
            title: "P02",
            cwd: "/Users/test/proj",
            state: .waitingForUser,
            stateSince: t0
        )

        // 场景 1: 面板打开时跨过第 1 个时间点 (5分钟后)
        let t5m = t0.addingTimeInterval(5 * 60)
        let due1 = scheduler.evaluate(sessions: [session], now: t5m)
        #expect(due1.count == 1)
        let snapshot = NotificationPolicy.SettingsSnapshot(
            notifyWaiting: true,
            silenceWhilePanelOpen: true,
            remindEnabled: true
        )
        // 面板打开时被抑制
        let shouldSend1 = NotificationPolicy.shouldSendReminder(
            session: due1[0].0,
            settings: snapshot,
            isPanelVisible: true
        )
        #expect(shouldSend1 == false)

        // 关闭面板后再 evaluate (5分30秒后)，不发
        let t5m30s = t5m.addingTimeInterval(30)
        let dueAfterClose = scheduler.evaluate(sessions: [session], now: t5m30s)
        #expect(dueAfterClose.isEmpty)

        // 场景 2: 删除 .all 静音规则后，不立即发
        let schedulerMute = ReminderScheduler(remindAfterMinutes: 5, remindMaxCount: 2)
        let ruleAll = MuteRule(path: "/Users/test/proj", scope: .all)
        let dueMute = schedulerMute.evaluate(sessions: [session], now: t5m)
        #expect(dueMute.count == 1)
        // 命中 .all 静音，不发送
        let shouldSendMute = NotificationPolicy.shouldSendReminder(
            session: dueMute[0].0,
            settings: snapshot,
            muteRules: [ruleAll],
            isPanelVisible: false
        )
        #expect(shouldSendMute == false)

        // 删除 .all 规则后在 5分30秒 evaluate，由于 evaluate 计数已推进，不发
        let dueAfterUnmute = schedulerMute.evaluate(sessions: [session], now: t5m30s)
        #expect(dueAfterUnmute.isEmpty)

        // 场景 3: 规则为 completedOnly 加 hideInPanel 的会话，仍然按时提醒
        let ruleCompletedOnly = MuteRule(path: "/Users/test/proj", scope: .completedOnly, hideInPanel: true)
        let schedulerHide = ReminderScheduler(remindAfterMinutes: 5, remindMaxCount: 2)
        let dueHide = schedulerHide.evaluate(sessions: [session], now: t5m)
        #expect(dueHide.count == 1)
        let shouldSendHide = NotificationPolicy.shouldSendReminder(
            session: dueHide[0].0,
            settings: snapshot,
            muteRules: [ruleCompletedOnly],
            isPanelVisible: false
        )
        #expect(shouldSendHide == true)
    }
}
