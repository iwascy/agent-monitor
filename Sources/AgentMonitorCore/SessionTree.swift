import Foundation

public enum SessionTree {
    /// 输入 SessionStore 的扁平列表（含子代理），输出只含顶层会话的列表，子代理挂在 subagents 里
    public static func build(_ flat: [AgentSession]) -> [AgentSession] {
        let validIds = Set(flat.map { $0.id })

        // 建立直接子节点映射 parentId -> [AgentSession]
        var childrenByParent: [String: [AgentSession]] = [:]
        for session in flat {
            if let parentId = session.parentId, validIds.contains(parentId) {
                childrenByParent[parentId, default: []].append(session)
            }
        }

        // 递归收集某个节点下的所有后代
        func collectAllDescendants(of parentId: String) -> [AgentSession] {
            guard let direct = childrenByParent[parentId] else { return [] }
            var list: [AgentSession] = []
            for child in direct {
                list.append(child)
                list.append(contentsOf: collectAllDescendants(of: child.id))
            }
            return list
        }

        // 识别顶层根节点
        var roots: [AgentSession] = []
        for session in flat {
            if session.parentId == nil {
                roots.append(session)
            } else if let parentId = session.parentId, !validIds.contains(parentId) {
                // 找不到父会话的孤儿
                if session.state == .running || session.state == .waitingForUser {
                    roots.append(session)
                }
                // 否则丢弃
            }
        }

        // 为每个根节点挂载子树并计算显示状态
        var resultRoots: [AgentSession] = []
        for var root in roots {
            let directChildren = (childrenByParent[root.id] ?? []).sorted { $0.stateSince < $1.stateSince }

            var builtChildren: [AgentSession] = []
            for var child in directChildren {
                // 面板最多显示两层：更深的挂到最近一个已显示的祖先下（即直接作为 child 的 subagents）
                let deeperDescendants = collectAllDescendants(of: child.id).sorted { $0.stateSince < $1.stateSince }
                child.subagents = deeperDescendants
                builtChildren.append(child)
            }
            root.subagents = builtChildren

            // 计算所有后代列表
            let allDescendants = root.subagents.flatMap { [$0] + $0.subagents }

            // 计算父会话的显示状态副本：取自身和所有后代中最紧急的
            // waitingForUser > running > completed > idle
            if root.state != .waitingForUser {
                let waitingDescendants = allDescendants.filter { $0.state == .waitingForUser }
                if let mostUrgent = waitingDescendants.min(by: { $0.stateSince < $1.stateSince }) {
                    root.state = .waitingForUser
                    let childLabel = mostUrgent.waitingLabel ?? "等待授权"
                    root.waitingLabel = childLabel.hasPrefix("子代理") ? childLabel : "子代理\(childLabel)"
                    root.detail = mostUrgent.detail
                    root.detailIsCommand = mostUrgent.detailIsCommand
                } else if (root.state == .idle || root.state == .completed) && allDescendants.contains(where: { $0.state == .running }) {
                    root.state = .running
                    let runningDescendants = allDescendants.filter { $0.state == .running }
                    if let earliest = runningDescendants.map({ $0.stateSince }).min() {
                        root.stateSince = earliest
                    }
                } else if root.state == .idle && allDescendants.contains(where: { $0.state == .completed }) {
                    root.state = .completed
                }
            }

            resultRoots.append(root)
        }

        // 顶层排序：waiting -> completed -> running -> idle，同状态按 lastActivity 降序
        let stateRank = { (state: SessionState) -> Int in
            switch state {
            case .waitingForUser: return 0
            case .completed: return 1
            case .running: return 2
            case .idle: return 3
            }
        }

        resultRoots.sort { lhs, rhs in
            let rankL = stateRank(lhs.state)
            let rankR = stateRank(rhs.state)
            if rankL != rankR {
                return rankL < rankR
            }
            return lhs.lastActivity > rhs.lastActivity
        }

        return resultRoots
    }
}
