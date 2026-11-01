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
            let content = String(decoding: data, as: UTF8.self)
            var lines = content.components(separatedBy: .newlines)
            // If we seeked into the middle of the file, the first line is likely partial.
            if offset > 0 && !lines.isEmpty {
                lines.removeFirst()
            }
            return lines
        } catch {
            return nil
        }
    }
}
