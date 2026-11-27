import Foundation
import SQLite3
import Testing
@testable import AgentMonitorCore

@Suite("T3 Code adapter")
struct T3CodeTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-monitor-t3code-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "rc=\(rc)"
            sqlite3_free(errMsg)
            throw NSError(domain: "T3CodeTests", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private func createSchema(in db: OpaquePointer) throws {
        try exec(db, """
        PRAGMA journal_mode = WAL;
        CREATE TABLE projection_projects (
            project_id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            workspace_root TEXT NOT NULL,
            scripts_json TEXT NOT NULL DEFAULT '[]',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            deleted_at TEXT
        );
        CREATE TABLE orchestration_v2_projection_threads (
            thread_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            title TEXT NOT NULL,
            default_provider TEXT NOT NULL,
            runtime_mode TEXT NOT NULL DEFAULT 'full-access',
            interaction_mode TEXT NOT NULL DEFAULT 'default',
            active_provider_thread_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            archived_at TEXT,
            deleted_at TEXT,
            payload_json TEXT NOT NULL,
            provider_instance_id TEXT
        );
        CREATE TABLE orchestration_v2_projection_runs (
            run_id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            provider TEXT NOT NULL,
            provider_thread_id TEXT,
            status TEXT NOT NULL,
            requested_at TEXT NOT NULL,
            completed_at TEXT,
            payload_json TEXT NOT NULL,
            provider_instance_id TEXT
        );
        CREATE TABLE orchestration_v2_projection_runtime_requests (
            runtime_request_id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            node_id TEXT NOT NULL,
            provider_turn_id TEXT,
            kind TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            resolved_at TEXT,
            payload_json TEXT NOT NULL
        );
        CREATE TABLE orchestration_v2_projection_provider_threads (
            provider_thread_id TEXT PRIMARY KEY,
            thread_id TEXT,
            owner_node_id TEXT,
            provider TEXT NOT NULL,
            provider_session_id TEXT,
            status TEXT NOT NULL,
            first_run_ordinal INTEGER,
            last_run_ordinal INTEGER,
            updated_at TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            driver TEXT,
            provider_instance_id TEXT
        );
        CREATE TABLE orchestration_v2_projection_turn_items (
            turn_item_id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            run_id TEXT,
            node_id TEXT,
            provider_thread_id TEXT,
            provider_turn_id TEXT,
            parent_item_id TEXT,
            ordinal INTEGER NOT NULL,
            type TEXT NOT NULL,
            status TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            payload_json TEXT NOT NULL
        );
        CREATE TABLE orchestration_v2_projection_messages (
            message_id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            run_id TEXT,
            node_id TEXT,
            role TEXT NOT NULL,
            streaming INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            payload_json TEXT NOT NULL
        );
        """)
    }

    private func iso(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: date)
    }

    @Test("扫描运行中、等待授权、等待回复、已完成与静态导入过滤")
    func scanStatesAndFiltering() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "env-123\n".write(to: dir.appendingPathComponent("environment-id"), atomically: true, encoding: .utf8)
        let dbURL = dir.appendingPathComponent("statev2.sqlite")

        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        let database = try #require(db)
        try createSchema(in: database)

        let now = Date()
        let tNow = iso(now)
        let tStarted = iso(now.addingTimeInterval(-95))
        let tWait = iso(now.addingTimeInterval(-40))
        let tDone = iso(now.addingTimeInterval(-20))

        try exec(database, """
        INSERT INTO projection_projects(project_id, title, workspace_root, created_at, updated_at)
        VALUES ('p1', 'agent-monitor', '/Users/test/code/agent-monitor', '\(tNow)', '\(tNow)');

        -- 1. 运行中线程（带 worktreePath、contextUsage、command_execution）
        INSERT INTO orchestration_v2_projection_threads
          (thread_id, project_id, title, default_provider, active_provider_thread_id, created_at, updated_at, payload_json, provider_instance_id)
        VALUES
          ('th-running', 'p1', '实现 T3Code 适配', 'antigravity', 'pt-running', '\(tStarted)', '\(tNow)',
           '{"worktreePath":"/Users/test/code/agent-monitor-wt","modelSelection":{"model":"gemini-4-neon"},"lineage":{"parentThreadId":null}}',
           'antigravity');
        INSERT INTO orchestration_v2_projection_runs
          (run_id, thread_id, ordinal, provider, status, requested_at, payload_json, provider_instance_id)
        VALUES
          ('run-1', 'th-running', 1, 'antigravity', 'running', '\(tStarted)',
           '{"startedAt":"\(tStarted)","modelSelection":{"model":"gemini-4-neon"}}', 'antigravity');
        INSERT INTO orchestration_v2_projection_provider_threads
          (provider_thread_id, thread_id, provider, status, updated_at, payload_json, provider_instance_id)
        VALUES
          ('pt-running', 'th-running', 'antigravity', 'running', '\(tNow)',
           '{"nativeThreadRef":{"driver":"antigravity","nativeId":"pending:run:1"},"contextUsage":{"usedTokens":173555,"maxTokens":1048576,"inputTokens":150000,"outputTokens":23555}}',
           'antigravity');
        INSERT INTO orchestration_v2_projection_turn_items
          (turn_item_id, thread_id, run_id, ordinal, type, status, updated_at, payload_json)
        VALUES
          ('item-1', 'th-running', 'run-1', 10, 'command_execution', 'running', '\(tNow)',
           '{"title":"Ran command","input":"swift test --filter T3Code"}');

        -- 2. 等待命令授权线程
        INSERT INTO orchestration_v2_projection_threads
          (thread_id, project_id, title, default_provider, active_provider_thread_id, created_at, updated_at, payload_json, provider_instance_id)
        VALUES
          ('th-approval', 'p1', '危险命令审批', 'codex', 'pt-approval', '\(tStarted)', '\(tNow)', '{}', 'codex');
        INSERT INTO orchestration_v2_projection_runs
          (run_id, thread_id, ordinal, provider, status, requested_at, payload_json, provider_instance_id)
        VALUES
          ('run-2', 'th-approval', 1, 'codex', 'waiting', '\(tStarted)', '{}', 'codex');
        INSERT INTO orchestration_v2_projection_runtime_requests
          (runtime_request_id, thread_id, node_id, kind, status, created_at, payload_json)
        VALUES
          ('req-approval', 'th-approval', 'n1', 'command', 'pending', '\(tWait)', '{}');
        INSERT INTO orchestration_v2_projection_turn_items
          (turn_item_id, thread_id, run_id, ordinal, type, status, updated_at, payload_json)
        VALUES
          ('item-2', 'th-approval', 'run-2', 5, 'approval_request', 'waiting', '\(tWait)',
           '{"requestId":"req-approval","requestKind":"command","prompt":"git push --force origin main"}');

        -- 3. 等待用户输入（在问你）
        INSERT INTO orchestration_v2_projection_threads
          (thread_id, project_id, title, default_provider, created_at, updated_at, payload_json, provider_instance_id)
        VALUES
          ('th-question', 'p1', '确认方案选型', 'claudeAgent', '\(tStarted)', '\(tNow)', '{}', 'claudeAgent');
        INSERT INTO orchestration_v2_projection_runtime_requests
          (runtime_request_id, thread_id, node_id, kind, status, created_at, payload_json)
        VALUES
          ('req-q', 'th-question', 'n2', 'user_input', 'pending', '\(tWait)', '{}');
        INSERT INTO orchestration_v2_projection_turn_items
          (turn_item_id, thread_id, run_id, ordinal, type, status, updated_at, payload_json)
        VALUES
          ('item-3', 'th-question', NULL, 6, 'user_input_request', 'waiting', '\(tWait)',
           '{"requestId":"req-q","questions":[{"question":"需要保留旧配置兼容吗？"}]}');

        -- 4. 已完成（Adapter 报 idle，suppressCompletion = false）+ 最后一条助手回复
        INSERT INTO orchestration_v2_projection_threads
          (thread_id, project_id, title, default_provider, created_at, updated_at, payload_json, provider_instance_id)
        VALUES
          ('th-done', 'p1', '已完成的任务', 'codex', '\(tStarted)', '\(tDone)', '{}', 'codex');
        INSERT INTO orchestration_v2_projection_runs
          (run_id, thread_id, ordinal, provider, status, requested_at, completed_at, payload_json, provider_instance_id)
        VALUES
          ('run-4', 'th-done', 1, 'codex', 'completed', '\(tStarted)', '\(tDone)', '{}', 'codex');
        INSERT INTO orchestration_v2_projection_messages
          (message_id, thread_id, run_id, role, streaming, created_at, updated_at, payload_json)
        VALUES
          ('msg-4', 'th-done', 'run-4', 'assistant', 0, '\(tDone)', '\(tDone)', '{"text":"全部测试已经通过。"}');

        -- 5. 中止任务（suppressCompletion = true）
        INSERT INTO orchestration_v2_projection_threads
          (thread_id, project_id, title, default_provider, created_at, updated_at, payload_json, provider_instance_id)
        VALUES
          ('th-failed', 'p1', '失败的任务', 'codex', '\(tStarted)', '\(tDone)', '{}', 'codex');
        INSERT INTO orchestration_v2_projection_runs
          (run_id, thread_id, ordinal, provider, status, requested_at, completed_at, payload_json, provider_instance_id)
        VALUES
          ('run-5', 'th-failed', 1, 'codex', 'failed', '\(tStarted)', '\(tDone)', '{}', 'codex');

        -- 6. 纯静态导入的历史线程（无 run 记录，应被过滤）
        INSERT INTO orchestration_v2_projection_threads
          (thread_id, project_id, title, default_provider, created_at, updated_at, payload_json, provider_instance_id)
        VALUES
          ('import:codex:01a18ada-28dd-74a2-a756-fddc87ffdb4f', 'p1', '旧导入线程', 'codex', '\(tStarted)', '\(tNow)', '{}', 'codex');

        -- 7. 已在 T3 Code 中续跑过的导入线程（有 run 记录，应保留）
        INSERT INTO orchestration_v2_projection_threads
          (thread_id, project_id, title, default_provider, created_at, updated_at, payload_json, provider_instance_id)
        VALUES
          ('import:codex:01a18ada-28dd-74a2-a756-000000000002', 'p1', '续跑导入线程', 'codex', '\(tStarted)', '\(tNow)', '{}', 'codex');
        INSERT INTO orchestration_v2_projection_runs
          (run_id, thread_id, ordinal, provider, status, requested_at, payload_json, provider_instance_id)
        VALUES
          ('run-7', 'import:codex:01a18ada-28dd-74a2-a756-000000000002', 1, 'codex', 'running', '\(tStarted)', '{}', 'codex');

        -- 8. 已归档与已删除线程（应被过滤）
        INSERT INTO orchestration_v2_projection_threads
          (thread_id, project_id, title, default_provider, created_at, updated_at, archived_at, payload_json)
        VALUES
          ('th-archived', 'p1', '已归档', 'codex', '\(tStarted)', '\(tNow)', '\(tNow)', '{}');
        INSERT INTO orchestration_v2_projection_threads
          (thread_id, project_id, title, default_provider, created_at, updated_at, deleted_at, payload_json)
        VALUES
          ('th-deleted', 'p1', '已删除', 'codex', '\(tStarted)', '\(tNow)', '\(tNow)', '{}');
        """)
        sqlite3_close(database)

        let adapter = T3CodeAdapter(baseDirectory: dir, isServerAlive: { true })
        let sessions = try adapter.scan()
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        #expect(sessions.count == 6)
        #expect(byID["t3Code:import:codex:01a18ada-28dd-74a2-a756-fddc87ffdb4f"] == nil)
        #expect(byID["t3Code:th-archived"] == nil)
        #expect(byID["t3Code:th-deleted"] == nil)

        let running = try #require(byID["t3Code:th-running"])
        #expect(running.state == .running)
        #expect(running.cwd == "/Users/test/code/agent-monitor-wt")
        #expect(running.detail == "正在运行 swift test --filter T3Code")
        #expect(running.t3Code?.environmentID == "env-123")
        #expect(running.t3Code?.displayLabel == "T3 Code · Antigravity")
        #expect(running.t3Code?.nativeSessionID == nil) // pending: 占位符不应作为原生 ID
        #expect(running.usage?.contextTokens == 173_555)
        #expect(running.usage?.contextWindow == 1_048_576)
        #expect(running.usage?.model == "gemini-4-neon")
        #expect(abs(running.stateSince.timeIntervalSince(now.addingTimeInterval(-95))) < 2.0)

        let approval = try #require(byID["t3Code:th-approval"])
        #expect(approval.state == .waitingForUser)
        #expect(approval.waitingLabel == "等待授权")
        #expect(approval.detail == "git push --force origin main")
        #expect(approval.detailIsCommand == true)
        #expect(approval.cwd == "/Users/test/code/agent-monitor")

        let question = try #require(byID["t3Code:th-question"])
        #expect(question.state == .waitingForUser)
        #expect(question.waitingLabel == "在问你")
        #expect(question.detail == "需要保留旧配置兼容吗？")
        #expect(question.detailIsCommand == false)
        #expect(question.t3Code?.displayLabel == "T3 Code · Claude Code")

        let done = try #require(byID["t3Code:th-done"])
        #expect(done.state == .idle)
        #expect(done.suppressCompletion == false)
        #expect(done.detail == "全部测试已经通过。")

        let failed = try #require(byID["t3Code:th-failed"])
        #expect(failed.state == .idle)
        #expect(failed.suppressCompletion == true)

        let resumedImport = try #require(byID["t3Code:import:codex:01a18ada-28dd-74a2-a756-000000000002"])
        #expect(resumedImport.state == .running)

        // 当服务进程退出时，所有活跃态降级为 idle 且抑制误报完成
        let offlineAdapter = T3CodeAdapter(baseDirectory: dir, isServerAlive: { false })
        let offlineSessions = try offlineAdapter.scan()
        for s in offlineSessions {
            #expect(s.state == .idle)
            #expect(s.suppressCompletion == true)
        }
    }

    @Test("WAL 数据库在无 -wal/-shm 文件时仍可只读扫描且不产生伴生文件")
    func walImmutableRead() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("statev2.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        let database = try #require(db)
        try createSchema(in: database)
        let now = iso(Date())
        try exec(database, """
        INSERT INTO projection_projects(project_id, title, workspace_root, created_at, updated_at)
        VALUES ('p1', 'demo', '/Users/test/demo', '\(now)', '\(now)');
        INSERT INTO orchestration_v2_projection_threads
          (thread_id, project_id, title, default_provider, created_at, updated_at, payload_json)
        VALUES
          ('th-1', 'p1', 'WAL 快照测试', 'codex', '\(now)', '\(now)', '{}');
        """)
        sqlite3_close(database)

        // 模拟空闲 checkpoint 后移除 -wal / -shm
        try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")
        try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")

        let adapter = T3CodeAdapter(baseDirectory: dir, isServerAlive: { false })
        let sessions = try adapter.scan()
        #expect(sessions.count == 1)
        #expect(sessions.first?.title == "WAL 快照测试")
        #expect(!FileManager.default.fileExists(atPath: dbURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: dbURL.path + "-shm"))
    }

    @Test("SessionStore 在 T3 Code 运行转为 completed 时升级为已完成，失败时不升级")
    func storePromotion() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("statev2.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        let database = try #require(db)
        try createSchema(in: database)
        let now = iso(Date())
        try exec(database, """
        INSERT INTO projection_projects(project_id, title, workspace_root, created_at, updated_at)
        VALUES ('p1', 'demo', '/Users/test/demo', '\(now)', '\(now)');
        INSERT INTO orchestration_v2_projection_threads
          (thread_id, project_id, title, default_provider, created_at, updated_at, payload_json)
        VALUES
          ('th-ok', 'p1', '正常完成', 'antigravity', '\(now)', '\(now)', '{}'),
          ('th-abort', 'p1', '中途取消', 'antigravity', '\(now)', '\(now)', '{}');
        INSERT INTO orchestration_v2_projection_runs
          (run_id, thread_id, ordinal, provider, status, requested_at, payload_json)
        VALUES
          ('r1', 'th-ok', 1, 'antigravity', 'running', '\(now)', '{}'),
          ('r2', 'th-abort', 1, 'antigravity', 'running', '\(now)', '{}');
        """)

        let adapter = T3CodeAdapter(baseDirectory: dir, isServerAlive: { true })
        let store = SessionStore(adapters: [adapter])
        store.refresh()
        #expect(store.currentSessions.allSatisfy { $0.state == .running })

        let doneTime = iso(Date().addingTimeInterval(2))
        try exec(database, """
        UPDATE orchestration_v2_projection_runs SET status = 'completed', completed_at = '\(doneTime)' WHERE run_id = 'r1';
        UPDATE orchestration_v2_projection_runs SET status = 'cancelled', completed_at = '\(doneTime)' WHERE run_id = 'r2';
        UPDATE orchestration_v2_projection_threads SET updated_at = '\(doneTime)';
        """)
        sqlite3_close(database)

        store.refresh()
        let byID = Dictionary(uniqueKeysWithValues: store.currentSessions.map { ($0.id, $0) })
        #expect(byID["t3Code:th-ok"]?.state == .completed)
        #expect(byID["t3Code:th-abort"]?.state == .idle)
    }

    @Test("父子线程层级保留老父会话，并与本地原生会话去重合并")
    func hierarchyAndDeduplication() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("statev2.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        let database = try #require(db)
        try createSchema(in: database)

        let oldTime = iso(Date().addingTimeInterval(-48 * 3600))
        let nowTime = iso(Date())
        try exec(database, """
        INSERT INTO projection_projects(project_id, title, workspace_root, created_at, updated_at)
        VALUES ('p1', 'demo', '/Users/test/demo', '\(oldTime)', '\(nowTime)');
        INSERT INTO orchestration_v2_projection_threads
          (thread_id, project_id, title, default_provider, active_provider_thread_id, created_at, updated_at, payload_json)
        VALUES
          ('th-parent', 'p1', '主线程', 'codex', 'pt-parent', '\(oldTime)', '\(oldTime)', '{"lineage":{"parentThreadId":null}}'),
          ('th-child', 'p1', '委派子线程', 'codex', NULL, '\(nowTime)', '\(nowTime)', '{"lineage":{"parentThreadId":"th-parent"}}');
        INSERT INTO orchestration_v2_projection_provider_threads
          (provider_thread_id, thread_id, provider, status, updated_at, payload_json)
        VALUES
          ('pt-parent', 'th-parent', 'codex', 'idle', '\(oldTime)',
           '{"nativeThreadRef":{"driver":"codex","nativeId":"01a188df-cf09-7763-8796-5609ef455ca1"}}');
        INSERT INTO orchestration_v2_projection_runs
          (run_id, thread_id, ordinal, provider, status, requested_at, payload_json)
        VALUES
          ('r-child', 'th-child', 1, 'codex', 'running', '\(nowTime)', '{}');
        """)
        sqlite3_close(database)

        let adapter = T3CodeAdapter(baseDirectory: dir, maxAgeSeconds: 6 * 3600, isServerAlive: { true })
        let scanned = try adapter.scan()
        #expect(scanned.count == 2)
        let child = try #require(scanned.first { $0.id == "t3Code:th-child" })
        #expect(child.parentSessionID == "t3Code:th-parent")

        let parent = try #require(scanned.first { $0.id == "t3Code:th-parent" })
        #expect(parent.t3Code?.localIdentity == "codex:01a188df-cf09-7763-8796-5609ef455ca1")

        // 验证与本地 Codex 原生会话的去重合并以及子代理父引用重定向
        let nativeUsage = SessionUsage(model: "gpt-6", inputTokens: 1200, outputTokens: 300)
        let nativeCodex = AgentSession(
            id: "codex:01a188df-cf09-7763-8796-5609ef455ca1",
            kind: .codex,
            title: "native codex",
            state: .idle,
            transcriptPath: "/tmp/rollout.jsonl",
            usage: nativeUsage
        )
        let nativeSub = AgentSession(
            id: "codex:sub-1",
            kind: .codex,
            title: "native sub",
            state: .running,
            parentSessionID: nativeCodex.id
        )
        let unrelated = AgentSession(id: "codex:other", kind: .codex, title: "other", state: .idle)

        let merged = T3CodeAdapter.merging([parent, child, nativeCodex, nativeSub, unrelated])
        #expect(merged.count == 4)
        #expect(!merged.contains { $0.id == nativeCodex.id })
        #expect(merged.contains { $0.id == unrelated.id })
        #expect(merged.first { $0.id == parent.id }?.usage == nativeUsage)
        #expect(merged.first { $0.id == parent.id }?.transcriptPath == "/tmp/rollout.jsonl")
        #expect(merged.first { $0.id == nativeSub.id }?.parentSessionID == parent.id)
    }
}
