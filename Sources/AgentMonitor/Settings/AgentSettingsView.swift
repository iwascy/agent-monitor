import SwiftUI
import AgentMonitorCore

struct AgentSettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    let sessionStore: SessionStore?

    init(sessionStore: SessionStore? = nil) {
        self.sessionStore = sessionStore
    }

    private func isAgentDetected(kind: AgentKind) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        switch kind {
        case .claudeCode:
            return fm.fileExists(atPath: home.appendingPathComponent(".claude").path)
        case .codex:
            return fm.fileExists(atPath: home.appendingPathComponent(".codex").path)
        case .dsh:
            return fm.fileExists(atPath: home.appendingPathComponent(".dsh").path)
        case .antigravity:
            return fm.fileExists(atPath: home.appendingPathComponent(".gemini/antigravity").path)
        }
    }

    private func displayPath(for kind: AgentKind) -> String {
        switch kind {
        case .claudeCode: return "~/.claude"
        case .codex: return "~/.codex"
        case .dsh: return "~/.dsh"
        case .antigravity: return "~/.gemini/antigravity"
        }
    }

    private func sessionCount(for kind: AgentKind) -> Int {
        guard let store = sessionStore else { return 0 }
        return store.currentSessions.filter { $0.kind == kind }.count
    }

    var body: some View {
        Form {
            Section(footer: Text("关闭后不再扫描该 agent 的数据，也不会收到它的通知。会话数只统计「显示最近」时间范围内的会话。")) {
                ForEach(AgentKind.allCases, id: \.self) { kind in
                    let isDetected = isAgentDetected(kind: kind)
                    HStack(spacing: 12) {
                        Image(nsImage: IconManager.shared.icon(for: kind))
                            .resizable()
                            .frame(width: 32, height: 32)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.displayName)
                                .font(.body)

                            HStack(spacing: 6) {
                                if isDetected {
                                    Text("● 已检测到")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                } else {
                                    Text("未找到数据目录")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Text("　\(displayPath(for: kind)) · \(sessionCount(for: kind)) 个会话")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { !settings.disabledAgents.contains(kind) },
                            set: { isEnabled in
                                if isEnabled {
                                    settings.disabledAgents.remove(kind)
                                } else {
                                    settings.disabledAgents.insert(kind)
                                }
                            }
                        ))
                        .labelsHidden()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
    }
}
