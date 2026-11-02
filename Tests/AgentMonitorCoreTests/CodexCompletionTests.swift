import Foundation
import Testing
@testable import AgentMonitorCore

@Suite("Codex completion regressions")
struct CodexCompletionTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ records: [[String: Any]], to url: URL) throws {
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record))
            data.append(10)
        }
        try data.write(to: url)
    }

    private func event(_ type: String) -> [String: Any] {
        ["type": "event_msg", "payload": ["type": type]]
    }

    private func meta(_ payload: [String: Any]) -> [String: Any] {
        ["type": "session_meta", "payload": payload]
    }

    private func adapter(_ directory: URL, threshold: TimeInterval = 600) -> CodexAdapter {
        CodexAdapter(sessionsDirectory: directory,
                     sessionIndexURL: directory.appendingPathComponent("index.jsonl"),
                     activeThreshold: threshold)
    }

    @Test("Guardian completion cannot overwrite the running parent or notify")
    func guardianDoesNotCompleteParent() throws {
        let dir = try directory()
        let parent = dir.appendingPathComponent("rollout-parent.jsonl")
        let child = dir.appendingPathComponent("rollout-guardian.jsonl")
        try write([meta(["id": "parent", "session_id": "parent"]), event("task_started")], to: parent)
        let store = SessionStore(adapters: [adapter(dir)])
        store.refresh()
        #expect(store.currentSessions.first?.state == .running)

        // Real Codex Desktop metadata: session_id belongs to the parent, id to the guardian.
        let childMeta = meta(["id": "guardian", "session_id": "parent",
                              "parent_thread_id": "parent", "thread_source": "guardian_review",
                              "source": ["subagent": ["other": "guardian"]]])
        try write([childMeta, event("task_started"), event("task_complete")], to: child)
        let transitions = store.refresh()
        #expect(store.currentSessions.count == 1)
        #expect(store.currentSessions.first?.id == "codex:parent")
        #expect(store.currentSessions.first?.state == .running)
        #expect(transitions.isEmpty)

        try write([meta(["id": "parent"]), event("task_started"), event("task_complete")], to: parent)
        store.refresh()
        #expect(store.currentSessions.first?.state == .completed)
    }

    @Test("All subagent metadata forms are excluded")
    func excludesSubagents() throws {
        let dir = try directory()
        let markers: [[String: Any]] = [
            ["source": ["subagent": "review"]],
            ["source": "subagent"],
            ["parent_thread_id": "parent"],
            ["thread_source": "guardian_review"]
        ]
        for (index, marker) in markers.enumerated() {
            var payload = marker
            payload["id"] = "child-\(index)"
            try write([meta(payload), event("task_complete")],
                      to: dir.appendingPathComponent("rollout-child-\(index).jsonl"))
        }
        #expect(try adapter(dir).scan().isEmpty)
    }

    @Test("Native id takes precedence over session_id, including beyond the tail window")
    func nativeIdentity() throws {
        let dir = try directory()
        try write([meta(["id": "native", "session_id": "legacy"]), event("task_started")],
                  to: dir.appendingPathComponent("rollout-short.jsonl"))
        try write([meta(["id": "native-long", "session_id": "legacy-long"]),
                   ["type": "response_item", "payload": ["type": "reasoning", "text": String(repeating: "x", count: 100_000)]],
                   event("task_started")], to: dir.appendingPathComponent("rollout-long.jsonl"))
        #expect(Set(try adapter(dir).scan().map(\.id)) == ["codex:native", "codex:native-long"])
    }

    @Test("Timeout and abort never promote to completed; explicit completion still does")
    func completionRequiresEvidence() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("rollout-task.jsonl")
        let head = meta(["id": "task"])
        try write([head, event("task_started")], to: file)
        let store = SessionStore(adapters: [adapter(dir)])
        store.refresh()

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-601)], ofItemAtPath: file.path)
        store.refresh()
        #expect(store.currentSessions.first?.state == .idle)
        #expect(store.currentSessions.first?.suppressCompletion == true)

        try write([head, event("task_started")], to: file)
        store.refresh()
        try write([head, event("task_started"), event("turn_aborted")], to: file)
        store.refresh()
        #expect(store.currentSessions.first?.state == .idle)

        try write([head, event("task_started")], to: file)
        store.refresh()
        try write([head, event("task_started"), event("task_complete")], to: file)
        store.refresh()
        #expect(store.currentSessions.first?.state == .completed)
    }

    @Test("Large tool output and a partial next record preserve the active turn")
    func largeOutputDoesNotComplete() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("rollout-task.jsonl")
        let head = meta(["id": "task"])
        try write([head, event("task_started")], to: file)
        let store = SessionStore(adapters: [adapter(dir)])
        store.refresh()
        try write([head, event("task_started"),
                   ["type": "response_item", "payload": ["type": "function_call_output", "output": String(repeating: "输出", count: 50_000)]]], to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"event_msg","payload":{"type":"task_complete"}}"#.utf8))
        try handle.close()
        store.refresh()
        #expect(store.currentSessions.first?.state == .running)
    }
}
