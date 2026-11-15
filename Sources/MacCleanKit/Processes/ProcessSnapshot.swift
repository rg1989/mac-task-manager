import Foundation

/// One process at one sampling tick. Pure data: collected by `ProcessSampler`,
/// then filtered, sorted and grouped by `ProcessListPolicy`.
public struct ProcessSnapshot: Equatable, Sendable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let ppid: Int32
    public let uid: UInt32
    public let name: String
    public let executablePath: String
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public let elapsedSeconds: Int
    public let isOwnedByCurrentUser: Bool

    public init(
        pid: Int32,
        ppid: Int32,
        uid: UInt32,
        name: String,
        executablePath: String,
        cpuPercent: Double,
        memoryBytes: UInt64,
        elapsedSeconds: Int,
        isOwnedByCurrentUser: Bool
    ) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.name = name
        self.executablePath = executablePath
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.elapsedSeconds = elapsedSeconds
        self.isOwnedByCurrentUser = isOwnedByCurrentUser
    }
}
