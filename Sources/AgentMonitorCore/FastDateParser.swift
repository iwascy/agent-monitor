import Foundation

/// 高性能、线程安全的时间戳解析器。
/// 优先使用零堆分配的 UTF-8 字节算术解析常见 ISO-8601 与 SQLite 时间格式，
/// 遇到非标准变体时自动回退到加锁复用的静态 Formatter。
public enum FastDateParser {
    /// 封装带锁的静态 Formatter 供非常规格式兜底使用，符合 Swift 6 严格并发安全要求。
    private final class FallbackBox: @unchecked Sendable {
        private let lock = NSLock()
        private let isoWithFraction: ISO8601DateFormatter
        private let isoStandard: ISO8601DateFormatter
        private let sqlWithFraction: DateFormatter
        private let sqlWithOffset: DateFormatter
        private let sqlSimpleUTC: DateFormatter

        init() {
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.isoWithFraction = f1

            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            self.isoStandard = f2

            let df1 = DateFormatter()
            df1.locale = Locale(identifier: "en_US_POSIX")
            df1.timeZone = TimeZone(secondsFromGMT: 0)
            df1.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ"
            self.sqlWithFraction = df1

            let df2 = DateFormatter()
            df2.locale = Locale(identifier: "en_US_POSIX")
            df2.timeZone = TimeZone(secondsFromGMT: 0)
            df2.dateFormat = "yyyy-MM-dd HH:mm:ssZZZZZ"
            self.sqlWithOffset = df2

            let df3 = DateFormatter()
            df3.locale = Locale(identifier: "en_US_POSIX")
            df3.timeZone = TimeZone(secondsFromGMT: 0)
            df3.dateFormat = "yyyy-MM-dd HH:mm:ss"
            self.sqlSimpleUTC = df3
        }

        func parse(_ s: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return isoWithFraction.date(from: s)
                ?? isoStandard.date(from: s)
                ?? sqlWithFraction.date(from: s)
                ?? sqlWithOffset.date(from: s)
                ?? sqlSimpleUTC.date(from: s)
        }
    }

    private static let fallback = FallbackBox()

    private enum FastParseOutcome {
        case parsed(TimeInterval)
        case invalidCalendarDate
        case unrecognizedFormat
    }

    /// 直接从 SQLite 返回的 C 字符串指针解析时间，避免构造临时 Swift `String`。
    public static func parse(cString: UnsafePointer<UInt8>) -> Date? {
        let len = strlen(UnsafeRawPointer(cString).assumingMemoryBound(to: CChar.self))
        guard len > 0 else { return nil }
        let buf = UnsafeBufferPointer(start: cString, count: len)
        switch parseFastUTF8(buf) {
        case .parsed(let ts):
            return Date(timeIntervalSince1970: ts)
        case .invalidCalendarDate:
            return nil
        case .unrecognizedFormat:
            let str = String(decoding: buf, as: UTF8.self)
            return fallback.parse(str)
        }
    }

    /// 解析常见的时间字符串（支持 `T` 或空格分隔、任意位数小数秒、`Z` / `±HH:MM` / `±HHMM` / 无时区默认 UTC）。
    public static func parse(_ string: String?) -> Date? {
        guard var s = string, !s.isEmpty else { return nil }
        let outcome = s.withUTF8 { parseFastUTF8($0) }
        switch outcome {
        case .parsed(let ts):
            return Date(timeIntervalSince1970: ts)
        case .invalidCalendarDate:
            return nil
        case .unrecognizedFormat:
            return fallback.parse(s)
        }
    }

