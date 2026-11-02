import SwiftUI
import AgentMonitorCore

struct MuteSettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("静音的项目目录") {
                Text("静音设置（将在步骤 5 完成）")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
