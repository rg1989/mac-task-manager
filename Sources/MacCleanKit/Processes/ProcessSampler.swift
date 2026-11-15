import Foundation
import Darwin

/// Lists every process on the Mac.
///
/// libproc only answers for the current user's processes (about two thirds on
/// a typical Mac). `/bin/ps` is setuid root and lists all of them in ~30 ms,
/// so `ps` supplies the list and libproc refines the rows it can read:
/// CPU from the delta between two samples, memory as the physical footprint
/// (the number Activity Monitor shows). Other users' processes keep the `ps`
/// values: a decaying CPU average and resident size.
public actor ProcessSampler {
    private var previous: [Int32: (cpuNanos: UInt64, at: TimeInterval)] = [:]
    private let currentUID: UInt32

    public init() {
        currentUID = getuid()
    }

    /// nil when `ps` could not be run; callers keep their last list.
    public func sample() -> [ProcessSnapshot]? {
        guard let (text, psPID) = Self.runPS() else { return nil }
        var list = PSOutputParser.parse(text, currentUID: currentUID).filter { $0.pid != psPID }
        let now = ProcessInfo.processInfo.systemUptime
        var next: [Int32: (cpuNanos: UInt64, at: TimeInterval)] = [:]
        for index in list.indices where list[index].isOwnedByCurrentUser {
            let pid = list[index].pid
            guard let usage = Self.usage(of: pid) else { continue }
            list[index].memoryBytes = usage.footprint
            if let before = previous[pid], now > before.at, usage.cpuNanos >= before.cpuNanos {
                let cpuSeconds = Double(usage.cpuNanos - before.cpuNanos) / 1_000_000_000
                list[index].cpuPercent = cpuSeconds / (now - before.at) * 100
            }
            next[pid] = (usage.cpuNanos, now)
        }
        previous = next
        return list
    }

    static func runPS() -> (output: String, pid: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,uid=,pcpu=,rss=,etime=,comm="]
        // C locale: decimal point in pcpu, no localized output.
        process.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return (String(decoding: data, as: UTF8.self), process.processIdentifier)
    }

    /// `ri_user_time` and `ri_system_time` are in Mach time units, which are
    /// not nanoseconds on Apple Silicon (125/3 ns per unit).
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()

    static func usage(of pid: Int32) -> (cpuNanos: UInt64, footprint: UInt64)? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard status == 0 else { return nil }
        let ticks = info.ri_user_time &+ info.ri_system_time
        return (ticks &* timebase.numer / timebase.denom, info.ri_phys_footprint)
    }
}
