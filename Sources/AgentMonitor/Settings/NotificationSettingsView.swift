import SwiftUI
import AppKit
import AgentMonitorCore

struct NotificationSettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    private var systemSounds: [String] {
        let soundsURL = URL(fileURLWithPath: "/System/Library/Sounds")
        guard let files = try? FileManager.default.contentsOfDirectory(at: soundsURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension.lowercased() == "aiff" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    private func playSound(_ name: String) {
        if name == "none" || name == "default" {
            return
        }
        NSSound(named: name)?.play()
    }

    var body: some View {
        Form {
            Section("什么时候通知") {
                HStack {
                    Text("会话等你回复")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settings.waitingSound },
                        set: { newSound in
                            settings.waitingSound = newSound
                            playSound(newSound)
                        }
                    )) {
                        Text("默认").tag("default")
                        ForEach(systemSounds, id: \.self) { sound in
                            Text(sound).tag(sound)
                        }
                        Text("无").tag("none")
                    }
                    .labelsHidden()
                    .frame(width: 120)

                    Toggle("", isOn: $settings.notifyWaiting)
                        .labelsHidden()
                }

                HStack {
                    Text("任务完成")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settings.completedSound },
                        set: { newSound in
                            settings.completedSound = newSound
                            playSound(newSound)
                        }
                    )) {
                        Text("默认").tag("default")
                        ForEach(systemSounds, id: \.self) { sound in
                            Text(sound).tag(sound)
                        }
                        Text("无").tag("none")
                    }
                    .labelsHidden()
                    .frame(width: 120)

                    Toggle("", isOn: $settings.notifyCompleted)
                        .labelsHidden()
                }

                Picker(selection: $settings.minRunSecondsForCompletion) {
                    Text("0 秒").tag(0)
                    Text("10 秒").tag(10)
                    Text("30 秒").tag(30)
                    Text("1 分钟").tag(60)
                    Text("5 分钟").tag(300)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("只通知运行超过此时长的任务")
                        Text("短于这个时长的任务完成时不打扰你")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(header: Text("再次提醒"), footer: Text("之后每隔同样时长提醒一次，直到达到次数上限。会话离开「等你回复」后重新计时。")) {
                Toggle("等待太久时再次提醒", isOn: $settings.remindEnabled)

                Picker("等待超过", selection: $settings.remindAfterMinutes) {
                    Text("3 分钟").tag(3)
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                }

                Picker("最多提醒", selection: $settings.remindMaxCount) {
                    Text("1 次").tag(1)
                    Text("2 次").tag(2)
                    Text("3 次").tag(3)
                    Text("5 次").tag(5)
                }

                Toggle("超时后菜单栏角标变红", isOn: $settings.overdueBadgeRed)
            }

            Section(header: Text("免打扰"), footer: Text("菜单栏铃铛按钮可暂停全部通知 1 小时。")) {
                Toggle("面板打开时不弹出通知", isOn: $settings.silenceWhilePanelOpen)
            }
        }
        .formStyle(.grouped)
    }
}
