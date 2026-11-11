import Foundation
import Darwin

struct TerminalSessionIdentity: Sendable {
    let tty: String
    let bundleID: String
    let terminalPID: Int32
    let warpSessionID: String?
}

enum TerminalSessionNavigator {
    static func identity(processID: Int32) -> TerminalSessionIdentity? {
        // 优先通过原生 sysctl + proc_pidpath 读取进程树，失败时再回退 /bin/ps 子进程
        if let listing = nativeProcessListing() {
            return resolveIdentity(processID: processID, listing: listing) { warpEnvironment(pid: $0) }
        }
        let result = NavigationCommand.run("/bin/ps", ["-axo", "pid=,ppid=,tty=,comm="])
        guard result.succeeded else { return nil }
        return resolveIdentity(processID: processID, listing: result.output) { warpEnvironment(pid: $0) }
    }

    /// 使用 Darwin 原生 sysctl 枚举系统进程表，避免启动外部 /bin/ps 进程。
    static func nativeProcessListing() -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var byteCount = 0
        guard sysctl(&mib, u_int(mib.count), nil, &byteCount, nil, 0) == 0, byteCount > 0 else {
            return nil
        }

        // 预留余量以防两次调用之间新进程派生导致 ENOMEM
        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = (byteCount / stride) + 64
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        var actualBytes = capacity * stride
        let status = procs.withUnsafeMutableBytes { buf in
            sysctl(&mib, u_int(mib.count), buf.baseAddress, &actualBytes, nil, 0)
        }
        guard status == 0, actualBytes >= stride else { return nil }

