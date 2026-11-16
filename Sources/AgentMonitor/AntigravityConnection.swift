import Foundation

/// Uses the loopback DevTools endpoint that Antigravity itself publishes for
/// local integration. Never enables remote debugging or changes app settings.
struct AntigravityConnection: Sendable {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser

    struct Page: Decodable, Sendable, Equatable {
        let id: String
        let type: String
        let title: String?
        let url: String
        let webSocketDebuggerUrl: String?

        init(id: String, type: String = "page", title: String? = nil, url: String, webSocketDebuggerUrl: String? = nil) {
            self.id = id
            self.type = type
            self.title = title
            self.url = url
            self.webSocketDebuggerUrl = webSocketDebuggerUrl
        }
    }

    private struct DaemonHubInfo: Decodable, Sendable {
        let pid: Int32?
        let httpsPort: Int?
        let httpPort: Int?
    }

    func focus(nativeID: String) async -> Bool {
        guard UUID(uuidString: nativeID) != nil else { return false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        // Antigravity writes this file at each launch. Do not cache the port.
        let file = home.appendingPathComponent("Library/Application Support/Antigravity/DevToolsActivePort")
        guard let contents = try? String(contentsOf: file, encoding: .utf8),
              let line = contents.split(separator: "\n").first,
              let port = Int(line), (1...65535).contains(port),
              let endpoint = URL(string: "http://127.0.0.1:\(port)/json/list") else { return false }
        do {
            let pages = try await pages(session: session, endpoint: endpoint)
            let hubPorts = activeHubPorts()
            var candidates = Self.selectHubCandidates(from: pages, activeHubPorts: hubPorts)
            if candidates.count > 1 {
                candidates = await filterVerifiedHubPages(candidates, session: session, port: port)
            }
            guard candidates.count == 1, let page = candidates.first,
                  let current = URL(string: page.url),
                  let target = Self.conversationURL(current: current, nativeID: nativeID) else { return false }
            if current.path == target.path { return true }
            guard let debugger = page.webSocketDebuggerUrl, let socketURL = URL(string: debugger),
                  socketURL.scheme == "ws", socketURL.host == "127.0.0.1", socketURL.port == port else { return false }
            let socket = session.webSocketTask(with: socketURL)
            socket.resume()
            defer { socket.cancel(with: .goingAway, reason: nil) }
            let navigatedInPlace: Bool
            if let expression = Self.clientNavigationExpression(target: target) {
                let evalCommand = try JSONSerialization.data(withJSONObject: [
                    "id": 1,
                    "method": "Runtime.evaluate",
                    "params": [
                        "expression": expression,
                        "returnByValue": true
                    ]
                ])
                try await socket.send(.string(String(decoding: evalCommand, as: UTF8.self)))
                navigatedInPlace = try await acknowledgeEvaluation(socket, id: 1)
            } else {
                navigatedInPlace = false
            }
            if !navigatedInPlace {
                let navCommand = try JSONSerialization.data(withJSONObject: [
                    "id": 2, "method": "Page.navigate", "params": ["url": target.absoluteString]
                ])
                try await socket.send(.string(String(decoding: navCommand, as: UTF8.self)))
                guard try await acknowledgeNavigation(socket, id: 2) else { return false }
            }
            // A command accepted by Chromium is not proof of selecting a chat.
            // Verify the page URL reported by the same target after navigation.
            for attempt in 0..<10 {
                if attempt > 0 || !navigatedInPlace {
                    try await Task.sleep(for: .milliseconds(150))
                }
                let updated = try await self.pages(session: session, endpoint: endpoint)
                if let selected = updated.first(where: { $0.id == page.id }),
                   let url = URL(string: selected.url), isAntigravityConversationURL(url, nativeID: nativeID) { return true }
            }
        } catch { return false }
        return false
    }

    static func isHubPage(type: String, url: String) -> Bool {
        guard type == "page", let url = URL(string: url), ["http", "https"].contains(url.scheme),
              ["127.0.0.1", "localhost"].contains(url.host), url.port != nil else { return false }
        // Exclude embedded plugin/webview pages even if they use loopback URLs.
        return url.path == "/" || url.path.hasPrefix("/c/") ||
            url.path == "/history" || url.path.hasPrefix("/history/") ||
            url.path == "/sidecars" || url.path.hasPrefix("/sidecars/") ||
            url.path == "/customizations" || url.path.hasPrefix("/customizations/") ||
            url.path.hasPrefix("/view/") || url.path.hasPrefix("/battle/") || url.path.hasPrefix("/forked/")
    }

    /// 从 `/json/list` 候选页面中过滤掉内置浏览器（WebContentsView）打开的 `localhost` 开发页面，
    /// 精准选出真实的 Antigravity Hub 主窗口。
    static func selectHubCandidates(from pages: [Page], activeHubPorts: Set<Int> = []) -> [Page] {
        var candidates = pages.filter { isHubPage(type: $0.type, url: $0.url) }
        guard candidates.count > 1 else { return candidates }

        if !activeHubPorts.isEmpty {
            let portMatched = candidates.filter { page in
                guard let port = URL(string: page.url)?.port else { return false }
                return activeHubPorts.contains(port)
            }
            if !portMatched.isEmpty {
                candidates = portMatched
                if candidates.count == 1 { return candidates }
            }
        }

        let definite = candidates.filter(isDefiniteHubCandidate)
        if !definite.isEmpty {
            candidates = definite
        }
        return candidates
    }

    private static func isDefiniteHubCandidate(_ page: Page) -> Bool {
        if let rawTitle = page.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           rawTitle == "Antigravity" || rawTitle.hasSuffix(" - Antigravity") {
            return true
        }
        guard let url = URL(string: page.url) else { return false }
        if url.path.hasPrefix("/c/") {
            let tail = url.path.dropFirst(3)
            let parts = tail.split(separator: "+")
            if !parts.isEmpty, parts.allSatisfy({ UUID(uuidString: String($0)) != nil }) {
                return true
            }
        }
        return url.path == "/sidecars" || url.path.hasPrefix("/sidecars/") ||
            url.path == "/customizations" || url.path.hasPrefix("/customizations/") ||
            url.path.hasPrefix("/battle/") || url.path.hasPrefix("/forked/")
    }

    /// 读取 `~/.gemini/antigravity/daemon/hub_*.json` 中存活 `language_server` 实例的 Hub 端口。
    func activeHubPorts() -> Set<Int> {
        let daemonDir = home.appendingPathComponent(".gemini/antigravity/daemon")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: daemonDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var ports = Set<Int>()
        let decoder = JSONDecoder()
        for file in files where file.lastPathComponent.hasPrefix("hub_") && file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let info = try? decoder.decode(DaemonHubInfo.self, from: data) else { continue }
            if let pid = info.pid, pid > 1, kill(pid, 0) != 0 {
                continue
            }
            if let p = info.httpsPort, (1...65535).contains(p) { ports.insert(p) }
            if let p = info.httpPort, (1...65535).contains(p) { ports.insert(p) }
        }
        return ports
    }

