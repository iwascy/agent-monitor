import Foundation
import AgentMonitorCore

var hours: Double = 6.0
if let hoursIdx = CommandLine.arguments.firstIndex(of: "--hours"), hoursIdx + 1 < CommandLine.arguments.count,
   let customHours = Double(CommandLine.arguments[hoursIdx + 1]) {
    hours = customHours
}

let maxAge = hours * 3600.0

print("========================================")
print(" Agent Monitor Probe - Live Agents Scan")
print("========================================")
print("Scanning real user directories at: \(Date())")
print("Max activity age window: \(hours) hours (\(Int(maxAge)) seconds)\n")

let claude = ClaudeCodeAdapter(maxAgeSeconds: maxAge)
let codex = CodexAdapter(maxAgeSeconds: maxAge)
let dsh = DshAdapter(maxAgeSeconds: maxAge)
let antigravity = AntigravityAdapter(maxAgeSeconds: maxAge)

let adapters: [AgentAdapter] = [claude, codex, dsh, antigravity]

for adapter in adapters {
    print("----------------------------------------")
    print("Agent Kind: \(adapter.kind.displayName) [\(adapter.kind.rawValue)]")
    print("Watch Paths: \(adapter.watchPaths.map { $0.path }.joined(separator: ", "))")
    do {
        let sessions = try adapter.scan()
        print("Scanned sessions count: \(sessions.count)")
        for (idx, s) in sessions.enumerated() {
            print("  [\(idx + 1)] ID: \(s.id)")
            print("      Title: \(s.title)")
            print("      CWD: \(s.cwd ?? "<none>")")
            print("      State (raw): \(s.state.rawValue)")
            if let label = s.waitingLabel {
                print("      Waiting Label: \(label)")
            }
            if let detail = s.detail {
                print("      Detail (isCommand=\(s.detailIsCommand)): \(detail)")
            }
            print("      Last Activity: \(s.lastActivity)")
            print("      Age: \(Int(Date().timeIntervalSince(s.lastActivity)))s ago")
        }
    } catch {
        print("  Error scanning \(adapter.kind): \(error)")
    }
    print("")
}

print("========================================")
print(" SessionStore Aggregation (Initial Scan)")
print("========================================")
let store = SessionStore(adapters: adapters, maxAgeSeconds: maxAge)
let transitions = store.refresh()
let storeSessions = store.currentSessions
print("Total sessions tracked: \(storeSessions.count)")
print("Initial transitions generated: \(transitions.count) (suppressed from notifications)")

for (idx, s) in storeSessions.enumerated() {
    print("  [\(idx + 1)] [\(s.kind.shortCode)] \(s.title)")
    print("      ID: \(s.id)")
    print("      State: \(s.state.rawValue)")
    print("      Detail: \(s.detail ?? "<none>")")
    print("      Last Activity: \(s.lastActivity)")
}
print("========================================")

