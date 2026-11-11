import Foundation
import Darwin

/// 基于 POSIX `stat` 的轻量文件元数据快照，避免构造 `FileManager` 属性字典或 `NSURL` 资源缓存开销。
public struct FileStamp: Equatable, Hashable, Sendable {
    public let mtimeSec: Int
    public let mtimeNsec: Int
    public let size: Int
    public let isDirectory: Bool

    public var modificationDate: Date {
        Date(timeIntervalSince1970: Double(mtimeSec) + Double(mtimeNsec) * 1e-9)
    }
}

public enum FileUtils {
    /// 使用系统调用 `stat` 快速读取路径的修改时间与字节大小；文件不存在或不可读时返回 `nil`。
    @inline(__always)
    public static func fastStat(path: String) -> FileStamp? {
        var st = stat()
        let rc = path.withCString { cPath in
            stat(cPath, &st)
        }
        guard rc == 0 else { return nil }
        return FileStamp(
            mtimeSec: st.st_mtimespec.tv_sec,
            mtimeNsec: st.st_mtimespec.tv_nsec,
            size: Int(st.st_size),
            isDirectory: (st.st_mode & S_IFMT) == S_IFDIR
        )
    }

    /// Reads up to `maxBytes` from the tail of a file and splits into lines.
    /// Safely handles UTF-8 boundaries and drops any leading partial line caused by truncation.
    public static func readTailLines(fileURL: URL, maxBytes: Int) -> [String]? {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? fileHandle.close() }

        var st = Darwin.stat()
        let fileSize: Int
        if fstat(fileHandle.fileDescriptor, &st) == 0 {
            fileSize = Int(st.st_size)
        } else {
            fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
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
