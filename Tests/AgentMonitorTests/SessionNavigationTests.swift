import Foundation
import Testing
import AgentMonitorCore
@testable import AgentMonitor

@Suite("Session navigation")
struct SessionNavigationTests {
    private let uuid = "01a188df-cf09-7763-8796-5609ef455ca1"
    private let other = "68660d06-0ce7-42f3-b8a1-7b17a91fbae4"

    @Test("Paseo uses the exact host and agent, including remote provider ID collisions")
    func paseoHostRoute() {
        let resolver = SessionNavigationResolver(home: URL(fileURLWithPath: "/nonexistent"))
        let origin = PaseoOrigin(serverID: "server with/slash", agentID: other, hostName: "remote", isLocal: false,
                                 provider: "codex", nativeSessionID: uuid, connected: false)
        let target = resolver.resolve(.init(kind: .paseo, sessionID: "paseo:server:\(other)", paseo: origin))
        #expect(target == .deepLink(URL(string: "paseo://h/server%20with%2Fslash/agent/\(other)")!, bundleID: "sh.paseo.desktop"))
        var invalid = origin; invalid.agentID = "../../new?prompt=hello"
        #expect(invalid.deepLink == nil)
    }

    @Test("Codex routes to the native chat ID")
    func codexRoute() {
        let resolver = SessionNavigationResolver(home: URL(fileURLWithPath: "/nonexistent"))
        #expect(resolver.resolve(.init(kind: .codex, sessionID: "codex:\(uuid)")) ==
                .deepLink(URL(string: "codex://threads/\(uuid)")!, bundleID: "com.openai.codex"))
    }

    @Test("Malformed IDs cannot become URLs or process selectors")
    func invalidIDs() {
        for id: String? in [nil, "", "codex:", "codex:../../new", "codex:\(uuid)?prompt=hello", "claudeCode:\(uuid)", "codex:session-\(uuid)"] {
            #expect(SessionNavigationRequest(kind: .codex, sessionID: id).nativeID == nil)
        }
        #expect(SessionNavigationRequest(kind: .dsh, sessionID: "dsh:session-\(uuid)").nativeID == "session-\(uuid)")
    }

    @Test("Claude maps the CLI ID to the existing desktop ID, not the title or cwd")
    func claudeMapping() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let resolver = SessionNavigationResolver(home: home)
        let path = "Library/Application Support/Claude/claude-code-sessions/account/org"
        try write(["sessionId": "local_\(other)", "cliSessionId": uuid, "title": "same", "cwd": "/work"], to: home, path: "\(path)/target.json")
        try write(["sessionId": "local_\(uuid)", "cliSessionId": other, "title": "same", "cwd": "/work"], to: home, path: "\(path)/wrong.json")
        let target = resolver.resolve(.init(kind: .claudeCode, sessionID: "claudeCode:\(uuid)", entrypoint: "claude-desktop"))
        #expect(target == .deepLink(URL(string: "claude://code/continue?session=local_\(other)")!, bundleID: "com.anthropic.claudefordesktop"))
        // Explicit CLI entry points must not be imported into the desktop app.
        if case .deepLink = resolver.resolve(.init(kind: .claudeCode, sessionID: "claudeCode:\(uuid)", entrypoint: "cli")) {
            Issue.record("CLI session must stay in its original terminal")
        }
    }

    @Test("Archived or ambiguous Claude records do not select an arbitrary chat")
    func claudeAmbiguity() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let resolver = SessionNavigationResolver(home: home)
        let path = "Library/Application Support/Claude/claude-code-sessions"
        try write(["sessionId": "local_\(other)", "cliSessionId": uuid, "isArchived": true], to: home, path: "\(path)/a.json")
        #expect(resolver.claudeDesktopID(for: uuid) == nil)
        try write(["sessionId": "local_\(other)", "cliSessionId": uuid], to: home, path: "\(path)/a.json")
        try write(["sessionId": "local_\(uuid)", "cliSessionId": uuid], to: home, path: "\(path)/b.json")
        #expect(resolver.claudeDesktopID(for: uuid) == nil)
    }

    @Test("DSH plugin ID maps to Paseo's agent and server IDs")
    func paseoMapping() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let resolver = SessionNavigationResolver(home: home)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".paseo"), withIntermediateDirectories: true)
        try "server with/slash\n".write(to: home.appendingPathComponent(".paseo/server-id"), atomically: true, encoding: .utf8)
        let plugin = "plugin:{\"version\":1,\"data\":{\"dshSessionId\":\"\(uuid)\"}}"
        try write(["id": other, "provider": "dsh-pi", "runtimeInfo": ["sessionId": plugin]], to: home, path: ".paseo/agents/work/agent.json")
        #expect(resolver.resolve(.init(kind: .dsh, sessionID: "dsh:\(uuid)")) ==
                .deepLink(URL(string: "paseo://h/server%20with%2Fslash/agent/\(other)")!, bundleID: "sh.paseo.desktop"))
        #expect(resolver.paseoLink(for: other) == nil)
        #expect(SessionNavigationResolver.paseoNativeID("plugin:broken") == nil)
    }

    @Test("Antigravity routes on the existing dynamic origin and drops the old project")
    func antigravityRoute() {
        let current = URL(string: "http://127.0.0.1:57445/c/\(other)?section=old&platform=electron#old")!
        #expect(AntigravityConnection.conversationURL(current: current, nativeID: uuid)?.absoluteString ==
                "http://127.0.0.1:57445/c/\(uuid)?platform=electron")
        #expect(isAntigravityConversationURL(URL(string: "http://localhost:1234/c/\(uuid)?section=any")!, nativeID: uuid))
        #expect(!isAntigravityConversationURL(URL(string: "https://example.com/c/\(uuid)")!, nativeID: uuid))
        #expect(!isAntigravityConversationURL(URL(string: "http://localhost:1234/c/\(uuid)/extra")!, nativeID: uuid))
        let secureOrigin = URL(string: "https://127.0.0.1:57445/c/\(other)?section=old")!
        #expect(AntigravityConnection.conversationURL(current: secureOrigin, nativeID: uuid)?.absoluteString ==
                "https://127.0.0.1:57445/c/\(uuid)")
        #expect(!AntigravityConnection.isHubPage(type: "webview", url: current.absoluteString))
        #expect(!AntigravityConnection.isHubPage(type: "page", url: "http://localhost:1234/plugin/index.html"))
        #expect(AntigravityConnection.isHubPage(type: "page", url: "https://127.0.0.1:57445/history"))
        #expect(AntigravityConnection.isHubPage(type: "page", url: "https://127.0.0.1:57445/sidecars/abc"))
        #expect(AntigravityConnection.isHubPage(type: "page", url: "https://127.0.0.1:57445/battle/abc"))
        #expect(AntigravityConnection.conversationURL(current: current, nativeID: "../new") == nil)

        let target = AntigravityConnection.conversationURL(current: current, nativeID: uuid)!
        let expr = AntigravityConnection.clientNavigationExpression(target: target)
        #expect(expr?.contains("\"/c/\(uuid)?platform=electron\"") == true)
        #expect(expr?.contains("\"/c/\(uuid)\"") == true)
        #expect(expr?.contains("window.history.pushState") == true)
        #expect(AntigravityConnection.clientNavigationExpression(target: URL(string: "https://127.0.0.1:57445/history")!) == nil)
    }

    @Test("Warp environment parsing extracts UUID, focus URL, and legacy ID")
    func warpEnvironmentParsing() {
        #expect(TerminalSessionNavigator.parseWarpSessionID(from: [
            "WARP_TERMINAL_SESSION_UUID=eaf77e3cde1d47f08a57dbfa4621e467",
            "WARP_FOCUS_URL=warp://session/eaf77e3cde1d47f08a57dbfa4621e467"
        ]) == "eaf77e3cde1d47f08a57dbfa4621e467")

        #expect(TerminalSessionNavigator.parseWarpSessionID(from: [
            "WARP_FOCUS_URL=warp://session/01a188df-cf09-7763-8796-5609ef455ca1"
        ]) == "01a188df-cf09-7763-8796-5609ef455ca1")

        #expect(TerminalSessionNavigator.parseWarpSessionID(from: [
            "WARP_SESSION_ID=legacy-session-id"
        ]) == "legacy-session-id")

        #expect(TerminalSessionNavigator.parseWarpSessionID(from: [
            "USER=test",
            "SHELL=/bin/zsh"
        ]) == nil)
    }

    @Test("Warp namespace mapping requires an unambiguous native ID")
    func warpMapping() throws {
        let data = Data(#"{"response":{"status":"ok","data":{"sessions":[{"id":"public-a","terminal_session_id":"native-a"},{"id":"public-b","terminal_session_id":"native-b"}]}}}"#.utf8)
        #expect(TerminalSessionNavigator.warpIDs(output: #"{"response":{"status":"ok","data":{"windows":[{"id":"w1"},{"id":"w2"}]}}}"#, collection: "windows") == ["w1", "w2"])
        #expect(TerminalSessionNavigator.warpIDs(output: #"{"response":{"status":"error"}}"#, collection: "tabs").isEmpty)
        #expect(TerminalSessionNavigator.warpPublicSessionID(data: data, nativeID: "native-b") == "public-b")
        #expect(TerminalSessionNavigator.warpPublicSessionID(data: data, nativeID: "unknown") == nil)
        let ambiguous = Data(#"[{"id":"a","session_id":"same"},{"id":"b","session_id":"same"}]"#.utf8)
        #expect(TerminalSessionNavigator.warpPublicSessionID(data: ambiguous, nativeID: "same") == nil)
    }

    @Test("Terminal selection follows the actual process ancestry and TTY")
    func terminalIdentity() {
        let processes = """
        100 1 ?? /Applications/Warp.app/Contents/MacOS/stable
        200 1 ?? /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
        201 200 ttys003 /bin/zsh
        202 201 ttys003 /Users/test/bin/claude
        301 100 ttys007 /bin/zsh
        302 301 ttys007 /Users/test/bin/dsh
        400 1 ?? /Applications/Warp.app/Contents/MacOS/stable
        401 400 ?? /Applications/Warp.app/Contents/MacOS/stable terminal-server --parent-pid=400
        402 401 ttys008 /bin/zsh
        403 402 ttys008 /Users/test/bin/claude
        """
        let terminal = TerminalSessionNavigator.resolveIdentity(processID: 202, listing: processes) { _ in nil }
        #expect(terminal?.bundleID == "com.apple.Terminal")
        #expect(terminal?.tty == "/dev/ttys003")
        #expect(terminal?.terminalPID == 200)
        let warp = TerminalSessionNavigator.resolveIdentity(processID: 302, listing: processes) { $0 == 301 ? "warp-native-id" : nil }
        #expect(warp?.bundleID == "dev.warp.Warp-Stable")
        #expect(warp?.warpSessionID == "warp-native-id")
        #expect(warp?.terminalPID == 100)
        let warpServer = TerminalSessionNavigator.resolveIdentity(processID: 403, listing: processes) { $0 == 403 ? "uuid-123" : nil }
        #expect(warpServer?.bundleID == "dev.warp.Warp-Stable")
        #expect(warpServer?.warpSessionID == "uuid-123")
        #expect(warpServer?.terminalPID == 400)
        #expect(warpServer?.tty == "/dev/ttys008")
        #expect(TerminalSessionNavigator.resolveIdentity(processID: 999, listing: processes) { _ in nil } == nil)
    }

    @Test("Navigation commands preserve argument boundaries and time out")
    func commands() {
        let result = NavigationCommand.run("/usr/bin/printf", ["%s", "literal $(touch /tmp/should-not-exist); `pwd`\nnext"])
        #expect(result.succeeded)
        #expect(result.output == "literal $(touch /tmp/should-not-exist); `pwd`\nnext")
        let start = Date()
        #expect(!NavigationCommand.run("/bin/sleep", ["3"], timeout: 0.05).succeeded)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test("Live Warp session identity resolution", .enabled(if: ProcessInfo.processInfo.environment["AGENT_MONITOR_LOCAL_NAVIGATION_TEST"] == "1"))
    func liveWarpIdentity() {
        let result = NavigationCommand.run("/bin/ps", ["-axo", "pid=,ppid=,tty=,comm="])
        #expect(result.succeeded)
        var found = false
        for line in result.output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 4, let pid = Int32(parts[0]) else { continue }
            let comm = parts[3]
            if comm.contains("dsh") || comm.contains("node") || comm.contains("claude") {
                if let identity = TerminalSessionNavigator.identity(processID: pid), identity.bundleID == "dev.warp.Warp-Stable" {
                    #expect(identity.warpSessionID != nil)
                    #expect(identity.tty.hasPrefix("/dev/tty"))
                    #expect(identity.terminalPID > 1)
                    found = true
                    break
                }
            }
        }
        #expect(found)
    }

    @Test("Read-only local metadata smoke test", .enabled(if: ProcessInfo.processInfo.environment["AGENT_MONITOR_LOCAL_NAVIGATION_TEST"] == "1"))
    func localMetadata() throws {
        let resolver = SessionNavigationResolver()
        let root = resolver.home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var checked = false
        for case let file as URL in files where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
            let data = try Data(contentsOf: file)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["isArchived"] as? Bool != true,
                  let native = json["cliSessionId"] as? String, let desktop = json["sessionId"] as? String else { continue }
            #expect(resolver.claudeDesktopID(for: native) == desktop)
            checked = true
            break
        }
        #expect(checked)
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-monitor-navigation-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ object: [String: Any], to home: URL, path: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}
