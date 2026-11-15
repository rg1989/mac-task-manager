import Foundation

public enum ProcessFilter: String, CaseIterable, Sendable {
    case all, mine, apps
}

public enum ProcessSortKey: String, CaseIterable, Sendable {
    case name, pid, user, cpu, memory, runtime
}

public enum QuitAbility: Equatable, Sendable {
    /// Owned by the current user and not on the protected list.
    case allowed
    /// Quitting it would break the session, or it is Mac Sai itself.
    case protected
    /// Owned by another user. Needs admin rights, which this app does not ask for.
    case notOwned
}

/// Processes that belong together: an app with its helpers, or one of the two
/// catch-all buckets.
public struct ProcessGroup: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case app, background, system
    }

    public let id: String
    public let kind: Kind
    public let name: String
    public let bundlePath: String?
    /// The process a Quit on the whole group is sent to.
    public let mainPID: Int32?
    public let members: [ProcessSnapshot]
    public let cpuPercent: Double
    public let memoryBytes: UInt64

    public init(
        id: String,
        kind: Kind,
        name: String,
        bundlePath: String?,
        mainPID: Int32?,
        members: [ProcessSnapshot]
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.bundlePath = bundlePath
        self.mainPID = mainPID
        self.members = members
        self.cpuPercent = members.reduce(0) { $0 + $1.cpuPercent }
        self.memoryBytes = members.reduce(0) { $0 + $1.memoryBytes }
    }
}

