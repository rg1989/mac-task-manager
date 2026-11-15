import Foundation

/// Parses the output of
/// `/bin/ps -axo pid=,ppid=,uid=,pcpu=,rss=,etime=,comm=` (run with LC_ALL=C).
/// `comm` is last because it is the full executable path and can hold spaces.
public enum PSOutputParser {
    public static func parse(_ output: String, currentUID: UInt32) -> [ProcessSnapshot] {
        output.split(separator: "\n").compactMap { parseLine($0, currentUID: currentUID) }
    }

    static func parseLine(_ line: Substring, currentUID: UInt32) -> ProcessSnapshot? {
        let fields = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
        guard fields.count == 7,
              let pid = Int32(fields[0]),
              let ppid = Int32(fields[1]),
              let rawUID = Int64(fields[2]),
              let cpu = Double(fields[3]),
              let rssKB = UInt64(fields[4]),
              let elapsed = elapsedSeconds(fields[5]) else { return nil }
        let path = fields[6].trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        // ps prints uids above Int32.max (nobody = -2) as negative numbers.
        let uid = UInt32(truncatingIfNeeded: rawUID)
        let name = path.hasPrefix("/") ? (path as NSString).lastPathComponent : path
        return ProcessSnapshot(
            pid: pid,
            ppid: ppid,
            uid: uid,
            name: name,
            executablePath: path,
            cpuPercent: cpu,
            memoryBytes: rssKB * 1024,
            elapsedSeconds: elapsed,
            isOwnedByCurrentUser: uid == currentUID
        )
    }

    /// `[[dd-]hh:]mm:ss` to seconds. nil when the text is not in that shape.
    public static func elapsedSeconds(_ text: Substring) -> Int? {
        var days = 0
        var clock = text
        if let dash = text.firstIndex(of: "-") {
            guard let parsedDays = Int(text[..<dash]) else { return nil }
            days = parsedDays
            clock = text[text.index(after: dash)...]
        }
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var seconds = 0
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            seconds = seconds * 60 + value
        }
        return days * 86_400 + seconds
    }
}
