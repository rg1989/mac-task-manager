import Foundation
import Darwin

/// Parsers for the three tools `ProcessContextSampler` runs. Pure text in,
/// values out.
public enum ProcessContextParser {
    /// Output of `ps -xo pid=,tty=,args= -ww`.
    public static func parseCommandLines(
        _ output: String
    ) -> (commandLines: [Int32: String], terminals: [Int32: String]) {
        var commandLines: [Int32: String] = [:]
        var terminals: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]) else { continue }
            terminals[pid] = String(fields[1])
            commandLines[pid] = fields[2].trimmingCharacters(in: .whitespaces)
        }
        return (commandLines, terminals)
    }

    /// Output of `lsof -nP -iTCP -sTCP:LISTEN -Fpn`: a `p<pid>` line, then
    /// one `n<address>:<port>` line per listening socket of that process.
    public static func parseListeningPorts(_ output: String) -> [Int32: [Int]] {
        var ports: [Int32: Set<Int>] = [:]
        var current: Int32?
        for line in output.split(separator: "\n") {
            guard let kind = line.first else { continue }
            let value = line.dropFirst()
            if kind == "p" {
                current = Int32(value)
            } else if kind == "n", let pid = current,
                      let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) {
                ports[pid, default: []].insert(port)
            }
        }
        return ports.mapValues { $0.sorted() }
    }

    /// Output of `launchctl list`: `PID  Status  Label`, with `-` for jobs
    /// that are not running.
    public static func parseLaunchdPIDs(_ output: String) -> Set<Int32> {
        var pids: Set<Int32> = []
        for line in output.split(separator: "\n") {
            if let first = line.split(separator: "\t", omittingEmptySubsequences: true).first,
               let pid = Int32(first.trimmingCharacters(in: .whitespaces)) {
                pids.insert(pid)
            }
        }
        return pids
    }
}

/// Collects a `ProcessContext` for the current user's processes. Three small
/// read-only tools (about 30 ms each) plus one libproc call per process.
public actor ProcessContextSampler {
    public init() {}

    public func sample(for processes: [ProcessSnapshot]) -> ProcessContext {
        var context = ProcessContext()
        if let ps = ProcessSampler.runTool("/bin/ps", ["-xo", "pid=,tty=,args=", "-ww"]) {
            let parsed = ProcessContextParser.parseCommandLines(ps.output)
            context.commandLines = parsed.commandLines
            context.terminals = parsed.terminals
        }
        // lsof exits 1 when it finds nothing, which is not an error here.
        if let lsof = ProcessSampler.runTool("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"], requireSuccess: false) {
            context.listeningPorts = ProcessContextParser.parseListeningPorts(lsof.output)
        }
        if let launchctl = ProcessSampler.runTool("/bin/launchctl", ["list"]) {
            context.launchdManagedPIDs = ProcessContextParser.parseLaunchdPIDs(launchctl.output)
        }
        for process in processes where process.isOwnedByCurrentUser {
            if let directory = Self.workingDirectory(of: process.pid) {
                context.workingDirectories[process.pid] = directory
            }
        }
        return context
    }

    static func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }
}
