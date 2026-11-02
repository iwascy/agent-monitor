import SwiftUI
import ServiceManagement
import AgentMonitorCore

struct GeneralSettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @LocalState private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)

    var body: some View {
        Form {
            Section {
                Toggle("开机时启动", isOn: Binding(
                    get: {
                        MonitorViewModel.shared?.isLaunchAtLogin ?? (SMAppService.mainApp.status == .enabled)
                    },
                    set: { enable in
                        if let vm = MonitorViewModel.shared {
                            vm.setLaunchAtLogin(enable)
                        } else {
                            do {
                                if enable {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                NSLog("Failed to update launch at login: %@", error.localizedDescription)
                            }
                        }
                        launchAtLogin = (SMAppService.mainApp.status == .enabled)
                    }
                ))

                Picker(selection: $settings.activityWindowHours) {
                    Text("1 小时").tag(1)
                    Text("3 小时").tag(3)
                    Text("6 小时").tag(6)
                    Text("12 小时").tag(12)
                    Text("24 小时").tag(24)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示最近")
                        Text("超过这个时长没有活动的会话不再出现在面板里")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("默认展开空闲会话", isOn: $settings.idleExpandedByDefault)
            }

            Section("面板与菜单栏") {
                Toggle(isOn: $settings.showUsage) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示 Token 用量")
                        Text("在每个会话的第二行末尾显示上下文占用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("菜单栏图标显示等待数量", isOn: $settings.showWaitingCountInMenuBar)
            }
        }
        .formStyle(.grouped)
    }
}
