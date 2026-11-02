import SwiftUI
import AppKit
import AgentMonitorCore

struct MuteSettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @LocalState private var selectedIndex: Int? = nil

    var body: some View {
        Form {
            Section {
                VStack(spacing: 0) {
                    // 表头
                    HStack(spacing: 12) {
                        Text("目录")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("静音范围")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 140, alignment: .leading)
                        Text("面板中隐藏")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .center)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.08))

                    Divider()

                    if settings.muteRules.isEmpty {
                        Text("没有静音的项目")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        List {
                            ForEach(Array(settings.muteRules.enumerated()), id: \.element.id) { index, rule in
                                HStack(spacing: 12) {
                                    Text(formatPath(rule.path))
                                        .font(.system(size: 12, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Picker("", selection: Binding(
                                        get: { settings.muteRules[index].scope },
                                        set: { newScope in
                                            var copy = settings.muteRules
                                            copy[index].scope = newScope
                                            settings.muteRules = copy
                                        }
                                    )) {
                                        Text("所有通知").tag(MuteRule.Scope.all)
                                        Text("仅「已完成」通知").tag(MuteRule.Scope.completedOnly)
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .frame(width: 140, alignment: .leading)

                                    HStack {
                                        Spacer()
                                        Toggle("", isOn: Binding(
                                            get: { settings.muteRules[index].hideInPanel },
                                            set: { newHide in
                                                var copy = settings.muteRules
                                                copy[index].hideInPanel = newHide
                                                settings.muteRules = copy
                                            }
                                        ))
                                        .labelsHidden()
                                        .toggleStyle(.checkbox)
                                        Spacer()
                                    }
                                    .frame(width: 70)
                                }
                                .padding(.vertical, 3)
                                .padding(.horizontal, 4)
                                .contentShape(Rectangle())
                                .background(selectedIndex == index ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(Color.clear))
                                .cornerRadius(4)
                                .onTapGesture {
                                    selectedIndex = index
                                }
                            }
                        }
                        .listStyle(.plain)
                        .frame(minHeight: 120, maxHeight: 180)
                    }

                    Divider()

                    // 下方 + / - 按钮栏
                    HStack(spacing: 0) {
                        Button(action: addDirectory) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 28, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .frame(height: 14)

                        Button(action: removeSelected) {
                            Image(systemName: "minus")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 28, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedIndex == nil || (selectedIndex ?? -1) >= settings.muteRules.count)

                        Spacer()
                    }
                    .background(Color.secondary.opacity(0.04))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } header: {
                Text("静音的项目目录")
            } footer: {
                Text("会话的工作目录等于或位于某条规则的目录之下时生效；同时命中多条规则时取最长的那条。也可以在面板里右键会话 →「静音此项目」。\n「+」打开目录选择面板。规则为空时显示：「没有静音的项目」。")
            }
        }
        .formStyle(.grouped)
    }

    private func formatPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        } else if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            let clean = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
            var rules = settings.muteRules
            if !rules.contains(where: { $0.path == clean }) {
                rules.append(MuteRule(path: clean, scope: .all, hideInPanel: false))
                settings.muteRules = rules
                selectedIndex = rules.count - 1
            }
        }
    }

    private func removeSelected() {
        guard let idx = selectedIndex, idx < settings.muteRules.count else { return }
        var rules = settings.muteRules
        rules.remove(at: idx)
        settings.muteRules = rules
        if rules.isEmpty {
            selectedIndex = nil
        } else if idx >= rules.count {
            selectedIndex = rules.count - 1
        }
    }
}
