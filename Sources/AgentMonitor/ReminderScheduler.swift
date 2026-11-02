import Foundation
import AgentMonitorCore

@MainActor
public final class ReminderScheduler {
    public var remindAfterMinutes: Int
    public var remindMaxCount: Int

    // key = "\(session.id)|\(Int(session.stateSince.timeIntervalSince1970))"，value = 已发出的提醒次数
    private var sent: [String: Int] = [:]

    public init(remindAfterMinutes: Int = 5, remindMaxCount: Int = 2) {
        self.remindAfterMinutes = remindAfterMinutes
        self.remindMaxCount = remindMaxCount
    }

    public func evaluate(sessions: [AgentSession], now: Date) -> [(AgentSession, Int)] {
        var toNotify: [(AgentSession, Int)] = []
        let waitingSessions = sessions.filter { $0.state == .waitingForUser }
        let currentKeys = Set(waitingSessions.map { "\($0.id)|\(Int($0.stateSince.timeIntervalSince1970))" })

        // 清理已不在 waiting 的 key
        sent = sent.filter { currentKeys.contains($0.key) }

        guard remindAfterMinutes > 0, remindMaxCount > 0 else {
            return []
        }

        let interval = Double(remindAfterMinutes * 60)

        for session in waitingSessions {
            let key = "\(session.id)|\(Int(session.stateSince.timeIntervalSince1970))"
            let elapsed = now.timeIntervalSince(session.stateSince)
            if elapsed < interval {
                continue
            }

            // 当前应该达到的第 k 次 (k = 1...remindMaxCount)
            let k = min(remindMaxCount, Int(elapsed / interval))
            let lastSent = sent[key] ?? 0

            if k > lastSent {
                sent[key] = k
                toNotify.append((session, k))
            }
        }

        return toNotify
    }

    public func reset() {
        sent.removeAll()
    }
}
