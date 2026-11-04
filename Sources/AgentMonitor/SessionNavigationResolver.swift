import Foundation
import AgentMonitorCore

struct SessionNavigationRequest: Sendable {
    let kind: AgentKind
    let sessionID: String?
    var entrypoint: String? = nil
    var cwd: String? = nil
    var paseo: PaseoOrigin? = nil

    var nativeID: String? {
        guard let sessionID, sessionID.hasPrefix("\(kind.rawValue):") else { return nil }
        let value = String(sessionID.dropFirst(kind.rawValue.count + 1))
        // DSH sometimes prefixes its UUID with `session-`.
        let uuid = kind == .dsh && value.hasPrefix("session-") ? String(value.dropFirst(8)) : value
        guard UUID(uuidString: uuid) != nil else { return nil }
        return value
    }
}

enum SessionNavigationTarget: Equatable, Sendable {
    case deepLink(URL, bundleID: String)
    case antigravity(String)
    case terminal(processID: Int32)
    case unavailable(String)
}

/// Resolves native IDs from read-only on-disk metadata. Never imports/resumes a
/// second agent process just to bring the original conversation into view.
struct SessionNavigationResolver: Sendable {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser

    func resolve(_ request: SessionNavigationRequest) -> SessionNavigationTarget {
        if let origin = request.paseo {
            guard let link = origin.deepLink else { return .unavailable("Paseo 会话地址无效。") }
            return .deepLink(link, bundleID: "sh.paseo.desktop")
        }
        guard let id = request.nativeID else { return .unavailable("会话 ID 缺失或格式无效。") }
        switch request.kind {
        case .paseo:
            return .unavailable("缺少 Paseo 主机和会话信息。")
        case .codex:
            return .deepLink(URL(string: "codex://threads/\(id)")!, bundleID: "com.openai.codex")
        case .antigravity:
            return .antigravity(id)
        case .claudeCode:
            if request.entrypoint != "cli", let desktopID = claudeDesktopID(for: id) {
                var components = URLComponents()
                components.scheme = "claude"
                components.host = "code"
                components.path = "/continue"
                components.queryItems = [URLQueryItem(name: "session", value: desktopID)]
                return .deepLink(components.url!, bundleID: request.kind.bundleIdentifier)
            }
            if let pid = claudeProcessID(for: id) { return .terminal(processID: pid) }
            return .unavailable("未找到对应的 Claude 桌面会话或运行进程。")
        case .dsh:
            if let url = paseoLink(for: id) {
                return .deepLink(url, bundleID: "sh.paseo.desktop")
            }
            if let pid = dshProcessID(for: id) { return .terminal(processID: pid) }
            return .unavailable("未找到对应的 Paseo 会话或持有 DSH 会话锁的终端进程。")
        }
    }

    func claudeDesktopID(for nativeID: String) -> String? {
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        let matches = jsonFiles(in: root).compactMap { file -> String? in
            guard let json = readJSON(file), json["isArchived"] as? Bool != true,
                  json["cliSessionId"] as? String == nativeID,
                  let id = json["sessionId"] as? String,
                  id.hasPrefix("local_"), UUID(uuidString: String(id.dropFirst(6))) != nil else { return nil }
            return id
        }
        // An ambiguous cross-account match must not open a different conversation.
        return Set(matches).count == 1 ? matches.first : nil
    }

    func claudeProcessID(for nativeID: String) -> Int32? {
        let root = home.appendingPathComponent(".claude/sessions")
        let matches = jsonFiles(in: root).compactMap { file -> Int32? in
            guard let json = readJSON(file), json["sessionId"] as? String == nativeID,
                  let pid = json["pid"] as? Int, let value = Int32(exactly: pid), value > 1,
                  kill(value, 0) == 0 else { return nil }
            return value
        }
        return Set(matches).count == 1 ? matches.first : nil
    }

    func paseoLink(for nativeID: String) -> URL? {
        let root = home.appendingPathComponent(".paseo/agents")
        let matches = jsonFiles(in: root).compactMap { file -> String? in
            guard let json = readJSON(file), (json["archivedAt"] as? String)?.isEmpty != false,
                  json["archived"] as? Bool != true, json["isArchived"] as? Bool != true,
                  let runtime = json["runtimeInfo"] as? [String: Any],
                  let session = runtime["sessionId"] as? String,
                  Self.paseoNativeID(session) == nativeID,
                  let agentID = json["id"] as? String, UUID(uuidString: agentID) != nil else { return nil }
            return agentID
        }
        guard Set(matches).count == 1, let agentID = matches.first,
              let serverID = try? String(contentsOf: home.appendingPathComponent(".paseo/server-id"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !serverID.isEmpty,
              let segment = serverID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "paseo://h/\(segment)/agent/\(agentID)")
    }

    static func paseoNativeID(_ session: String) -> String? {
        // Paseo plugins serialize their provider session as plugin:{version,data}.
        guard session.hasPrefix("plugin:"), let data = String(session.dropFirst(7)).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any] else { return nil }
        return payload["dshSessionId"] as? String
    }

    func dshProcessID(for nativeID: String) -> Int32? {
        let root = home.appendingPathComponent(".dsh/sessions")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { return nil }
        var pids = Set<Int32>()
        for case let url as URL in enumerator where url.lastPathComponent == "session.lock" {
            // Require an exact session directory match; cwd and title are not identities.
            guard url.deletingLastPathComponent().lastPathComponent == nativeID else { continue }
            let result = NavigationCommand.run("/usr/sbin/lsof", ["-t", "--", url.path])
            for line in result.output.split(separator: "\n") {
                if let pid = Int32(line), pid > 1 { pids.insert(pid) }
            }
        }
        return pids.count == 1 ? pids.first : nil
    }

    private func jsonFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
    }

    private func readJSON(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
