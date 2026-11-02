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
    }
}
