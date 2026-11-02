import Foundation

public enum FileUtils {
    /// Reads up to `maxBytes` from the tail of a file and splits into lines.
    /// Safely handles UTF-8 boundaries and drops any leading partial line caused by truncation.
    public static func readTailLines(fileURL: URL, maxBytes: Int) -> [String]? {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? fileHandle.close() }

        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let offset = max(0, fileSize - maxBytes)
        do {
            try fileHandle.seek(toOffset: UInt64(offset))
            let data = fileHandle.readDataToEndOfFile()
            if data.isEmpty {
                return []
            }
            var lines: [String] = []
            var start = data.startIndex
            for i in data.indices {
                if data[i] == 0x0A {
                    let lineData = data[start..<i]
                    var line = String(decoding: lineData, as: UTF8.self)
                    if line.hasSuffix("\r") {
                        line.removeLast()
                    }
                    lines.append(line)
                    start = data.index(after: i)
                }
            }
            let trailingData = data[start..<data.endIndex]
            var trailingLine = String(decoding: trailingData, as: UTF8.self)
            if trailingLine.hasSuffix("\r") {
                trailingLine.removeLast()
            }
            lines.append(trailingLine)

            // If we seeked into the middle of the file, the first line is likely partial.
            if offset > 0 && !lines.isEmpty {
                lines.removeFirst()
            }
            return lines
        } catch {
            return nil
        }
    }

    /// Reads the first line of a file, stopping at `maxBytes`. Returns nil if no newline was found within the limit.
    public static func readFirstLine(fileURL: URL, maxBytes: Int) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? fileHandle.close() }

        var buffer = Data()
        while buffer.count < maxBytes {
            guard let chunk = try? fileHandle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                break
            }
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                buffer.append(chunk[chunk.startIndex..<newline])
                return String(decoding: buffer, as: UTF8.self)
            }
            buffer.append(chunk)
        }
        return nil
    }
}
