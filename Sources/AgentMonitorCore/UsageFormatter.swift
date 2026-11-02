import Foundation

public enum UsageFormatter {
    /// 标签数字缩写
    public static func short(tokens: Int) -> String {
        if tokens < 1000 {
            return "\(tokens)"
        } else if tokens < 100_000 {
            let val = Double(tokens) / 1000.0
            return formatOneDecimalOrInt(val) + "k"
        } else if tokens < 1_000_000 {
            let val = Double(tokens) / 1000.0
            let rounded = Int(round(val))
            return "\(rounded)k"
        } else {
            let val = Double(tokens) / 1_000_000.0
            return formatTwoDecimalsDropZero(val) + "M"
        }
    }

    /// 浮层数字格式化
    public static func long(tokens: Int) -> String {
        if tokens < 1000 {
            return "\(tokens)"
        } else if tokens < 100_000 {
            let val = Double(tokens) / 1000.0
            return formatOneDecimalOrInt(val) + "k"
        } else if tokens < 1_000_000 {
            let val = Double(tokens) / 1000.0
            return formatOneDecimalOrInt(val) + "k"
        } else {
            let val = Double(tokens) / 1_000_000.0
            return formatTwoDecimalsDropZero(val) + "M"
        }
    }

    /// 标签文字与是否为百分比
    public static func badgeText(usage: SessionUsage) -> (text: String, isPercent: Bool)? {
        if let tokens = usage.contextTokens, let window = usage.contextWindow, window > 0 {
            let pct = Int(round(Double(tokens) / Double(window) * 100.0))
            return ("\(pct)%", true)
        } else if let tokens = usage.contextTokens {
            return (short(tokens: tokens), false)
        } else if let steps = usage.steps {
            return ("\(steps) 步", false)
        } else {
            return nil
        }
    }

    /// 辅助功能描述文本
    public static func accessibilityLabel(usage: SessionUsage) -> String? {
        if let tokens = usage.contextTokens, let window = usage.contextWindow, window > 0 {
            let pct = Int(round(Double(tokens) / Double(window) * 100.0))
            return "上下文 \(pct)%"
        } else if let tokens = usage.contextTokens {
            return "上下文 \(short(tokens: tokens))"
        } else if let steps = usage.steps {
            return "\(steps) 步"
        } else {
            return nil
        }
    }

    private static func formatOneDecimalOrInt(_ val: Double) -> String {
        let rounded = (val * 10.0).rounded() / 10.0
        if rounded == floor(rounded) {
            return "\(Int(rounded))"
        } else {
            return String(format: "%.1f", rounded)
        }
    }

    private static func formatTwoDecimalsDropZero(_ val: Double) -> String {
        let rounded = (val * 100.0).rounded() / 100.0
        var s = String(format: "%.2f", rounded)
        while s.hasSuffix("0") {
            s.removeLast()
        }
        if s.hasSuffix(".") {
            s.removeLast()
        }
        return s
    }
}
