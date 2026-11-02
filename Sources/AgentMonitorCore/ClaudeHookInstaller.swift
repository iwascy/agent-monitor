import Foundation

public enum ClaudeHookInstallStatus: String, Sendable, Equatable {
    case installed
    case notInstalled
    case needsRepair
}

public enum ClaudeHookInstallerError: LocalizedError, Equatable {
    case invalidJSON
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "settings.json 不是有效的 JSON，请先手动修复"
        case .writeFailed(let reason):
            return "写入失败：\(reason)"
        }
    }
}

public final class ClaudeHookInstaller: @unchecked Sendable {
    public static let targetEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PermissionRequest",
        "Notification",
        "Stop",
        "StopFailure",
        "SessionEnd"
    ]

    public static let hookScriptBody = """
    #!/bin/sh
    # Agent Monitor: append one Claude Code hook event per line. Must print nothing.
    dir="$HOME/Library/Application Support/AgentMonitor/events"
    mkdir -p "$dir" 2>/dev/null
    { printf '%s\\t' "$(date +%s)"; tr -d '\\n'; printf '\\n'; } >> "$dir/claude.tsv" 2>/dev/null
    exit 0

    """

    public static var defaultSettingsURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/settings.json")
    }

    public static var defaultScriptURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/AgentMonitor/hooks/cc-event.sh")
    }

    public let settingsURL: URL
    public let scriptURL: URL

    public init(
        settingsURL: URL = ClaudeHookInstaller.defaultSettingsURL,
        scriptURL: URL = ClaudeHookInstaller.defaultScriptURL
    ) {
        self.settingsURL = settingsURL
        self.scriptURL = scriptURL
    }

    /// 构造每个事件要写入的 hook entry
    public func makeHookEntry(for event: String) -> [String: Any] {
        let hookItem: [String: Any] = [
            "type": "command",
            "async": true,
            "timeout": 5,
            "command": "\"$HOME/Library/Application Support/AgentMonitor/hooks/cc-event.sh\""
        ]

        // 不接受 matcher 的事件（UserPromptSubmit, Stop）省略 matcher 字段
        if event == "UserPromptSubmit" || event == "Stop" {
            return [
                "hooks": [hookItem]
            ]
        } else {
            return [
                "matcher": "*",
                "hooks": [hookItem]
            ]
        }
    }

    /// 生成将要写入的完整 hooks 片段字典
    public func generateDiffDictionary() -> [String: Any] {
        var hooksObj: [String: Any] = [:]
        for event in Self.targetEvents {
            hooksObj[event] = [makeHookEntry(for: event)]
        }
        return ["hooks": hooksObj]
    }

    /// 生成用于在确认 Sheet 中展示的 JSON 字符串
    public func generateDiffJSONString() -> String {
        let dict = generateDiffDictionary()
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    /// 判断某条 hook 命令是否属于 Agent Monitor
    public static func isAgentMonitorHook(command: String) -> Bool {
        return command.contains("AgentMonitor/hooks/cc-event.sh")
    }

    /// 检测安装状态
    public func checkStatus() -> ClaudeHookInstallStatus {
        let fm = FileManager.default

        let scriptExists = fm.fileExists(atPath: scriptURL.path)

        guard fm.fileExists(atPath: settingsURL.path) else {
            return .notInstalled
        }

        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .needsRepair
        }

        guard let hooks = json["hooks"] as? [String: Any] else {
            return .notInstalled
        }

        var installedCount = 0
        var totalHookCount = 0

        for event in Self.targetEvents {
            guard let entries = hooks[event] as? [[String: Any]] else {
                continue
            }
            var hasOurHook = false
            for entry in entries {
                if let hookList = entry["hooks"] as? [[String: Any]] {
                    for h in hookList {
                        if let cmd = h["command"] as? String, Self.isAgentMonitorHook(command: cmd) {
                            hasOurHook = true
                            totalHookCount += 1
                        }
                    }
                }
            }
            if hasOurHook {
                installedCount += 1
            }
        }

        if installedCount == 0 && totalHookCount == 0 {
            return .notInstalled
        }

        if installedCount == Self.targetEvents.count && scriptExists {
            return .installed
        }

        return .needsRepair
    }

    /// 安装 hook 脚本到目标路径
    public func installScript() throws {
        let fm = FileManager.default
        let parentDir = scriptURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let data = Data(Self.hookScriptBody.utf8)
        try data.write(to: scriptURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// 安装配置并写入
    public func install(backup: Bool = true) throws {
        try installScript()

        let fm = FileManager.default
        var root: [String: Any] = [:]

        if fm.fileExists(atPath: settingsURL.path) {
            let data: Data
            do {
                data = try Data(contentsOf: settingsURL)
            } catch {
                throw ClaudeHookInstallerError.writeFailed("无法读取 settings.json: \(error.localizedDescription)")
            }

            if !data.isEmpty {
                do {
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw ClaudeHookInstallerError.invalidJSON
                    }
                    root = json
                } catch {
                    throw ClaudeHookInstallerError.invalidJSON
                }
            }
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for event in Self.targetEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []

            // 检查是否已经存在我们的 hook
            var alreadyInstalled = false
            for entry in entries {
                if let hookList = entry["hooks"] as? [[String: Any]] {
                    for h in hookList {
                        if let cmd = h["command"] as? String, Self.isAgentMonitorHook(command: cmd) {
                            alreadyInstalled = true
                            break
                        }
                    }
                }
                if alreadyInstalled { break }
            }

            if !alreadyInstalled {
                entries.append(makeHookEntry(for: event))
            }
            hooks[event] = entries
        }

        root["hooks"] = hooks

        try writeSettings(root, backup: backup)
    }

    /// 卸载 hooks
    public func uninstall() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path) else {
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: settingsURL)
        } catch {
            throw ClaudeHookInstallerError.writeFailed("无法读取 settings.json")
        }

        guard !data.isEmpty else { return }

        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeHookInstallerError.invalidJSON
        }

        guard let hooks = root["hooks"] as? [String: Any] else {
            return
        }

        var updatedHooks: [String: Any] = [:]

        for (eventKey, eventVal) in hooks {
            guard let entries = eventVal as? [[String: Any]] else {
                updatedHooks[eventKey] = eventVal
                continue
            }

            var cleanedEntries: [[String: Any]] = []

            for var entry in entries {
                if let hookList = entry["hooks"] as? [[String: Any]] {
                    let filtered = hookList.filter { h in
                        guard let cmd = h["command"] as? String else { return true }
                        return !Self.isAgentMonitorHook(command: cmd)
                    }
                    if !filtered.isEmpty {
                        entry["hooks"] = filtered
                        cleanedEntries.append(entry)
                    }
                } else {
                    cleanedEntries.append(entry)
                }
            }

            if !cleanedEntries.isEmpty {
                updatedHooks[eventKey] = cleanedEntries
            }
        }

        if updatedHooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = updatedHooks
        }

        try writeSettings(root, backup: false)
    }

    /// 修复（卸载后再安装）
    public func repair(backup: Bool = true) throws {
        try uninstall()
        try install(backup: backup)
    }

    private func writeSettings(_ root: [String: Any], backup: Bool) throws {
        let fm = FileManager.default
        let parentDir = settingsURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        if backup && fm.fileExists(atPath: settingsURL.path) {
            let backupURL = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.agentmonitor-backup")
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: settingsURL, to: backupURL)
        }

        let outputData: Data
        do {
            outputData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        } catch {
            throw ClaudeHookInstallerError.writeFailed("JSON 序列化失败: \(error.localizedDescription)")
        }

        let tempURL = parentDir.appendingPathComponent("settings.json.tmp.\(UUID().uuidString)")
        do {
            try outputData.write(to: tempURL, options: .atomic)
            if fm.fileExists(atPath: settingsURL.path) {
                _ = try fm.replaceItemAt(settingsURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: settingsURL)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw ClaudeHookInstallerError.writeFailed("写入临时文件或原子替换失败: \(error.localizedDescription)")
        }
    }
}
