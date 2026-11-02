import SwiftUI
import AppKit
import AgentMonitorCore

public struct UsageChip: View {
    public let usage: SessionUsage

    @LocalState private var isHovered = false
    @LocalState private var isPopoverPresented = false
    @LocalState private var hoverTask: Task<Void, Never>? = nil

    public init(usage: SessionUsage) {
        self.usage = usage
    }

    private var thresholdColor: Color {
        switch UsageFormatter.usageLevel(usage: usage) {
        case .critical:
            return .red
        case .warning:
            return .orange
        case .normal:
            return .secondary
        }
    }

    public var body: some View {
        if let badge = UsageFormatter.badgeText(usage: usage) {
            HStack(spacing: 3) {
                if badge.isPercent, let tokens = usage.contextTokens, let window = usage.contextWindow, window > 0 {
                    let fraction = min(1.0, max(0.0, Double(tokens) / Double(window)))
                    ZStack {
                        Circle()
                            .stroke(thresholdColor.opacity(0.25), lineWidth: 1.6)
                        Circle()
                            .trim(from: 0.0, to: fraction)
                            .stroke(thresholdColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 10, height: 10)
                }

                Text(badge.text)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundColor(thresholdColor)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel(UsageFormatter.accessibilityLabel(usage: usage) ?? "")
            .onHover { hovering in
                isHovered = hovering
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        if !Task.isCancelled {
                            await MainActor.run {
                                isPopoverPresented = true
                            }
                        }
                    }
                } else {
                    isPopoverPresented = false
                }
            }
            .popover(isPresented: $isPopoverPresented.projectedValue, arrowEdge: .bottom) {
                UsagePopoverView(usage: usage, thresholdColor: thresholdColor)
            }
        }
    }
}

private struct UsagePopoverView: View {
    let usage: SessionUsage
    let thresholdColor: Color

    private var isAntigravity: Bool {
        usage.steps != nil && usage.contextTokens == nil
    }

    private var relativeTimeString: String {
        let elapsed = Date().timeIntervalSince(usage.updatedAt)
        if elapsed < 3 && elapsed >= -1 {
            return "刚刚"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateTimeStyle = .named
        let str = formatter.localizedString(for: usage.updatedAt, relativeTo: Date())
        if str.contains("0 秒") {
            return "刚刚"
        }
        return str
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text(isAntigravity ? "会话进度" : "上下文")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                let modelName = isAntigravity ? "Antigravity" : (usage.model ?? "")
                if !modelName.isEmpty {
                    Text(modelName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 6)

            // Content
            if let tokens = usage.contextTokens, let window = usage.contextWindow, window > 0 {
                // Codex style with context window and progress bar
                let fraction = min(1.0, max(0.0, Double(tokens) / Double(window)))
                let barColor: Color = thresholdColor == .secondary ? .blue : thresholdColor

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.primary.opacity(0.1))
                            .frame(height: 5)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(barColor)
                            .frame(width: max(3, geo.size.width * fraction), height: 5)
                    }
                }
                .frame(height: 5)
                .padding(.top, 2)
                .padding(.bottom, 6)

                rowView(title: "已用 / 窗口", value: "\(UsageFormatter.long(tokens: tokens)) / \(UsageFormatter.long(tokens: window))")

                Divider()
                    .padding(.vertical, 6)

                if let inp = usage.inputTokens {
                    rowView(title: "本会话输入", value: UsageFormatter.long(tokens: inp))
                }
                if let cached = usage.cachedInputTokens {
                    rowView(title: "其中缓存命中", value: UsageFormatter.long(tokens: cached))
                }
                if let out = usage.outputTokens {
                    rowView(title: "输出", value: UsageFormatter.long(tokens: out))
                }
                if let reasoning = usage.reasoningTokens {
                    rowView(title: "其中推理", value: UsageFormatter.long(tokens: reasoning))
                }
            } else if let tokens = usage.contextTokens {
                // Claude Code style
                rowView(title: "当前上下文", value: UsageFormatter.long(tokens: tokens))

                Divider()
                    .padding(.vertical, 6)

                if let inp = usage.inputTokens {
                    rowView(title: "本会话输入", value: UsageFormatter.long(tokens: inp))
                }
                if let write = usage.cacheWriteTokens {
                    rowView(title: "缓存写入", value: UsageFormatter.long(tokens: write))
                }
                if let read = usage.cachedInputTokens {
                    rowView(title: "缓存读取", value: UsageFormatter.long(tokens: read))
                }
                if let out = usage.outputTokens {
                    rowView(title: "输出", value: UsageFormatter.long(tokens: out))
                }
                if let reqCount = usage.requestCount {
                    rowView(title: "模型请求", value: "\(reqCount) 次")
                }
            } else if let steps = usage.steps {
                // Antigravity style
                rowView(title: "已执行步骤", value: "\(steps)")
            }

            // Footer
            let footerText = isAntigravity
                ? "Antigravity 本地数据不含 token 用量"
                : "来自本地会话记录，不含费用 · 更新于 \(relativeTimeString)"

            Text(footerText)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 236)
    }

    private func rowView(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundColor(.primary)
        }
        .frame(height: 19)
    }
}
