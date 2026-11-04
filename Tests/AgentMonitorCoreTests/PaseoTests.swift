import Foundation
import Testing
@testable import AgentMonitorCore

@Suite("Paseo conversations")
struct PaseoTests {
    private let agentID = "68660d06-0ce7-42f3-b8a1-7b17a91fbae4"
    private let nativeID = "01a188df-cf09-7763-8796-5609ef455ca1"

    private func agent(status: String = "idle", attention: String? = nil) throws -> PaseoAgentSnapshot {
        var value: [String: Any] = ["id":agentID, "provider":"codex", "title":"Paseo work", "cwd":"/work",
                                   "status":status, "updatedAt":ISO8601DateFormatter().string(from: Date()),
                                   "runtimeInfo":["sessionId":nativeID]]
        if let attention { value["requiresAttention"] = true; value["attentionReason"] = attention }
        return try JSONDecoder().decode(PaseoAgentSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func session(_ agent: PaseoAgentSnapshot, local: Bool = true, connected: Bool = true) throws -> AgentSession {
        try #require(agent.session(serverID: local ? "local" : "remote", hostName: "server", isLocal: local, connected: connected))
    }
    private func adapter() -> PaseoAdapter {
        PaseoAdapter(home: URL(fileURLWithPath: "/nonexistent"), application: URL(fileURLWithPath: "/nonexistent"))
    }
    private func host(_ agent: PaseoAgentSnapshot, connected: Bool = true) -> PaseoHostSnapshot {
        PaseoHostSnapshot(serverID: "local", hostName: "server", isLocal: true, connected: connected, agents: connected ? [agent] : [])
    }

    @Test("Provider identity deduplicates local sessions but never a remote ID collision")
    func deduplication() throws {
        let local = try session(agent(status:"running"))
        let remote = try session(agent(status:"running"), local:false)
        let usage = SessionUsage(inputTokens:42)
        let native = AgentSession(id:"codex:\(nativeID)", kind:.codex, title:"native", state:.running, transcriptPath:"/log", usage:usage)
        let unrelated = AgentSession(id:"codex:other", kind:.codex, title:"same cwd", cwd:"/work", state:.idle)
        let result = PaseoAdapter.merging([native,unrelated,local,remote])
        #expect(result.count == 3)
        #expect(result.contains { $0.id == unrelated.id })
        #expect(result.first { $0.id == local.id }?.usage == usage)
        #expect(result.first { $0.id == remote.id }?.usage == nil)
        #expect(PaseoAdapter.merging([native,remote]).count == 2)
    }

    @Test("Hierarchy follows the deduplicated parent")
    func hierarchy() throws {
        let local = try session(agent())
        let native = AgentSession(id:"codex:\(nativeID)", kind:.codex, title:"native", state:.idle)
        let child = AgentSession(id:"codex:child", kind:.codex, title:"child", state:.running, parentSessionID:native.id)
        let result = PaseoAdapter.merging([native,child,local])
        #expect(result.first { $0.id == child.id }?.parentSessionID == local.id)
    }

    @Test("Permissions, running, errors and disconnect map without false completions")
    func statuses() throws {
        #expect(try session(agent(status:"running")).state == .running)
        #expect(try session(agent(status:"initializing")).state == .running)
        #expect(try session(agent(status:"idle", attention:"permission")).state == .waitingForUser)
        #expect(try session(agent(status:"idle", attention:"finished")).state == .idle)
        #expect(try session(agent(status:"error", attention:"error")).suppressCompletion)
        let offline = try session(agent(status:"running", attention:"permission"), connected:false)
        #expect(offline.state == .idle)
        #expect(offline.suppressCompletion)
        #expect(offline.waitingLabel == nil)
        #expect(offline.paseo?.displayLabel == "Paseo · Codex · 本机 · 离线")
        #expect(try session(agent(), local:false).paseo?.displayLabel == "Paseo · Codex · server")
    }

    @Test("Disconnect retains rows, reconnect updates them, removed hosts and archived agents disappear")
    func lifecycle() throws {
        let a = adapter(), running = try agent(status:"running")
        a.applySnapshot([host(running)])
        let id = try #require(a.scan().first?.id)
        a.applySnapshot([host(running, connected:false)])
        let offline = try #require(a.scan().first)
        #expect(offline.id == id)
        #expect(offline.paseo?.connected == false)
        #expect(offline.suppressCompletion)
        a.applySnapshot([host(try agent())])
        #expect(try a.scan().first?.paseo?.connected == true)
        a.applySnapshot([])
        #expect(try a.scan().isEmpty)
        var archived = running; archived.archivedAt = "2026-11-04T00:00:00Z"
        #expect(archived.session(serverID:"local", hostName:"server", isLocal:true, connected:true) == nil)
        archived.archivedAt = nil; archived.internal = true
        #expect(archived.session(serverID:"local", hostName:"server", isLocal:true, connected:true) == nil)
    }

    @Test("Store never completes on disconnect; real completion can be marked read")
    func storeTransitions() throws {
        let a = adapter(), running = try agent(status:"running")
        let store = SessionStore(adapters:[a])
        a.applySnapshot([host(running)]); store.refresh()
        a.applySnapshot([host(running, connected:false)])
        let transitions = store.refresh()
        #expect(store.currentSessions.first?.state == .idle)
        #expect(!transitions.contains { if case .stateChanged(_,_,.completed) = $0 { return true }; return false })
        a.applySnapshot([host(running)]); store.refresh()
        a.applySnapshot([host(try agent(attention:"finished"))]); store.refresh()
        #expect(store.currentSessions.first?.state == .completed)
        let id = try #require(store.currentSessions.first?.id)
        store.markAsRead(id:id); store.refresh()
        #expect(store.currentSessions.first?.state == .idle)
    }

    @Test("Bridge failure also clears stale completed states")
    func failedBridge() throws {
        let a = adapter(), store = SessionStore(adapters:[a])
        a.applySnapshot([host(try agent(status:"running"))]); store.refresh()
        a.applySnapshot([host(try agent())]); store.refresh()
        #expect(store.currentSessions.first?.state == .completed)
        a.applySnapshot(nil); store.refresh()
        #expect(store.currentSessions.first?.state == .idle)
        #expect(store.currentSessions.first?.paseo?.connected == false)
    }

    @Test("DSH plugin session identity is extracted")
    func plugin() throws {
        var value = try agent()
        value.provider = "dsh-pi"
        value.runtimeInfo = .init(sessionId:"plugin:{\"version\":1,\"data\":{\"dshSessionId\":\"session-123\"}}")
        #expect(try session(value).paseo?.localIdentity == "dsh:session-123")
    }
}
