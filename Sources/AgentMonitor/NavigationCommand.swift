import Foundation

/// Bounded subprocess execution, used off the main actor. Arguments never pass
/// through a shell; output is captured privately and is never logged.
enum NavigationCommand {
    struct Result: Sendable {
        let succeeded: Bool
        let output: String
    }

    private final class Output: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk.prefix(max(0, 1_048_576 - data.count)))
        }
        func text() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 4) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return Result(succeeded: false, output: "") }
        // The parent must close its write end so the reader sees EOF after exit.
        try? pipe.fileHandleForWriting.close()
        let output = Output()
        let read = DispatchGroup()
        read.enter()
        DispatchQueue.global().async {
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                output.append(chunk)
            }
            read.leave()
        }
        let didFinish = finished.wait(timeout: .now() + timeout) == .success
        if !didFinish {
            process.terminate()
            if finished.wait(timeout: .now() + 0.3) != .success { kill(process.processIdentifier, SIGKILL) }
        }
        _ = read.wait(timeout: .now() + 0.5)
        return Result(succeeded: didFinish && process.terminationStatus == 0, output: output.text())
    }
}