    @inline(__always)
    private static func maxDaysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2:
            let isLeap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
            return isLeap ? 29 : 28
        default: return 0
        }
    }

    /// 基于 Howard Hinnant 公历算法的无分配 UTF-8 时间解析，返回解析结果枚举。
    @inline(__always)
    private static func parseFastUTF8(_ bytes: UnsafeBufferPointer<UInt8>) -> FastParseOutcome {
        // 最短合法格式: "YYYY-MM-DD HH:MM:SS" (19 字节)
        var start = 0
        var end = bytes.count
        while start < end && (bytes[start] == 0x20 || bytes[start] == 0x09) { start += 1 }
        while end > start && (bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 || bytes[end - 1] == 0x0A || bytes[end - 1] == 0x0D) { end -= 1 }
        let count = end - start
        guard count >= 19 else { return .unrecognizedFormat }

        @inline(__always)
        func digit(_ idx: Int) -> Int? {
            let b = bytes[start + idx]
            guard b >= 0x30 && b <= 0x39 else { return nil }
            return Int(b - 0x30)
        }

        @inline(__always)
        func twoDigits(_ idx: Int) -> Int? {
            guard let d1 = digit(idx), let d2 = digit(idx + 1) else { return nil }
            return d1 * 10 + d2
        }

        @inline(__always)
        func fourDigits(_ idx: Int) -> Int? {
            guard let hi = twoDigits(idx), let lo = twoDigits(idx + 2) else { return nil }
            return hi * 100 + lo
        }

        // YYYY-MM-DD[T ]HH:MM:SS
        guard bytes[start + 4] == 0x2D, // '-'
              bytes[start + 7] == 0x2D, // '-'
              (bytes[start + 10] == 0x54 || bytes[start + 10] == 0x74 || bytes[start + 10] == 0x20), // 'T', 't', ' '
              bytes[start + 13] == 0x3A, // ':'
              bytes[start + 16] == 0x3A, // ':'
              let year = fourDigits(0),
              let month = twoDigits(5),
              let day = twoDigits(8),
              let hour = twoDigits(11),
              let minute = twoDigits(14),
              let second = twoDigits(17) else {
            return .unrecognizedFormat
        }

        guard (1...12).contains(month),
              day >= 1 && day <= maxDaysInMonth(year: year, month: month),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...60).contains(second) else {
            return .invalidCalendarDate
        }

        var pos = 19
        var fractionalSeconds: Double = 0.0

        // 可选小数秒: .ffffff...
        if pos < count && bytes[start + pos] == 0x2E { // '.'
            pos += 1
            let fracStart = pos
            var fracValue: UInt64 = 0
            var fracScale: Double = 1.0
            var digitsRead = 0
            while pos < count {
                let b = bytes[start + pos]
                guard b >= 0x30 && b <= 0x39 else { break }
                if digitsRead < 9 {
                    fracValue = fracValue * 10 + UInt64(b - 0x30)
                    fracScale *= 10.0
                    digitsRead += 1
                }
                pos += 1
            }
            // '.' 后面必须至少有一位数字
            guard pos > fracStart else { return .unrecognizedFormat }
            fractionalSeconds = Double(fracValue) / fracScale
        }

        // 解析可选时区偏移（无时区后缀时按 UTC 处理，兼容 SQLite DATETIME 默认格式）
        var tzOffsetSeconds = 0
        if pos < count {
            // 允许时间与时区之间出现单个空格（例如 "2026-01-09 03:09:13 +00:00"）
            if bytes[start + pos] == 0x20 {
                pos += 1
            }
            guard pos < count else { return .unrecognizedFormat }
            let signByte = bytes[start + pos]
            if signByte == 0x5A || signByte == 0x7A { // 'Z' or 'z'
                pos += 1
            } else if signByte == 0x2B || signByte == 0x2D { // '+' or '-'
                let sign = (signByte == 0x2B) ? 1 : -1
                pos += 1
                guard pos + 2 <= count, let tzHour = twoDigits(pos), (0...23).contains(tzHour) else {
                    return .unrecognizedFormat
                }
                pos += 2
                var tzMin = 0
                if pos < count {
                    if bytes[start + pos] == 0x3A { // ':'
                        pos += 1
                    }
                    guard pos + 2 <= count, let m = twoDigits(pos), (0...59).contains(m) else {
                        return .unrecognizedFormat
                    }
                    tzMin = m
                    pos += 2
                }
                tzOffsetSeconds = sign * (tzHour * 3600 + tzMin * 60)
            } else {
                return .unrecognizedFormat
            }
        }

        // 消费完时区后不能有未识别的尾部字符
        guard pos == count else { return .unrecognizedFormat }

        // Civil date -> Unix epoch days (Howard Hinnant algorithm)
        var y = year
        if month <= 2 { y -= 1 }
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468

        let wholeSeconds = days * 86400 + hour * 3600 + minute * 60 + second - tzOffsetSeconds
        return .parsed(Double(wholeSeconds) + fractionalSeconds)
    }
}
