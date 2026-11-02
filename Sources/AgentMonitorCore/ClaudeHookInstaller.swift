import Foundation

public enum ClaudeHookInstallStatus: String, Sendable, Equatable {
    case installed
    case notInstalled
    case needsRepair
    case invalidJSON
}

public enum ClaudeHookInstallerError: LocalizedError, Equatable {
    case invalidJSON
    case unrecognizedHooksStructure
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "settings.json 不是有效的 JSON，请先手动修复"
        case .unrecognizedHooksStructure:
            return "settings.json 的 hooks 结构无法识别，请先手动检查"
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

        guard let data = try? Data(contentsOf: settingsURL) else {
            return .invalidJSON
        }

        if data.isEmpty {
            return .invalidJSON
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalidJSON
        }

        if json.keys.contains("hooks") && !(json["hooks"] is [String: Any]) {
            return .needsRepair
        }

        guard let hooks = json["hooks"] as? [String: Any] else {
            return .notInstalled
        }

        var installedCount = 0
        var totalHookCount = 0

        for event in Self.targetEvents {
            guard let entries = hooks[event] as? [Any] else {
                continue
            }
            var hasOurHook = false
            for item in entries {
                guard let entry = item as? [String: Any] else { continue }
                if let hookList = entry["hooks"] as? [Any] {
                    for h in hookList {
                        if let hDict = h as? [String: Any],
                           let cmd = hDict["command"] as? String,
                           Self.isAgentMonitorHook(command: cmd) {
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

    private func parseAndValidateSettings() throws -> [String: Any] {
        let realURL = settingsURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        guard fm.fileExists(atPath: realURL.path) else {
            return [:]
        }
        let data: Data
        do {
            data = try Data(contentsOf: realURL)
        } catch {
            throw ClaudeHookInstallerError.writeFailed("无法读取 settings.json: \(error.localizedDescription)")
        }
        if data.isEmpty {
            return [:]
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ClaudeHookInstallerError.invalidJSON
        }
        return json
    }

    private func validateHooksStructure(in root: [String: Any]) throws {
        guard let hooksVal = root["hooks"] else {
            return
        }
        guard let hooks = hooksVal as? [String: Any] else {
            throw ClaudeHookInstallerError.unrecognizedHooksStructure
        }
        for (_, val) in hooks {
            guard val is [Any] else {
                throw ClaudeHookInstallerError.unrecognizedHooksStructure
            }
        }
    }

    private func addHooks(to root: [String: Any]) throws -> [String: Any] {
        try validateHooksStructure(in: root)
        var updatedRoot = root
        var hooks = updatedRoot["hooks"] as? [String: Any] ?? [:]

        for event in Self.targetEvents {
            var entries = hooks[event] as? [Any] ?? []

            var alreadyInstalled = false
            for item in entries {
                if let entryDict = item as? [String: Any],
                   let hookList = entryDict["hooks"] as? [Any] {
                    for h in hookList {
                        if let hDict = h as? [String: Any],
                           let cmd = hDict["command"] as? String,
                           Self.isAgentMonitorHook(command: cmd) {
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

        updatedRoot["hooks"] = hooks
        return updatedRoot
    }

    private func removeHooks(from root: [String: Any]) throws -> (updated: [String: Any], changed: Bool) {
        try validateHooksStructure(in: root)
        guard let hooks = root["hooks"] as? [String: Any] else {
            return (root, false)
        }

        var updatedHooks: [String: Any] = [:]
        var hasChanges = false

        for (eventKey, eventVal) in hooks {
            guard let entries = eventVal as? [Any] else {
                updatedHooks[eventKey] = eventVal
                continue
            }

            var cleanedEntries: [Any] = []

            for item in entries {
                if var entryDict = item as? [String: Any],
                   let hookList = entryDict["hooks"] as? [Any] {
                    let filtered = hookList.filter { h in
                        guard let hDict = h as? [String: Any],
                              let cmd = hDict["command"] as? String else {
                            return true
                        }
                        return !Self.isAgentMonitorHook(command: cmd)
                    }

                    if filtered.count == hookList.count {
                        // 包括原本就为空的 hooks；未删除我们的命令时原样保留。
                        cleanedEntries.append(item)
                    } else if !filtered.isEmpty {
                        hasChanges = true
                        entryDict["hooks"] = filtered
                        cleanedEntries.append(entryDict)
                    } else {
                        hasChanges = true
                    }
                } else {
                    cleanedEntries.append(item)
                }
            }

            if cleanedEntries.count != entries.count {
                hasChanges = true
            }

            if !cleanedEntries.isEmpty {
                updatedHooks[eventKey] = cleanedEntries
            } else if entries.isEmpty {
                updatedHooks[eventKey] = entries
            } else {
                hasChanges = true
            }
        }

        var updatedRoot = root
        if updatedHooks.isEmpty {
            if !hooks.isEmpty {
                hasChanges = true
                updatedRoot.removeValue(forKey: "hooks")
            }
        } else {
            updatedRoot["hooks"] = updatedHooks
        }

        return (updatedRoot, hasChanges)
    }

    /// 安装配置并写入
    public func install(backup: Bool = true) throws {
        let root = try parseAndValidateSettings()
        let newRoot = try addHooks(to: root)

        try installScript()
        try writeSettings(newRoot, backup: backup)
    }

    /// 卸载 hooks
    public func uninstall() throws {
        let realURL = settingsURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        guard fm.fileExists(atPath: realURL.path) else {
            return
        }

        let root = try parseAndValidateSettings()
        guard !root.isEmpty else { return }

        let (newRoot, changed) = try removeHooks(from: root)
        guard changed else {
            return
        }

        try writeSettings(newRoot, backup: false)
    }

    /// 修复（卸载后再安装，只备份一次原文件，只写一次）
    public func repair(backup: Bool = true) throws {
        let root = try parseAndValidateSettings()
        let (cleanedRoot, _) = try removeHooks(from: root)
        let finalRoot = try addHooks(to: cleanedRoot)

        try installScript()
        try writeSettings(finalRoot, backup: backup)
    }

    private func writeSettings(_ root: [String: Any], backup: Bool) throws {
        let realURL = settingsURL.resolvingSymlinksInPath()
        let parentDir = realURL.deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        if backup && fm.fileExists(atPath: realURL.path) {
            let backupURL = parentDir.appendingPathComponent("settings.json.agentmonitor-backup")
            let backupTempURL = parentDir.appendingPathComponent("settings.json.backup.tmp.\(UUID().uuidString)")
            defer { try? fm.removeItem(at: backupTempURL) }
            do {
                // copyItem 同时保留权限和 ACL；rename 避免跟随已有备份的符号链接。
                try fm.copyItem(at: realURL, to: backupTempURL)
                try atomicRename(from: backupTempURL, to: backupURL)
            } catch {
                throw ClaudeHookInstallerError.writeFailed("备份 settings.json 失败: \(error.localizedDescription)")
            }
        }

        let outputData: Data
        do {
            outputData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        } catch {
            throw ClaudeHookInstallerError.writeFailed("JSON 序列化失败: \(error.localizedDescription)")
        }

        let tempURL = parentDir.appendingPathComponent("settings.json.tmp.\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempURL) }
        do {
            let permissions: Int
            if fm.fileExists(atPath: realURL.path) {
                let attrs = try fm.attributesOfItem(atPath: realURL.path)
                permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
                try fm.copyItem(at: realURL, to: tempURL)
                try fm.setAttributes([.posixPermissions: permissions | 0o200], ofItemAtPath: tempURL.path)
            } else {
                permissions = 0o600
                guard fm.createFile(atPath: tempURL.path, contents: nil, attributes: [.posixPermissions: permissions]) else {
                    throw ClaudeHookInstallerError.writeFailed("无法创建临时文件")
                }
            }
            let handle = try FileHandle(forWritingTo: tempURL)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: outputData)
            try handle.synchronize()
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: tempURL.path)
            try atomicRename(from: tempURL, to: realURL)
        } catch {
            throw ClaudeHookInstallerError.writeFailed("写入配置失败: \(error.localizedDescription)")
        }
    }

    private func atomicRename(from source: URL, to destination: URL) throws {
        if rename(source.path, destination.path) != 0 {
            let errStr = String(cString: strerror(errno))
            throw ClaudeHookInstallerError.writeFailed("原子覆盖真实文件失败: \(errStr)")
        }
    }
}
