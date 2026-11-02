import SwiftUI

struct HotkeySettingsView: View {
    var body: some View {
        Form {
            Section("全局快捷键") {
                Text("快捷键设置（将在步骤 7 完成）")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