/// Pure rules for the Processes page: search, filter, sort, grouping and
/// which rows may be quit.
public enum ProcessListPolicy {
    /// Executable names that never get a Quit button. Quitting these ends or
    /// freezes the login session; `MacClean` and `MacCleanMenu` are this app.
    public static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow",
        "Finder", "Dock", "SystemUIServer", "MacClean", "MacCleanMenu",
    ]

    static let backgroundKey = "background"
    static let systemKey = "system"

    /// The outermost `.app` bundle that contains the executable, if any.
    public static func appBundlePath(forExecutable path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// Comma separated terms; a process matches when any term is part of its
    /// name (case-insensitive) or equals its pid.
    public static func matches(_ process: ProcessSnapshot, search: String) -> Bool {
        let terms = searchTerms(search)
        guard !terms.isEmpty else { return true }
        let name = process.name.lowercased()
        let pid = String(process.pid)
        return terms.contains { name.contains($0) || pid == $0 }
    }

    static func searchTerms(_ search: String) -> [String] {
        search.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    static func passes(_ process: ProcessSnapshot, filter: ProcessFilter) -> Bool {
        switch filter {
        case .all: true
        case .mine: process.isOwnedByCurrentUser
        case .apps: appBundlePath(forExecutable: process.executablePath) != nil
        }
    }

    public static func filtered(
        _ all: [ProcessSnapshot],
        filter: ProcessFilter,
        search: String
    ) -> [ProcessSnapshot] {
        all.filter { passes($0, filter: filter) && matches($0, search: search) }
    }

    public static func sorted(
        _ list: [ProcessSnapshot],
        by key: ProcessSortKey,
        ascending: Bool
    ) -> [ProcessSnapshot] {
        let result = list.sorted { a, b in
            switch key {
            case .name:
                let order = a.name.localizedCaseInsensitiveCompare(b.name)
                return order == .orderedSame ? a.pid < b.pid : order == .orderedAscending
            case .pid:
                return a.pid < b.pid
            case .user:
                return a.uid == b.uid ? a.pid < b.pid : a.uid < b.uid
            case .cpu:
                return a.cpuPercent == b.cpuPercent ? a.pid < b.pid : a.cpuPercent < b.cpuPercent
            case .memory:
                return a.memoryBytes == b.memoryBytes ? a.pid < b.pid : a.memoryBytes < b.memoryBytes
            case .runtime:
                return a.elapsedSeconds == b.elapsedSeconds ? a.pid < b.pid : a.elapsedSeconds < b.elapsedSeconds
            }
        }
        return ascending ? result : result.reversed()
    }

    /// Groups in order of first appearance. A process belongs to the outermost
    /// `.app` of its own executable, else to that of its nearest ancestor that
    /// has one, else to Background (current user) or System (other users).
    public static func grouped(_ list: [ProcessSnapshot]) -> [ProcessGroup] {
        let byPID = Dictionary(list.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var buckets: [String: [ProcessSnapshot]] = [:]
        var order: [String] = []
        for process in list {
            let key = groupKey(for: process, byPID: byPID)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(process)
        }
        return order.map { makeGroup(key: $0, members: buckets[$0] ?? []) }
    }

    static func groupKey(for process: ProcessSnapshot, byPID: [Int32: ProcessSnapshot]) -> String {
        var current: ProcessSnapshot? = process
        var hops = 0
        while let candidate = current, hops < 32 {
            if let bundle = appBundlePath(forExecutable: candidate.executablePath) { return bundle }
            guard candidate.ppid > 1, candidate.ppid != candidate.pid else { break }
            current = byPID[candidate.ppid]
            hops += 1
        }
        return process.isOwnedByCurrentUser ? backgroundKey : systemKey
    }

    static func makeGroup(key: String, members: [ProcessSnapshot]) -> ProcessGroup {
        switch key {
        case backgroundKey:
            return ProcessGroup(id: key, kind: .background, name: "Background", bundlePath: nil, mainPID: nil, members: members)
        case systemKey:
            return ProcessGroup(id: key, kind: .system, name: "System", bundlePath: nil, mainPID: nil, members: members)
        default:
            let name = ((key as NSString).lastPathComponent as NSString).deletingPathExtension
            let mainPrefix = key + "/Contents/MacOS/"
            let main = members
                .filter { $0.executablePath.hasPrefix(mainPrefix) }
                .min { $0.pid < $1.pid }
            return ProcessGroup(id: key, kind: .app, name: name, bundlePath: key, mainPID: main?.pid, members: members)
        }
    }

    /// Groups after the filter. Grouping runs before the search so a helper
    /// still finds its app; a group stays when its name or any member matches.
    public static func filteredGroups(
        _ all: [ProcessSnapshot],
        filter: ProcessFilter,
        search: String
    ) -> [ProcessGroup] {
        let groups = grouped(all.filter { passes($0, filter: filter) })
        let terms = searchTerms(search)
        guard !terms.isEmpty else { return groups }
        return groups.filter { group in
            let name = group.name.lowercased()
            return terms.contains { name.contains($0) }
                || group.members.contains { matches($0, search: search) }
        }
    }

    /// Groups have no pid, user or run time, so those keys sort by name.
    public static func sortedGroups(
        _ groups: [ProcessGroup],
        by key: ProcessSortKey,
        ascending: Bool
    ) -> [ProcessGroup] {
        let result = groups.sorted { a, b in
            switch key {
            case .cpu where a.cpuPercent != b.cpuPercent:
                return a.cpuPercent < b.cpuPercent
            case .memory where a.memoryBytes != b.memoryBytes:
                return a.memoryBytes < b.memoryBytes
            default:
                let order = a.name.localizedCaseInsensitiveCompare(b.name)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
        }
        return ascending ? result : result.reversed()
    }

    public static func quitAbility(for process: ProcessSnapshot, ownPID: Int32) -> QuitAbility {
        if process.pid <= 1 || process.pid == ownPID || protectedNames.contains(process.name) {
            return .protected
        }
        return process.isOwnedByCurrentUser ? .allowed : .notOwned
    }

    /// A group quits through its main process. The catch-all buckets and apps
    /// with no visible main process cannot be quit as a group.
    public static func quitAbility(for group: ProcessGroup, ownPID: Int32) -> QuitAbility {
        guard group.kind == .app,
              let mainPID = group.mainPID,
              let main = group.members.first(where: { $0.pid == mainPID }) else { return .protected }
        return quitAbility(for: main, ownPID: ownPID)
    }

    /// For the menu bar: app groups plus every other process on its own,
    /// highest CPU first.
    public static func topConsumers(_ list: [ProcessSnapshot], limit: Int) -> [ProcessGroup] {
        var entries: [ProcessGroup] = []
        for group in grouped(list) {
            if group.kind == .app {
                entries.append(group)
            } else {
                entries += group.members.map {
                    ProcessGroup(id: "pid-\($0.pid)", kind: group.kind, name: $0.name, bundlePath: nil, mainPID: $0.pid, members: [$0])
                }
            }
        }
        return Array(sortedGroups(entries, by: .cpu, ascending: false).prefix(max(limit, 0)))
    }
}
