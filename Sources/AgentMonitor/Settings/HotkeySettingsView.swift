import SwiftUI
import AgentMonitorCore

struct HotkeySettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var hotkeyCenter = HotkeyCenter.shared

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("打开 / 关闭面板")
                        Spacer()
                        KeyRecorderView(keyCombo: $settings.hotkeyTogglePanel)
                    }
                    if hotkeyCenter.togglePanelConflict {
                        Text("该快捷键已被占用")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("跳到等待最久的会话")
                            Text("不打开面板，直接跳转；没有等待的会话时跳到最近完成的会话")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        KeyRecorderView(keyCombo: $settings.hotkeyJumpWaiting)
                    }
                    if hotkeyCenter.jumpWaitingConflict {
                        Text("该快捷键已被占用")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            } header: {
                Text("全局快捷键")
            } footer: {
                Text("点击录制框后按下组合键，至少包含 ⌘、⌃、⌥ 之一；按 esc 取消，按 ⌫ 清除。与系统或其他 app 冲突时录制框下方显示红字「该快捷键已被占用」。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("面板内") {
                VStack(alignment: .leading, spacing: 10) {
                    keyMapRow(keys: "↑ ↓", description: "选择会话")
                    keyMapRow(keys: "↩", description: "跳转到选中的会话（已完成的同时标为已读）")
                    keyMapRow(keys: "⌫", description: "把选中的已完成会话标为已读")
                    keyMapRow(keys: "⌘⌫", description: "全部标为已读")
                    keyMapRow(keys: "1 2 3 4", description: "切换筛选：等你 / 已完成 / 运行中 / 空闲（再按一次取消）")
                    keyMapRow(keys: "esc", description: "有筛选时清除筛选，否则关闭面板")
                    keyMapRow(keys: "⌘,", description: "打开设置")
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }

    private func keyMapRow(keys: String, description: String) -> some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .frame(minWidth: 54, alignment: .center)

            Text(description)
                .font(.system(size: 12))
                .foregroundColor(.primary)

            Spacer()
        }
    }
}
