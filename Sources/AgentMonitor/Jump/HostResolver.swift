import Darwin
import Foundation
import AppKit

public struct HostInfo: Equatable, Sendable {
    public let app: NSRunningApplication
    public let tty: String? // 形如 "/dev/ttys012"

    public init(app: NSRunningApplication, tty: String?) {
        self.app = app
        self.tty = tty
    }
}

public final class HostResolver: Sendable {
    public static let shared = HostResolver()

    public init() {}

    public func resolve(pid: Int32) -> HostInfo? {
        guard pid > 1 else { return nil }

        // 获取第一层 agent 进程自身的 tty
        var initialTTY: String? = nil
        if let procInfo = getKinfoProc(for: pid) {
            let tdev = procInfo.kp_eproc.e_tdev
            if let cstr = devname(tdev, S_IFCHR) {
                let name = String(cString: cstr)
                if !name.isEmpty && name != "??" {
                    initialTTY = "/dev/\(name)"
                }
            }
        }

        var currentPID = pid
        var iterations = 0

        while currentPID > 1 && iterations < 32 {
            iterations += 1
            if let runningApp = NSRunningApplication(processIdentifier: currentPID),
               runningApp.bundleIdentifier != nil {
                return HostInfo(app: runningApp, tty: initialTTY)
            }

            guard let procInfo = getKinfoProc(for: currentPID) else {
                break
            }
            let ppid = procInfo.kp_eproc.e_ppid
            if ppid == currentPID || ppid <= 1 {
                if let runningApp = NSRunningApplication(processIdentifier: ppid),
                   runningApp.bundleIdentifier != nil {
                    return HostInfo(app: runningApp, tty: initialTTY)
                }
                break
            }
            currentPID = ppid
        }

        return nil
    }

    private func getKinfoProc(for pid: Int32) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let ret = sysctl(&mib, 4, &proc, &size, nil, 0)
        guard ret == 0, size > 0 else { return nil }
        return proc
    }
}
