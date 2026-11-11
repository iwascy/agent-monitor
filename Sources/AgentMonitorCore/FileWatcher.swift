import Foundation
import CoreServices

public final class FileWatcher: @unchecked Sendable {
    private let paths: [String]
    private let debounceInterval: TimeInterval
    private let queue: DispatchQueue
    private let onChangeWithPaths: @Sendable (Set<String>) -> Void

    private var eventStream: FSEventStreamRef?
    private var debounceTimer: DispatchSourceTimer?
    private var pendingPaths: Set<String> = []
    private let lock = NSLock()
    private var isStarted = false

    public convenience init(
        paths: [URL],
        debounceInterval: TimeInterval = 0.3,
        queue: DispatchQueue = DispatchQueue(label: "com.agentmonitor.filewatcher", qos: .utility),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.init(paths: paths, debounceInterval: debounceInterval, queue: queue) { _ in
            onChange()
        }
    }

    /// 支持将防抖窗口内触发的所有变更路径集合传递给调用方，用于按路径定向扫描对应 Adapter。
    public init(
        paths: [URL],
        debounceInterval: TimeInterval = 0.3,
        queue: DispatchQueue = DispatchQueue(label: "com.agentmonitor.filewatcher", qos: .utility),
        onChangeWithPaths: @escaping @Sendable (Set<String>) -> Void
    ) {
        self.paths = paths.map { $0.path }
        self.debounceInterval = debounceInterval
        self.queue = queue
        self.onChangeWithPaths = onChangeWithPaths
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

        let callback: FSEventStreamCallback = { (_, clientCallBackInfo, _, eventPaths, _, _) in
            guard let clientCallBackInfo = clientCallBackInfo else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
            let changed = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String]) ?? []
            watcher.handleEvents(changedPaths: changed)
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

        pendingPaths.removeAll()
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

    private func handleEvents(changedPaths: [String]) {
        lock.lock()
        guard isStarted else {
            lock.unlock()
            return
        }
        for path in changedPaths {
            pendingPaths.insert(path)
        }

        // 复用已激活的防抖定时器，仅重设触发截止时间，避免高频事件下反复销毁与重建内核 Timer
        if let timer = debounceTimer {
            timer.schedule(deadline: .now() + debounceInterval)
        } else {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + debounceInterval)
            timer.setEventHandler { [weak self] in
                self?.fireDebouncedCallback()
            }
            debounceTimer = timer
            timer.resume()
        }
        lock.unlock()
    }

    private func fireDebouncedCallback() {
        lock.lock()
        guard isStarted else {
            lock.unlock()
            return
        }
        let batch = pendingPaths
        pendingPaths.removeAll()
        // 将已触发的单次定时器置为远期休眠以备下次直接重用 schedule
        debounceTimer?.schedule(deadline: .distantFuture)
        lock.unlock()

        onChangeWithPaths(batch)
    }
}
