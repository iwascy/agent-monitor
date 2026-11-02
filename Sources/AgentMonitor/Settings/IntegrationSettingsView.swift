import SwiftUI
import AppKit
import AgentMonitorCore

struct IntegrationSettingsView: View {
    let sessionStore: SessionStore?
    private let installer = ClaudeHookInstaller()
    private let reader = ClaudeHookEventReader()

    @LocalState private var status: ClaudeHookInstallStatus = .notInstalled
    @LocalState private var errorMessage: String? = nil
    @LocalState private var lastEventDesc: String? = nil
    @LocalState private var isAccessibilityTrusted: Bool = AXIsProcessTrusted()
    @LocalState private var showingSheet: Bool = false
    @LocalState private var sheetDiffJSON: String = ""
    @LocalState private var createBackup: Bool = true
    @LocalState private var sheetError: String? = nil

    init(sessionStore: SessionStore? = nil) {
        self.sessionStore = sessionStore
    }

    private func refreshStatus() {
        isAccessibilityTrusted = AXIsProcessTrusted()
        status = installer.checkStatus()
        errorMessage = nil

        _ = reader.poll()
        if let last = reader.lastEvent {
            let seconds = max(0, Int(Date().timeIntervalSince(last.at)))
            lastEventDesc = "最近一次事件：\(seconds) 秒前（\(last.event)）"
        } else {
            lastEventDesc = nil
        }
    }

    private func openAccessibilityPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openAutomationPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func performUninstall() {
        do {
            try installer.uninstall()
            refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openInstallSheet() {
        sheetDiffJSON = installer.generateDiffJSONString()
        sheetError = nil
        showingSheet = true
    }

    private func executeInstallFromSheet() {
        do {
            if status == .needsRepair {
                try installer.repair(backup: createBackup)
            } else {
                try installer.install(backup: createBackup)
            }
            showingSheet = false
            refreshStatus()
        } catch {
            sheetError = error.localizedDescription
        }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(nsImage: IconManager.shared.icon(for: .claudeCode))
                            .resizable()
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 3) {
                            Text("状态实时同步")
                                .font(.body)

                            if status == .installed, let desc = lastEventDesc {
                                Text(desc)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if status == .needsRepair {
                                Text("配置文件条目不完整或脚本缺失，请点击修复。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("在 ~/.claude/settings.json 中加入 7 个异步 hook。状态变化会立即反映到面板，不必等文件扫描；授权请求会显示原始提示文字。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        switch status {
                        case .installed:
                            HStack(spacing: 4) {
                                Text("● 已安装")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.green)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Capsule())
                        case .notInstalled:
                            Text("未安装")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        case .needsRepair:
                            Text("● 需要修复")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }

                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack(spacing: 8) {
                        Spacer()
                        switch status {
                        case .notInstalled:
                            Button("查看改动…") {
                                openInstallSheet()
                            }
                            Button("安装") {
                                openInstallSheet()
                            }
                            .buttonStyle(.borderedProminent)
                        case .installed:
                            Button("卸载", role: .destructive) {
                                performUninstall()
                            }
                        case .needsRepair:
                            Button("查看改动…") {
                                openInstallSheet()
                            }
                            Button("修复") {
                                openInstallSheet()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Claude Code Hooks（实验性）")
            } footer: {
                Text("hook 以 async 方式运行，不会拖慢 Claude Code。卸载时只删除 Agent Monitor 写入的条目，你自己的 hook 保持不变。")
            }

            Section {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("辅助功能")
                            .font(.body)
                        Text("用于跳转时把正确的终端窗口带到最前（Warp、Ghostty、kitty 等）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isAccessibilityTrusted {
                        Text("● 已授权")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Capsule())
                    } else {
                        HStack(spacing: 8) {
                            Text("未授权")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())

                            Button("打开系统设置") {
                                openAccessibilityPreferences()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("自动化 · iTerm2 / 终端")
                            .font(.body)
                        Text("用于跳转到具体的标签页；第一次跳转时系统会询问")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Text("未请求")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())

                        Button("打开系统设置") {
                            openAutomationPreferences()
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("权限")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshStatus()
        }
        .sheet(isPresented: $showingSheet) {
            VStack(alignment: .leading, spacing: 14) {
                Text(status == .needsRepair ? "修复 Claude Code Hooks" : "安装 Claude Code Hooks")
                    .font(.headline)

                Text("Agent Monitor 会在 ~/.claude/settings.json 的 hooks 中追加以下条目。已有的配置不会改动，写入前会自动备份。新开的 Claude Code 会话会使用新配置；已经打开的会话可能需要重启才能生效。写入后文件的键顺序和缩进可能变化，内容不变。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)

                ScrollView {
                    Text(sheetDiffJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 180)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

                if let err = sheetError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Toggle("写入前备份为 settings.json.agentmonitor-backup", isOn: $createBackup)
                        .font(.subheadline)

                    Spacer()

                    Button("取消") {
                        showingSheet = false
                    }

                    Button(status == .needsRepair ? "修复" : "安装") {
                        executeInstallFromSheet()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(width: 520)
        }
    }
}