    /// 当静态特征仍存在多个候选时，通过只读 `Runtime.evaluate` 校验 preload/全局配置并优先选聚焦窗口。
    private func filterVerifiedHubPages(_ candidates: [Page], session: URLSession, port: Int) async -> [Page] {
        var verified: [(page: Page, priority: Int)] = []
        for candidate in candidates {
            guard let priority = await probeHubPagePriority(candidate, session: session, port: port),
                  priority >= 0 else { continue }
            verified.append((candidate, priority))
        }
        guard !verified.isEmpty else { return candidates }
        if verified.count == 1 { return [verified[0].page] }
        let maxPriority = verified.map(\.priority).max() ?? 0
        let top = verified.filter { $0.priority == maxPriority }
        if top.count == 1 { return [top[0].page] }
        return verified.map(\.page)
    }

    private func probeHubPagePriority(_ page: Page, session: URLSession, port: Int) async -> Int? {
        guard let debugger = page.webSocketDebuggerUrl, let socketURL = URL(string: debugger),
              socketURL.scheme == "ws", socketURL.host == "127.0.0.1", socketURL.port == port else { return nil }
        let socket = session.webSocketTask(with: socketURL)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        let expr = """
        (window.__APP_CONFIG__?.productName === "antigravity" || typeof window.electronNative !== "undefined")
            ? (document.hasFocus() ? 2 : (document.visibilityState === "visible" ? 1 : 0))
            : -1
        """
        do {
            let cmd = try JSONSerialization.data(withJSONObject: [
                "id": 99,
                "method": "Runtime.evaluate",
                "params": ["expression": expr, "returnByValue": true]
            ])
            try await socket.send(.string(String(decoding: cmd, as: UTF8.self)))
            let data = try await receiveResponseData(socket, id: 99)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["error"] == nil,
                  let result = object["result"] as? [String: Any],
                  result["exceptionDetails"] == nil,
                  let inner = result["result"] as? [String: Any],
                  let value = inner["value"] as? Int else { return nil }
            return value
        } catch {
            return nil
        }
    }

