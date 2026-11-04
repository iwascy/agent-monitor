import SwiftUI
import Combine
import AgentMonitorCore

struct AgentSettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    let sessionStore: SessionStore?
    @LocalState private var currentSessions: [AgentSession] = []

    init(sessionStore: SessionStore? = nil) {
        self.sessionStore = sessionStore
    }

    private func isAgentDetected(kind: AgentKind) -> Bool {
        let fm = FileManager.default
        if let adapter = sessionStore?.adapters.first(where: { $0.kind == kind }) {
            return adapter.watchPaths.contains { fm.fileExists(atPath: $0.path) }
        }
        let home = fm.homeDirectoryForCurrentUser
        switch kind {
        case .paseo:
            return fm.fileExists(atPath: home.appendingPathComponent(".paseo").path)
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
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let adapter = sessionStore?.adapters.first(where: { $0.kind == kind }),
           let firstURL = adapter.watchPaths.first {
            let path = firstURL.path
            var isDir: ObjCBool = false
            let targetPath: String
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                targetPath = path
            } else {
                targetPath = firstURL.deletingLastPathComponent().path
            }
            if targetPath == home {
                return "~"
            } else if targetPath.hasPrefix(home + "/") {
                return "~" + targetPath.dropFirst(home.count)
            }
            return targetPath
        }

        switch kind {
        case .paseo: return "~/.paseo"
        case .claudeCode: return "~/.claude"
        case .codex: return "~/.codex"
        case .dsh: return "~/.dsh"
        case .antigravity: return "~/.gemini/antigravity"
        }
    }

    private func sessionCount(for kind: AgentKind) -> Int {
        currentSessions.filter { $0.kind == kind }.count
    }

    private var sessionUpdates: AnyPublisher<[AgentSession], Never> {
        sessionStore?.sessionsPublisher ?? Just([]).eraseToAnyPublisher()
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

                        VStack(alignment: .leading, spacing: 4) {
                            Text(kind.displayName)
                                .font(.body)

                            HStack(spacing: 8) {
                                Text(isDetected ? "● 已检测到" : "未找到数据目录")
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(isDetected ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                                    )
                                    .foregroundStyle(isDetected ? Color.green : Color.secondary)

                                if isDetected {
                                    Text("\(displayPath(for: kind)) · \(sessionCount(for: kind)) 个会话")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("\(displayPath(for: kind))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
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
        .onReceive(sessionUpdates.receive(on: DispatchQueue.main)) { sessions in
            currentSessions = sessions
        }
    }
}
