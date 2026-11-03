import Foundation
import SQLite3
import Testing
@testable import AgentMonitorCore

@Suite("Antigravity hierarchy")
struct AntigravityHierarchyTests {
    @Test("Recent children retain old ancestors through adapter and store; killed children stay idle")
    func hierarchyAndExpiration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("conversation_summaries.db")
        defer { try? FileManager.default.removeItem(at: file) }
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let recent = formatter.string(from: Date())
        let old = formatter.string(from: Date().addingTimeInterval(-7200))
        let sql = """
        CREATE TABLE conversation_summaries (
          conversation_id TEXT PRIMARY KEY, title TEXT, preview TEXT, workspace_uris TEXT,
          status TEXT, not_fully_idle INTEGER, killed INTEGER, last_modified_time TEXT,
          parent_conversation_id TEXT, agent_name TEXT
        );
        INSERT INTO conversation_summaries VALUES
          ('parent', 'Main', '', '[]', 'CASCADE_RUN_STATUS_IDLE', 0, 0, '\(old)', '', ''),
          ('child', '', '', '["file:///tmp/subagent-UI-Engineer-self-12345678"]', 'CASCADE_RUN_STATUS_RUNNING', 0, 0, '\(recent)', 'parent', 'self'),
          ('ended', '', '', '[]', 'CASCADE_RUN_STATUS_RUNNING', 1, 1, '\(recent)', 'child', 'Reviewer'),
          ('killed-root', '', '', '[]', 'CASCADE_RUN_STATUS_IDLE', 0, 1, '\(recent)', '', ''),
          ('expired', '', '', '[]', 'CASCADE_RUN_STATUS_IDLE', 0, 0, '\(old)', '', '');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        let adapter = AntigravityAdapter(baseDirectory: directory, isLockHeld: { _ in false }, maxAgeSeconds: 3600)
        let sessions = try adapter.scan()
        #expect(Set(sessions.map(\.id)) == ["antigravity:parent", "antigravity:child", "antigravity:ended"])
        let child = try #require(sessions.first { $0.id == "antigravity:child" })
        #expect(child.parentSessionID == "antigravity:parent")
        #expect(child.title == "UI Engineer")
        #expect(child.state == .running)
        let ended = try #require(sessions.first { $0.id == "antigravity:ended" })
        #expect(ended.parentSessionID == child.id)
        #expect(ended.state == .idle)
        #expect(ended.suppressCompletion)
        #expect(ended.title == "Reviewer")
        let store = SessionStore(adapters: [adapter], maxAgeSeconds: 3600)
        _ = store.refresh()
        #expect(Set(store.currentSessions.map(\.id)) == Set(sessions.map(\.id)))
        _ = store.refresh()
        #expect(store.currentSessions.contains { $0.id == "antigravity:parent" })
    }
}
