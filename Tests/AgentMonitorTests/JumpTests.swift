import Foundation
import Testing
import AppKit
@testable import AgentMonitor
@testable import AgentMonitorCore

@Suite("Session Jump and Host Resolution Tests")
struct JumpTests {

    @Test("HostResolver: resolve current process and invalid pid")
    func testHostResolver() {
        let currentPid = getpid()
        // Resolving current process may or may not find a GUI host depending on CI / terminal environment,
        // but it must never crash.
        let info = HostResolver.shared.resolve(pid: currentPid)
        if let info = info {
            #expect(!info.app.isTerminated)
        }

        // Invalid pid returns nil
        #expect(HostResolver.shared.resolve(pid: 0) == nil)
        #expect(HostResolver.shared.resolve(pid: -1) == nil)
        #expect(HostResolver.shared.resolve(pid: 99999999) == nil)
    }

    @Test("FocusStrategies: title normalization")
    func testTitleNormalization() {
        let cases: [(input: String, expected: String)] = [
            ("✳ 多 agent 会话监控面板", "多 agent 会话监控面板"),
            ("⠂ Foo  Bar", "foo bar"),
            ("  Claude  Code  ", "claude code"),
            ("✨ [WIP] Project  Title   123 ", "wip] project title 123"),
            ("--- Normal  Case ---", "normal case ---"),
            ("", "")
        ]

        for c in cases {
            let normalized = FocusStrategies.normalizeTitle(c.input)
            #expect(normalized == c.expected)
        }
    }

    @Test("SessionJumper: target resolution fallbacks")
    @MainActor
    func testSessionJumperTargetResolution() {
        let jumper = SessionJumper.shared

        // Claude Code without pid -> Terminal or Claude desktop
        let sClaude = AgentSession(
            id: "claude-1",
            kind: .claudeCode,
            title: "Task 1",
            state: .running,
            entrypoint: "cli"
        )
        if case .app(let bundleId) = jumper.target(for: sClaude) {
            #expect(!bundleId.isEmpty)
        } else {
            Issue.record("Expected .app jump target for claude CLI without pid")
        }

        // Antigravity -> app
        let sAgy = AgentSession(
            id: "agy-1",
            kind: .antigravity,
            title: "Task 2",
            state: .waitingForUser
        )
        if case .app(let bundleId) = jumper.target(for: sAgy) {
            #expect(bundleId == "com.google.antigravity")
        } else {
            Issue.record("Expected .app jump target for antigravity")
        }

        // describeTarget should return readable description without crashing
        let desc = jumper.describeTarget(for: sAgy)
        #expect(desc != nil && !desc!.isEmpty)
    }
}