        let count = actualBytes / stride
        var lines: [String] = []
        lines.reserveCapacity(count)
        var pathBuffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)

        for i in 0..<count {
            let info = procs[i]
            let pid = info.kp_proc.p_pid
            guard pid > 0 else { continue }
            let ppid = info.kp_eproc.e_ppid

            let tdev = info.kp_eproc.e_tdev
            let tty: String
            if tdev == -1 || tdev == 0 {
                tty = "??"
            } else if let cName = devname(tdev, S_IFCHR) {
                let name = String(cString: cName)
                tty = name.isEmpty ? "??" : name
            } else {
                tty = "??"
            }

            let pathLen = pathBuffer.withUnsafeMutableBytes { buf in
                proc_pidpath(pid, buf.baseAddress, UInt32(buf.count))
            }
            let comm: String
            if pathLen > 0 {
                comm = String(decoding: pathBuffer[0..<Int(pathLen)], as: UTF8.self)
            } else {
                comm = withUnsafePointer(to: info.kp_proc.p_comm) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: info.kp_proc.p_comm)) { cPtr in
                        String(cString: cPtr)
                    }
                }
            }
            guard !comm.isEmpty else { continue }
            lines.append("\(pid) \(ppid) \(tty) \(comm)")
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func resolveIdentity(processID: Int32, listing: String, warpEnvironment: (Int32) -> String?) -> TerminalSessionIdentity? {
        struct Entry {
            let parent: Int32
            let tty: String
            let command: String
        }
        var entries: [Int32: Entry] = [:]
        for line in listing.split(separator: "\n") {
            let fields = line.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 4, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { continue }
            entries[pid] = Entry(parent: parent, tty: String(fields[2]), command: String(fields[3]))
        }
        var pid = processID
        var visited = Set<Int32>()
        var tty: String?
        var warpSessionID: String?
        while pid > 1, visited.insert(pid).inserted, let entry = entries[pid] {
            if tty == nil, entry.tty != "??", entry.tty != "?" { tty = entry.tty }
            if warpSessionID == nil { warpSessionID = warpEnvironment(pid) }
            let bundleID: String?
            if entry.command.contains("/Warp.app/") { bundleID = "dev.warp.Warp-Stable" }
            else if entry.command.contains("/iTerm.app/") || entry.command.contains("/iTerm2.app/") {
                bundleID = "com.googlecode.iterm2"
            } else if entry.command.contains("/Terminal.app/") { bundleID = "com.apple.Terminal" }
            else { bundleID = nil }
            if let bundleID, let tty {
                if bundleID == "dev.warp.Warp-Stable", warpSessionID == nil {
                    // If the starting process was an interactive login shell whose environment
                    // was modified after startup, check child processes on the same TTY.
                    let targetTTY = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
                    for (childPID, childEntry) in entries where childEntry.parent == processID && childEntry.tty == targetTTY {
                        if let childSession = warpEnvironment(childPID) {
                            warpSessionID = childSession
                            break
                        }
                    }
                }
                var rootPID = pid
                if bundleID == "dev.warp.Warp-Stable" {
                    var visitedPIDs = Set<Int32>([rootPID])
                    while let parent = entries[rootPID]?.parent,
                          parent > 1,
                          visitedPIDs.insert(parent).inserted,
                          let parentEntry = entries[parent],
                          parentEntry.command.contains("/Warp.app/") {
                        rootPID = parent
                    }
                }
                return TerminalSessionIdentity(tty: tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)",
                                               bundleID: bundleID, terminalPID: rootPID, warpSessionID: warpSessionID)
            }
            pid = entry.parent
        }
        return nil
    }

    static func focus(_ target: TerminalSessionIdentity, warpExecutable: String?) -> Bool {
        guard target.tty.range(of: #"^/dev/tty[A-Za-z0-9]+$"#, options: .regularExpression) != nil else { return false }
        switch target.bundleID {
        case "com.apple.Terminal", "com.googlecode.iterm2":
            let result = NavigationCommand.run("/usr/bin/osascript", ["-e", script(bundleID: target.bundleID), target.tty], timeout: 6)
            return result.succeeded && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "found"
        case "dev.warp.Warp-Stable":
            guard let nativeID = target.warpSessionID else { return false }
            // 1. Direct native Warp focus URL scheme (warp://session/<uuid>).
            // Warp sets WARP_FOCUS_URL (warp://session/<uuid>) and WARP_TERMINAL_SESSION_UUID
            // in session environments. Opening this URL brings Warp to the front and
            // selects the matching terminal tab/session directly without requiring
            // automation permissions or warpctrl CLI.
            let urlString = nativeID.hasPrefix("warp://") ? nativeID : "warp://session/\(nativeID)"
            if let url = URL(string: urlString),
               url.scheme == "warp",
               let host = url.host,
               host == "session" {
                let openResult = NavigationCommand.run("/usr/bin/open", ["-b", "dev.warp.Warp-Stable", url.absoluteString])
                if openResult.succeeded { return true }
            }

            // 2. Fallback to CLI-based control (--warpctrl) if available.
            guard let warpExecutable else { return false }
            let prefix = ["--warpctrl"]
            let scope = ["--pid", String(target.terminalPID), "--output-format", "json"]
            let windows = NavigationCommand.run(warpExecutable, prefix + ["window", "list"] + scope)
            guard windows.succeeded else { return false }
            let windowIDs = warpIDs(output: windows.output, collection: "windows")
            let deadline = Date().addingTimeInterval(8)
            var matches: [(window: String, tab: String, session: String)] = []
            for window in windowIDs {
                guard Date() < deadline else { return false }
                let tabs = NavigationCommand.run(warpExecutable, prefix + ["tab", "list", "--window", window] + scope, timeout: 2)
                guard tabs.succeeded else { return false }
                for tab in warpIDs(output: tabs.output, collection: "tabs") {
                    guard Date() < deadline else { return false }
                    let selectors = ["--window", window, "--tab", tab]
                    let result = NavigationCommand.run(warpExecutable, prefix + ["session", "list"] + selectors + scope, timeout: 2)
                    guard result.succeeded else { return false }
                    if let data = result.output.data(using: .utf8),
                       let id = warpPublicSessionID(data: data, nativeID: nativeID) {
                        matches.append((window, tab, id))
                    }
                }
            }
            guard matches.count == 1, let match = matches.first else { return false }
            let focused = NavigationCommand.run(warpExecutable, prefix + ["session", "activate", "--window", match.window,
                                                                         "--tab", match.tab, "--session", match.session] + scope)
            return focused.succeeded
        default:
            return false
        }
    }

    static func warpIDs(output: String, collection: String) -> [String] {
        guard let data = output.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        func extract(_ value: Any) -> [String] {
            if let array = value as? [[String: Any]] { return array.compactMap { $0["id"] as? String } }
            guard let object = value as? [String: Any] else { return [] }
            if let items = object[collection] { return extract(items) }
            if let response = object["response"] { return extract(response) }
            if let data = object["data"] { return extract(data) }
            return []
        }
        return extract(json)
    }

    static func warpPublicSessionID(data: Data, nativeID: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var matches = Set<String>()
        func visit(_ value: Any) {
            if let object = value as? [String: Any] {
                let native = object["terminal_session_id"] as? String ?? object["session_id"] as? String
                let id = object["id"] as? String ?? object["session_id"] as? String
                if let id, id == nativeID || native == nativeID { matches.insert(id) }
                for child in object.values { visit(child) }
            } else if let array = value as? [Any] { array.forEach(visit) }
        }
        visit(json)
        return matches.count == 1 ? matches.first : nil
    }

    static func script(bundleID: String) -> String {
        if bundleID == "com.apple.Terminal" {
            return """
            on run argv
                set targetTTY to item 1 of argv
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is targetTTY then
                                set selected tab of w to t
                                set index of w to 1
                                activate
                                return "found"
                            end if
                        end repeat
                    end repeat
                end tell
                return "missing"
            end run
            """
        }
        return """
        on run argv
            set targetTTY to item 1 of argv
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is targetTTY then
                                tell s to select
                                tell t to select
                                tell w to select
                                activate
                                return "found"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "missing"
        end run
        """
    }

    static func parseWarpSessionID(from entries: [String]) -> String? {
        var uuid: String?
        var focusURL: String?
        var sessionID: String?
        for entry in entries {
            if entry.hasPrefix("WARP_TERMINAL_SESSION_UUID=") {
                uuid = String(entry.dropFirst("WARP_TERMINAL_SESSION_UUID=".count))
            } else if entry.hasPrefix("WARP_FOCUS_URL=") {
                focusURL = String(entry.dropFirst("WARP_FOCUS_URL=".count))
            } else if entry.hasPrefix("WARP_SESSION_ID=") {
                sessionID = String(entry.dropFirst("WARP_SESSION_ID=".count))
            }
        }
        if let uuid, !uuid.isEmpty { return uuid }
        if let focusURL, !focusURL.isEmpty {
            if focusURL.hasPrefix("warp://session/") {
                return String(focusURL.dropFirst("warp://session/".count))
            }
            return focusURL
        }
        if let sessionID, !sessionID.isEmpty { return sessionID }
        return nil
    }

    /// Read only the Warp-specific environment values; never emit full process args or
    /// environment (which may contain credentials) to subprocess output or logs.
    private static func warpEnvironment(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4, size <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let status = bytes.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        // Executable path, alignment padding, then argc NUL-terminated arguments.
        while cursor < size, bytes[cursor] != 0 { cursor += 1 }
        while cursor < size, bytes[cursor] == 0 { cursor += 1 }
        for _ in 0..<argc {
            while cursor < size, bytes[cursor] != 0 { cursor += 1 }
            cursor += 1
        }
        var warpEntries: [String] = []
        while cursor < size {
            let start = cursor
            while cursor < size, bytes[cursor] != 0 { cursor += 1 }
            let entry = String(decoding: bytes[start..<cursor], as: UTF8.self)
            if entry.hasPrefix("WARP_") { warpEntries.append(entry) }
            cursor += 1
        }
        return parseWarpSessionID(from: warpEntries)
    }
}
