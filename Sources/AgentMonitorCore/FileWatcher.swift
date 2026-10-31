import Foundation
import CoreServices

public final class FileWatcher: @unchecked Sendable {
    private let paths: [String]
    private let debounceInterval: TimeInterval
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void

    private var eventStream: FSEventStreamRef?
    private var debounceTimer: DispatchSourceTimer?
    private let lock = NSLock()
    private var isStarted = false

    public init(
        paths: [URL],
        debounceInterval: TimeInterval = 0.3,
        queue: DispatchQueue = DispatchQueue(label: "com.agentmonitor.filewatcher", qos: .utility),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.paths = paths.map { $0.path }
        self.debounceInterval = debounceInterval
        self.queue = queue
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isStarted, !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        let callback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let clientCallBackInfo = clientCallBackInfo else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
            watcher.handleEvents()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else {
            return
        }

        self.eventStream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        if FSEventStreamStart(stream) {
            isStarted = true
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        if let timer = debounceTimer {
            timer.cancel()
            debounceTimer = nil
        }

        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
        isStarted = false
    }

    private func handleEvents() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }

            if let timer = self.debounceTimer {
                timer.cancel()
            }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.debounceInterval)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                self.debounceTimer = nil
                self.lock.unlock()

                self.onChange()
            }
            self.debounceTimer = timer
            timer.resume()
        }
    }
}