    static func conversationURL(current: URL, nativeID: String) -> URL? {
        guard UUID(uuidString: nativeID) != nil, isHubPage(type: "page", url: current.absoluteString),
              var components = URLComponents(url: current, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/c/\(nativeID)"
        // Retain platform flags; project/section selection belongs to the old chat.
        components.queryItems = components.queryItems?.filter { ["platform", "isEnterpriseDistribution"].contains($0.name) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        components.fragment = nil
        return components.url
    }

    /// 构造页内客户端路由（History API / TanStack Router）跳转表达式，
    /// 避免使用 Page.navigate 触发整页文档重载导致数秒黑屏。
    static func clientNavigationExpression(target: URL) -> String? {
        guard let components = URLComponents(url: target, resolvingAgainstBaseURL: false),
              components.path.hasPrefix("/c/") else { return nil }
        let relativeURL: String
        if let query = components.percentEncodedQuery, !query.isEmpty {
            relativeURL = "\(components.path)?\(query)"
        } else {
            relativeURL = components.path
        }
        guard let argsData = try? JSONSerialization.data(withJSONObject: [relativeURL, components.path], options: [.withoutEscapingSlashes]),
              let argsJSON = String(data: argsData, encoding: .utf8) else { return nil }
        return """
        (([targetUrl, targetPath]) => {
            if (window.location.pathname === targetPath) return true;
            const prevState = window.history.state;
            const nextIndex = (prevState && typeof prevState.__TSR_index === "number") ? prevState.__TSR_index + 1 : 0;
            const key = Math.random().toString(36).slice(2, 8);
            const nextState = { __TSR_index: nextIndex, key: key, __TSR_key: key };
            const isPatched = window.history.pushState !== History.prototype.pushState;
            window.history.pushState(nextState, "", targetUrl);
            if (!isPatched) {
                window.dispatchEvent(new PopStateEvent("popstate", { state: nextState }));
            }
            return window.location.pathname === targetPath;
        })(\(argsJSON))
        """
    }

    private func pages(session: URLSession, endpoint: URL) async throws -> [Page] {
        let (data, response) = try await session.data(from: endpoint)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ConnectionError.invalidResponse }
        return try JSONDecoder().decode([Page].self, from: data)
    }

    private enum ConnectionError: Error { case invalidResponse, timeout }

    private func acknowledgeEvaluation(_ socket: URLSessionWebSocketTask, id: Int) async throws -> Bool {
        let data = try await receiveResponseData(socket, id: id)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil,
              let result = object["result"] as? [String: Any],
              result["exceptionDetails"] == nil,
              let inner = result["result"] as? [String: Any] else { return false }
        return inner["value"] as? Bool == true
    }

    private func acknowledgeNavigation(_ socket: URLSessionWebSocketTask, id: Int) async throws -> Bool {
        let data = try await receiveResponseData(socket, id: id)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let result = object["result"] as? [String: Any]
        return object["error"] == nil && result != nil && result?["errorText"] == nil
    }

    private func receiveResponseData(_ socket: URLSessionWebSocketTask, id: Int) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                while true {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .data(let bytes): data = bytes
                    case .string(let string): data = Data(string.utf8)
                    @unknown default: continue
                    }
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          object["id"] as? Int == id else { continue }
                    return data
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                socket.cancel(with: .goingAway, reason: nil)
                throw ConnectionError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next() ?? Data()
        }
    }
}
