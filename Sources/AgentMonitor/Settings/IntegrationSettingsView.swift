import SwiftUI

struct IntegrationSettingsView: View {
    var body: some View {
        Form {
            Section("Claude Code Hooks（实验性）") {
                Text("集成设置（将在步骤 8 完成）")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
