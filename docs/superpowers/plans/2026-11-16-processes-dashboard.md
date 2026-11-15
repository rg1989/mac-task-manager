# Processes Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mac Sai opens on a Processes dashboard (task manager), and its menu bar dropdown shows the top five processes.

**Architecture:** A shared reader in `MacCleanKit` lists every process with `/bin/ps` and refines CPU and memory for the user's own processes with libproc. Pure policy functions filter, sort, group and decide what may be quit. The main app and the menu bar helper both consume them.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, SwiftPM, macOS 14+. No new dependencies.

Spec: `docs/superpowers/specs/2026-11-16-processes-dashboard-design.md`

## Global Constraints

- Build with `swift build --product MacClean` and `swift build --product MacCleanMenu`. Plain `swift build` and `swift test` fail here: XCTest needs full Xcode, and only the Command Line Tools are installed.
- No new entitlement, no admin prompt, no privileged helper.
- Cleanup and deletion code is not changed.
- New code goes in new files. Existing files get the listed edits only.
- UI strings use `L10n.tr("中文", "English", "Русский")`.
- Refresh interval: 2 seconds in the app, the existing 3 second loop in the menu helper.
- Nothing is pushed. Commits stay on the local branch `processes-dashboard`.
- Commit messages end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.

## File Structure

| File | Status | Responsibility |
|------|--------|----------------|
| `Sources/MacCleanKit/Processes/ProcessSnapshot.swift` | new | One process, pure data |
| `Sources/MacCleanKit/Processes/PSOutputParser.swift` | new | `ps` text to snapshots |
| `Sources/MacCleanKit/Processes/ProcessListPolicy.swift` | new | Filter, sort, group, quit rules |
| `Sources/MacCleanKit/Processes/ProcessSampler.swift` | new | Runs `ps`, refines with libproc |
| `Sources/MacCleanKit/Processes/SystemCardsSampler.swift` | new | CPU, memory, disk, network for the cards |
| `Sources/ProcessSelfCheck/main.swift` | new | Runnable checks for the pure logic, `--live` for the samplers |
| `Sources/MacClean/Modules/Processes/ProcessTerminator.swift` | new | Quit and Force Quit |
| `Sources/MacClean/Views/Processes/ProcessesViewModel.swift` | new | State, 2 s loop, formatting helpers |
| `Sources/MacClean/Views/Processes/ProcessStatCards.swift` | new | The four cards |
| `Sources/MacClean/Views/Processes/ProcessTableView.swift` | new | Header, rows, group rows |
| `Sources/MacClean/Views/Processes/ProcessesView.swift` | new | Page layout, quit confirmation |
| `scripts/fork-install.sh` | new | Build, sign with the local identity, install |
| `Package.swift` | edit | Add the `ProcessSelfCheck` target |
| `Sources/MacClean/Views/Sidebar/SidebarView.swift` | edit | New `.processes` item, first |
| `Sources/MacClean/App/ContentView.swift` | edit | Route to `ProcessesView` |
| `Sources/MacClean/App/AppState.swift` | edit | Default page |
| `Sources/MacClean/Views/Shared/GradientBackground.swift` | edit | Only if the compiler reports a non-exhaustive switch |
| `Sources/MacCleanKit/Localization.swift` | edit | English sidebar title |
| `Sources/MacCleanMenu/MenuStatsModel.swift` | edit | `topProcesses` |
| `Sources/MacCleanMenu/MacCleanMenuApp.swift` | edit | Top processes card |
| `Sources/MacCleanKit/Constants.swift`, `UpdateChecker.swift` | edit | Fork flag, update check off |

New files are given in full below. A block that follows a `<!-- file: PATH -->` marker is the complete content of that file.

---

### Task 1: Pure process logic and its self-check

**Files:**
- Create: `Sources/MacCleanKit/Processes/ProcessSnapshot.swift`, `PSOutputParser.swift`, `ProcessListPolicy.swift`
- Create: `Sources/ProcessSelfCheck/main.swift`
- Modify: `Package.swift`

**Interfaces:**
- Produces: `ProcessSnapshot`, `PSOutputParser.parse(_:currentUID:)`, `ProcessFilter`, `ProcessSortKey`, `QuitAbility`, `ProcessGroup`, and `ProcessListPolicy.{appBundlePath, matches, filtered, sorted, grouped, filteredGroups, sortedGroups, quitAbility, topConsumers}`.

- [ ] **Step 1: Add the self-check target to `Package.swift`**, after the `MacCleanKit` target:

```swift
        .executableTarget(
            name: "ProcessSelfCheck",
            dependencies: ["MacCleanKit"],
            path: "Sources/ProcessSelfCheck"
        ),
```

- [ ] **Step 2: Write the self-check first**

<!-- file: Sources/ProcessSelfCheck/main.swift -->
```swift
import Foundation
import MacCleanKit

// Runnable checks for the Processes logic. `swift test` needs XCTest (full
// Xcode); this target runs with the Command Line Tools alone.
//   swift run ProcessSelfCheck          pure-logic checks, exit 1 on failure
//   swift run ProcessSelfCheck --live   also sample this Mac and print a summary

var failures = 0
@MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("ok    \(message)")
    } else {
        failures += 1
        print("FAIL  \(message)")
    }
}

func proc(
    _ pid: Int32, ppid: Int32 = 1, uid: UInt32 = 501, _ path: String,
    cpu: Double = 0, mem: UInt64 = 0, elapsed: Int = 10, mine: Bool = true
) -> ProcessSnapshot {
    ProcessSnapshot(
        pid: pid, ppid: ppid, uid: uid,
        name: (path as NSString).lastPathComponent, executablePath: path,
        cpuPercent: cpu, memoryBytes: mem, elapsedSeconds: elapsed,
        isOwnedByCurrentUser: mine
    )
}

// MARK: Parser

check(PSOutputParser.elapsedSeconds("42:16") == 42 * 60 + 16, "etime mm:ss")
check(PSOutputParser.elapsedSeconds("02:42:16") == 2 * 3600 + 42 * 60 + 16, "etime hh:mm:ss")
check(PSOutputParser.elapsedSeconds("340-02:42:16") == 340 * 86400 + 2 * 3600 + 42 * 60 + 16, "etime dd-hh:mm:ss")
check(PSOutputParser.elapsedSeconds("abc") == nil, "etime garbage is nil")

let psText = """
    1     0     0   0.1  18352 12-03:04:05 /sbin/launchd
 4391     1   501  12.5 480000    01:02:03 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
 4410  4391   501   2.4 620000       59:01 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper
  777     1    -2   0.0   1024       00:05 /usr/sbin/nobodyd
this line is not a process
"""
let parsed = PSOutputParser.parse(psText, currentUID: 501)
check(parsed.count == 4, "parser keeps 4 valid lines and drops the garbage line")
check(parsed.first { $0.pid == 4391 }?.name == "Google Chrome", "name is the last path component, spaces kept")
check(parsed.first { $0.pid == 4391 }?.memoryBytes == 480_000 * 1024, "rss is converted from KB to bytes")
check(parsed.first { $0.pid == 4391 }?.cpuPercent == 12.5, "cpu percent parsed")
check(parsed.first { $0.pid == 4410 }?.ppid == 4391, "ppid parsed")
check(parsed.first { $0.pid == 1 }?.isOwnedByCurrentUser == false, "root process is not owned by the current user")
check(parsed.first { $0.pid == 4391 }?.isOwnedByCurrentUser == true, "uid 501 process is owned by the current user")
check(parsed.first { $0.pid == 777 }?.uid == 4_294_967_294, "negative uid is read as unsigned")

// MARK: Policy

let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
let chromeHelper = "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
check(ProcessListPolicy.appBundlePath(forExecutable: chromeHelper) == "/Applications/Google Chrome.app", "helper maps to the outermost app bundle")
check(ProcessListPolicy.appBundlePath(forExecutable: "/usr/bin/ssh") == nil, "plain binary has no bundle")

let sample: [ProcessSnapshot] = [
    proc(1, ppid: 0, uid: 0, "/sbin/launchd", mine: false),
    proc(402, uid: 88, "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", cpu: 1.8, mem: 350, mine: false),
    proc(4391, chrome, cpu: 1.9, mem: 480, elapsed: 500),
    proc(4410, ppid: 4391, chromeHelper, cpu: 2.4, mem: 620),
    proc(900, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", cpu: 0.2, mem: 90),
    proc(901, ppid: 900, "/bin/zsh", cpu: 0.0, mem: 5),
    proc(902, ppid: 901, "/opt/homebrew/bin/node", cpu: 30, mem: 200),
    proc(950, "/usr/libexec/someagent", cpu: 0.5, mem: 12),
]

check(ProcessListPolicy.matches(sample[2], search: ""), "empty search matches everything")
check(ProcessListPolicy.matches(sample[2], search: "chrome"), "search is case-insensitive on the name")
check(ProcessListPolicy.matches(sample[6], search: "finder, node"), "comma separated terms: any term matches")
check(ProcessListPolicy.matches(sample[6], search: "902"), "search matches an exact pid")
check(!ProcessListPolicy.matches(sample[6], search: "90"), "a partial pid does not match")

check(ProcessListPolicy.filtered(sample, filter: .mine, search: "").count == 6, "Mine drops other users' processes")
check(ProcessListPolicy.filtered(sample, filter: .apps, search: "").map(\.pid) == [4391, 4410, 900], "Apps keeps bundle processes only")
check(ProcessListPolicy.filtered(sample, filter: .all, search: "zsh").map(\.pid) == [901], "search narrows the list")

check(ProcessListPolicy.sorted(sample, by: .cpu, ascending: false).first?.pid == 902, "sort by cpu descending")
check(ProcessListPolicy.sorted(sample, by: .memory, ascending: true).first?.pid == 1, "sort by memory ascending")
check(ProcessListPolicy.sorted(sample, by: .name, ascending: true).first?.name == "Google Chrome", "sort by name ascending")
check(ProcessListPolicy.sorted(sample, by: .pid, ascending: true).map(\.pid) == [1, 402, 900, 901, 902, 950, 4391, 4410], "sort by pid ascending")

let groups = ProcessListPolicy.grouped(sample)
let chromeGroup = groups.first { $0.id == "/Applications/Google Chrome.app" }
check(chromeGroup?.members.map(\.pid) == [4391, 4410], "Chrome group holds the app and its helper")
check(chromeGroup?.name == "Google Chrome", "group name is the bundle name without .app")
check(chromeGroup?.mainPID == 4391, "main pid is the executable in Contents/MacOS")
check(chromeGroup?.memoryBytes == 1100, "group memory is the sum of its members")
check(abs((chromeGroup?.cpuPercent ?? 0) - 4.3) < 0.0001, "group cpu is the sum of its members")
let terminalGroup = groups.first { $0.name == "Terminal" }
check(terminalGroup?.members.map(\.pid) == [900, 901, 902], "shell and node join Terminal through their parents")
check(groups.first { $0.kind == .background }?.members.map(\.pid) == [950], "own process with no app ancestor is Background")
check(groups.first { $0.kind == .system }?.members.map(\.pid) == [1, 402], "other users' processes are System")

check(ProcessListPolicy.filteredGroups(sample, filter: .all, search: "node").map(\.name) == ["Terminal"], "group search matches through a member")
check(ProcessListPolicy.filteredGroups(sample, filter: .all, search: "chrome").count == 1, "group search matches the group name")
check(ProcessListPolicy.sortedGroups(groups, by: .cpu, ascending: false).first?.name == "Terminal", "groups sort by summed cpu")

check(ProcessListPolicy.quitAbility(for: sample[0], ownPID: 5) == .protected, "launchd is protected")
check(ProcessListPolicy.quitAbility(for: sample[1], ownPID: 5) == .protected, "WindowServer is protected")
check(ProcessListPolicy.quitAbility(for: sample[2], ownPID: 4391) == .protected, "our own pid is protected")
check(ProcessListPolicy.quitAbility(for: sample[2], ownPID: 5) == .allowed, "own app can be quit")
check(ProcessListPolicy.quitAbility(for: proc(60, uid: 0, "/usr/sbin/cfprefsd", mine: false), ownPID: 5) == .notOwned, "another user's process cannot be quit")
check(ProcessListPolicy.quitAbility(for: proc(61, "/Applications/Mac Sai.app/Contents/MacOS/MacClean"), ownPID: 5) == .protected, "Mac Sai itself is protected")
check(ProcessListPolicy.quitAbility(for: chromeGroup!, ownPID: 5) == .allowed, "app group quits through its main process")
check(ProcessListPolicy.quitAbility(for: groups.first { $0.kind == .system }!, ownPID: 5) == .protected, "the System bucket has no quit")

let top = ProcessListPolicy.topConsumers(sample, limit: 3)
check(top.map(\.name) == ["Terminal", "Google Chrome", "WindowServer"], "top consumers: app groups and single processes by cpu")

// MARK: Live

if CommandLine.arguments.contains("--live") {
    let sampler = ProcessSampler()
    let cards = SystemCardsSampler()
    _ = await sampler.sample()
    _ = await cards.sample()
    try? await Task.sleep(for: .seconds(2))
    let list = await sampler.sample() ?? []
    let snapshot = await cards.sample()
    let mine = list.filter(\.isOwnedByCurrentUser)
    print("live  \(list.count) processes, \(mine.count) owned by this user")
    print("live  cpu \(String(format: "%.1f", snapshot.cpuFraction * 100))% over \(snapshot.perCoreFractions.count) cores")
    print("live  memory \(snapshot.memory.used / 1_048_576) MB of \(snapshot.memory.total / 1_048_576) MB, disk free \(snapshot.disk.free / 1_073_741_824) GB")
    print("live  network in \(Int(snapshot.bytesInPerSecond)) B/s, out \(Int(snapshot.bytesOutPerSecond)) B/s")
    for p in ProcessListPolicy.sorted(mine, by: .cpu, ascending: false).prefix(5) {
        print("live  pid \(p.pid) \(String(format: "%6.1f", p.cpuPercent))% \(p.memoryBytes / 1_048_576) MB \(p.name)")
    }
    check(list.count > 100, "live: more than 100 processes listed")
    check(mine.contains { $0.memoryBytes > 0 }, "live: own processes report memory")
    check(snapshot.perCoreFractions.count == ProcessInfo.processInfo.processorCount, "live: one fraction per core")
    check(snapshot.memory.total == ProcessInfo.processInfo.physicalMemory, "live: memory total matches the machine")
}

print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 3: Run it to see it fail**

Run: `swift build --product ProcessSelfCheck`
Expected: compile errors, `cannot find 'ProcessSnapshot' in scope`.

- [ ] **Step 4: Write the three Kit files**

<!-- file: Sources/MacCleanKit/Processes/ProcessSnapshot.swift -->
```swift
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
```

<!-- file: Sources/MacCleanKit/Processes/PSOutputParser.swift -->
```swift
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
```

<!-- file: Sources/MacCleanKit/Processes/ProcessListPolicy.swift -->
```swift
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
```

- [ ] **Step 5: The self-check also needs the samplers to compile.** Do Task 2 Step 1 before running. (The `--live` block references them.)

- [ ] **Step 6: Commit after Task 2 Step 3 passes** (one commit for Tasks 1 and 2).

---

### Task 2: Samplers

**Files:**
- Create: `Sources/MacCleanKit/Processes/ProcessSampler.swift`, `SystemCardsSampler.swift`

**Interfaces:**
- Consumes: `ProcessSnapshot`, `PSOutputParser`, and the existing `CPUTicks`, `CPUUsage`, `VMStatistics`, `MemoryUsage`, `DiskUsage`, `NetworkRate`.
- Produces: `actor ProcessSampler { func sample() -> [ProcessSnapshot]? }` (nil when `ps` cannot run), `struct SystemCardsSnapshot`, `actor SystemCardsSampler { func sample() -> SystemCardsSnapshot }`.

- [ ] **Step 1: Write both files**

<!-- file: Sources/MacCleanKit/Processes/ProcessSampler.swift -->
```swift
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
```

<!-- file: Sources/MacCleanKit/Processes/SystemCardsSampler.swift -->
```swift
import Foundation
import Darwin

/// Whole-machine numbers for the cards above the process table.
public struct SystemCardsSnapshot: Equatable, Sendable {
    /// Average over all cores, 0…1.
    public let cpuFraction: Double
    public let perCoreFractions: [Double]
    public let memory: MemoryUsage
    public let disk: DiskUsage
    public let bytesInPerSecond: Double
    public let bytesOutPerSecond: Double

    public init(
        cpuFraction: Double,
        perCoreFractions: [Double],
        memory: MemoryUsage,
        disk: DiskUsage,
        bytesInPerSecond: Double,
        bytesOutPerSecond: Double
    ) {
        self.cpuFraction = cpuFraction
        self.perCoreFractions = perCoreFractions
        self.memory = memory
        self.disk = disk
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
    }
}

/// Reads the same kernel counters as the menu bar helper's collectors, plus
/// per-core CPU. CPU and network are rates, so the first sample reports 0.
public actor SystemCardsSampler {
    private var previousCores: [CPUTicks] = []
    private var previousNetwork: (bytesIn: UInt64, bytesOut: UInt64, at: TimeInterval)?

    public init() {}

    public func sample() -> SystemCardsSnapshot {
        let cores = readCores()
        let perCore: [Double]
        if cores.count == previousCores.count {
            perCore = zip(previousCores, cores).map { before, after in
                CPUUsage(previous: before, current: after)?.totalActiveFraction ?? 0
            }
        } else {
            perCore = Array(repeating: 0, count: cores.count)
        }
        previousCores = cores
        let cpu = perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count)

        let network = readNetworkBytes()
        let now = ProcessInfo.processInfo.systemUptime
        var rateIn = 0.0
        var rateOut = 0.0
        if let before = previousNetwork {
            rateIn = NetworkRate.bytesPerSecond(current: network.bytesIn, previous: before.bytesIn, elapsed: now - before.at)
            rateOut = NetworkRate.bytesPerSecond(current: network.bytesOut, previous: before.bytesOut, elapsed: now - before.at)
        }
        previousNetwork = (network.bytesIn, network.bytesOut, now)

        return SystemCardsSnapshot(
            cpuFraction: cpu,
            perCoreFractions: perCore,
            memory: readMemory(),
            disk: readDisk(),
            bytesInPerSecond: rateIn,
            bytesOutPerSecond: rateOut
        )
    }

    private func readCores() -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &cpuInfo, &infoCount)
        guard result == KERN_SUCCESS, let info = cpuInfo else { return [] }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<Int32>.size)
            )
        }
        let raw = Array(UnsafeBufferPointer(start: info, count: Int(infoCount)))
        let width = CPUTicks.statesPerCPU
        return (0..<Int(cpuCount)).map { core in
            let base = core * width
            guard base + width <= raw.count else { return CPUTicks(user: 0, system: 0, idle: 0, nice: 0) }
            return CPUTicks.summed(rawLoadInfo: Array(raw[base..<base + width]), cpuCount: 1)
        }
    }

    private func readMemory() -> MemoryUsage {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return MemoryUsage(total: total, used: 0) }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        let vm = VMStatistics(
            activeCount: UInt64(stats.active_count),
            inactiveCount: UInt64(stats.inactive_count),
            wireCount: UInt64(stats.wire_count),
            freeCount: UInt64(stats.free_count),
            compressorPageCount: UInt64(stats.compressor_page_count)
        )
        return MemoryUsage(physicalTotal: total, vmStats: vm, pageSize: UInt64(pageSize), swapUsed: swap.xsu_used)
    }

    /// statfs, not URLResourceValues: the latter can hang on Macs with many
    /// APFS snapshots (upstream issue #78).
    private func readDisk() -> DiskUsage {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else {
            return DiskUsage.fromStatfs(blocks: 0, availableBlocks: 0, blockSize: 0)
        }
        return DiskUsage.fromStatfs(
            blocks: UInt64(fs.f_blocks),
            availableBlocks: UInt64(fs.f_bavail),
            blockSize: UInt64(fs.f_bsize)
        )
    }

    private func readNetworkBytes() -> (bytesIn: UInt64, bytesOut: UInt64) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (0, 0) }
        defer { freeifaddrs(addresses) }
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let address = cursor {
            defer { cursor = address.pointee.ifa_next }
            let name = String(cString: address.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("pdp_ip") else { continue }
            guard let socketAddress = address.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_LINK),
                  let data = address.pointee.ifa_data else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self)
            totalIn += UInt64(counters.pointee.ifi_ibytes)
            totalOut += UInt64(counters.pointee.ifi_obytes)
        }
        return (totalIn, totalOut)
    }
}
```

- [ ] **Step 2: Run the pure checks**

Run: `swift run ProcessSelfCheck`
Expected: every line starts with `ok`, last line `ALL CHECKS PASSED`, exit code 0.

- [ ] **Step 3: Run the live checks and compare CPU with `top`**

Run: `yes > /dev/null & YES=$!; sleep 1; swift run ProcessSelfCheck --live; kill $YES`
Expected: `ALL CHECKS PASSED`, and a `live  pid … yes` line near 100%. A value near 2.4% means the Mach timebase conversion is missing.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/MacCleanKit/Processes Sources/ProcessSelfCheck
git commit -m "Add shared process reader, list rules and a runnable self-check"
```

---

### Task 3: Processes page in the main app

**Files:**
- Create: `Sources/MacClean/Modules/Processes/ProcessTerminator.swift`
- Create: `Sources/MacClean/Views/Processes/ProcessesViewModel.swift`, `ProcessStatCards.swift`, `ProcessTableView.swift`, `ProcessesView.swift`
- Modify: `SidebarView.swift`, `ContentView.swift`, `AppState.swift`, `Localization.swift`

**Interfaces:**
- Consumes: everything from Tasks 1 and 2; existing `L10n.tr`, `FileSizeFormatter.format`, `ResourceHogsPolicy.canQuit(bundleIdentifier:)`, `AppState.selectedSidebarItem`.
- Produces: `ProcessesView`, `SidebarItem.processes` with deep link id `processes`.

- [ ] **Step 1: Write the five new files**

<!-- file: Sources/MacClean/Modules/Processes/ProcessTerminator.swift -->
```swift
import AppKit
import Darwin
import MacCleanKit

/// Sends Quit or Force Quit to one process, after re-checking that the pid
/// still belongs to the process the user picked.
enum ProcessTerminator {
    enum Outcome: Equatable {
        case sent
        case gone
        case protected
        case failed(String)
    }

    @MainActor
    static func terminate(_ row: ProcessSnapshot, force: Bool, sampler: ProcessSampler) async -> Outcome {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard ProcessListPolicy.quitAbility(for: row, ownPID: ownPID) == .allowed else { return .protected }

        // The row is from an earlier tick. A recycled pid must never take down
        // a different process: same executable, and at least as old as the row.
        guard let live = await sampler.sample()?.first(where: { $0.pid == row.pid }),
              live.executablePath == row.executablePath,
              live.elapsedSeconds >= row.elapsedSeconds else { return .gone }

        if let app = NSRunningApplication(processIdentifier: row.pid) {
            guard ResourceHogsPolicy.canQuit(bundleIdentifier: app.bundleIdentifier) else { return .protected }
            if force ? app.forceTerminate() : app.terminate() { return .sent }
            // Fall through: some apps refuse the AppKit request.
        }
        if kill(row.pid, force ? SIGKILL : SIGTERM) == 0 { return .sent }
        let code = errno
        return code == ESRCH ? .gone : .failed(String(cString: strerror(code)))
    }
}
```

<!-- file: Sources/MacClean/Views/Processes/ProcessesViewModel.swift -->
```swift
import SwiftUI
import AppKit
import MacCleanKit

/// State for the Processes page: the live list, the card numbers and their
/// short history, and the user's search, filter, sort and view mode.
@MainActor
@Observable
final class ProcessesViewModel {
    enum Mode: String, CaseIterable {
        case list, byApp
    }

    /// 60 samples at 2 seconds: the card graphs cover two minutes.
    static let historyLength = 60
    static let interval: Duration = .seconds(2)

    private(set) var processes: [ProcessSnapshot] = []
    private(set) var cards: SystemCardsSnapshot?
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var networkHistory: [Double] = []
    private(set) var readFailed = false
    private(set) var hasLoaded = false

    var searchText = ""
    var filter: ProcessFilter = .all
    var mode: Mode = .list
    var sortKey: ProcessSortKey = .cpu
    var ascending = false
    var isPaused = false
    var expandedGroups: Set<String> = []

    let sampler = ProcessSampler()
    private let cardsSampler = SystemCardsSampler()
    private var loop: Task<Void, Never>?

    var visibleProcesses: [ProcessSnapshot] {
        ProcessListPolicy.sorted(
            ProcessListPolicy.filtered(processes, filter: filter, search: searchText),
            by: sortKey,
            ascending: ascending
        )
    }

    var visibleGroups: [ProcessGroup] {
        ProcessListPolicy.sortedGroups(
            ProcessListPolicy.filteredGroups(processes, filter: filter, search: searchText),
            by: sortKey,
            ascending: ascending
        )
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func refreshNow() async {
        await sampleOnce()
    }

    func toggleSort(_ key: ProcessSortKey) {
        if sortKey == key {
            ascending.toggle()
        } else {
            sortKey = key
            // Text-like columns start A to Z; numbers start with the largest.
            ascending = key == .name || key == .pid || key == .user
        }
    }

    func toggleGroup(_ id: String) {
        if expandedGroups.contains(id) {
            expandedGroups.remove(id)
        } else {
            expandedGroups.insert(id)
        }
    }

    private func tick() async {
        guard !isPaused else { return }
        await sampleOnce()
    }

    private func sampleOnce() async {
        let snapshot = await cardsSampler.sample()
        cards = snapshot
        cpuHistory = Self.pushed(snapshot.cpuFraction, onto: cpuHistory)
        memoryHistory = Self.pushed(snapshot.memory.pressure, onto: memoryHistory)
        networkHistory = Self.pushed(snapshot.bytesInPerSecond + snapshot.bytesOutPerSecond, onto: networkHistory)
        if let list = await sampler.sample() {
            processes = list
            readFailed = false
        } else {
            readFailed = true
        }
        hasLoaded = true
    }

    private static func pushed(_ value: Double, onto history: [Double]) -> [Double] {
        Array((history + [value]).suffix(historyLength))
    }
}

/// Number and name formatting shared by the Processes views.
@MainActor
enum ProcessFormat {
    private static var userNames: [UInt32: String] = [:]

    static func userName(_ uid: UInt32) -> String {
        if let cached = userNames[uid] { return cached }
        let name: String
        if let entry = getpwuid(uid), let raw = entry.pointee.pw_name {
            name = String(cString: raw)
        } else {
            name = String(uid)
        }
        userNames[uid] = name
        return name
    }

    static func cpu(_ percent: Double) -> String {
        String(format: "%.1f%%", percent)
    }

    static func runtime(_ seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3600
        let minutes = seconds % 3600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m \(seconds % 60)s"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 { return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000) }
        if bytesPerSecond >= 1_000 { return String(format: "%.0f KB/s", bytesPerSecond / 1_000) }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}

/// App icons by bundle path. Looking an icon up is slow enough to matter for
/// 600 rows redrawn every two seconds.
@MainActor
final class ProcessIconCache {
    static let shared = ProcessIconCache()
    private var icons: [String: NSImage] = [:]

    func icon(forExecutable path: String) -> NSImage? {
        guard let bundle = ProcessListPolicy.appBundlePath(forExecutable: path) else { return nil }
        if let cached = icons[bundle] { return cached }
        let image = NSWorkspace.shared.icon(forFile: bundle)
        icons[bundle] = image
        return image
    }
}
```

<!-- file: Sources/MacClean/Views/Processes/ProcessStatCards.swift -->
```swift
import SwiftUI
import MacCleanKit

/// The row of live cards above the process table: CPU, Memory, Storage, Network.
struct ProcessStatCards: View {
    let cards: SystemCardsSnapshot?
    let cpuHistory: [Double]
    let memoryHistory: [Double]
    let networkHistory: [Double]

    private let cpuTint = Color(red: 0.45, green: 0.62, blue: 1.0)
    private let memoryTint = Color(red: 1.0, green: 0.62, blue: 0.38)
    private let storageTint = Color(red: 0.70, green: 0.66, blue: 1.0)
    private let networkTint = Color(red: 0.40, green: 0.85, blue: 0.75)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            cpuCard
            memoryCard
            storageCard
            networkCard
        }
    }

    private var cpuCard: some View {
        card(icon: "cpu", title: "CPU", tint: cpuTint) {
            bigValue(cards.map { String(format: "%.1f%%", $0.cpuFraction * 100) } ?? "--")
            caption(L10n.tr(
                "\(cards?.perCoreFractions.count ?? 0) 个核心的平均值",
                "Average of \(cards?.perCoreFractions.count ?? 0) cores",
                "Среднее по \(cards?.perCoreFractions.count ?? 0) ядрам"
            ))
            Spacer(minLength: 4)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array((cards?.perCoreFractions ?? []).enumerated()), id: \.offset) { _, fraction in
                    CoreBar(fraction: fraction, tint: cpuTint)
                }
            }
            .frame(height: 18)
            Sparkline(values: cpuHistory, tint: cpuTint).frame(height: 22)
        }
    }

    private var memoryCard: some View {
        card(icon: "memorychip", title: L10n.tr("内存", "Memory", "Память"), tint: memoryTint) {
            bigValue(cards.map { FileSizeFormatter.format($0.memory.used) } ?? "--")
            caption(cards.map {
                L10n.tr(
                    "共 \(FileSizeFormatter.format($0.memory.total))",
                    "used of \(FileSizeFormatter.format($0.memory.total))",
                    "из \(FileSizeFormatter.format($0.memory.total))"
                )
            } ?? " ")
            Spacer(minLength: 4)
            detailLine(
                L10n.tr("交换", "Swap", "Подкачка"),
                cards.map { FileSizeFormatter.format($0.memory.swapUsed) } ?? "--"
            )
            Sparkline(values: memoryHistory, tint: memoryTint).frame(height: 22)
        }
    }

    private var storageCard: some View {
        card(icon: "internaldrive", title: L10n.tr("存储", "Storage", "Диск"), tint: storageTint) {
            bigValue(cards.map { FileSizeFormatter.format($0.disk.free) } ?? "--")
            caption(cards.map {
                L10n.tr(
                    "可用，共 \(FileSizeFormatter.format($0.disk.total))",
                    "free of \(FileSizeFormatter.format($0.disk.total))",
                    "свободно из \(FileSizeFormatter.format($0.disk.total))"
                )
            } ?? " ")
            Spacer(minLength: 4)
            detailLine(
                L10n.tr("已用", "Used", "Занято"),
                cards.map { String(format: "%.0f%%", $0.disk.usedFraction * 100) } ?? "--"
            )
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(storageTint)
                        .frame(width: proxy.size.width * CGFloat(min(max(cards?.disk.usedFraction ?? 0, 0), 1)))
                }
            }
            .frame(height: 6)
            .padding(.vertical, 8)
        }
    }

    private var networkCard: some View {
        let peak = max(networkHistory.max() ?? 0, 1)
        return card(icon: "network", title: L10n.tr("网络", "Network", "Сеть"), tint: networkTint) {
            bigValue(cards.map { ProcessFormat.rate($0.bytesInPerSecond) } ?? "--")
            caption(L10n.tr("↓ 下载", "↓ Received", "↓ Получено"))
            Spacer(minLength: 4)
            detailLine(
                L10n.tr("↑ 上传", "↑ Sent", "↑ Отправлено"),
                cards.map { ProcessFormat.rate($0.bytesOutPerSecond) } ?? "--"
            )
            Sparkline(values: networkHistory.map { $0 / peak }, tint: networkTint).frame(height: 22)
        }
    }

    // MARK: Pieces

    private func card<Content: View>(
        icon: String,
        title: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 138, maxHeight: 138, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
    }

    private func bigValue(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .bold).monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.primary.opacity(0.6))
            .lineLimit(1)
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 10))
        .foregroundStyle(.primary.opacity(0.7))
    }
}

private struct CoreBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.10))
                RoundedRectangle(cornerRadius: 2).fill(tint)
                    .frame(height: max(2, proxy.size.height * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(maxWidth: 10)
    }
}

/// A filled line graph of values in 0…1. New values enter on the right, so a
/// short history starts part-way along.
struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let points = self.points(in: proxy.size)
            if let first = points.first, let last = points.last, points.count > 1 {
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: proxy.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: last.x, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(tint.opacity(0.18))
                    Path { path in
                        path.move(to: first)
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(tint, lineWidth: 1.5)
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let capacity = ProcessesViewModel.historyLength
        guard values.count > 1, capacity > 1 else { return [] }
        let step = size.width / CGFloat(capacity - 1)
        let offset = CGFloat(capacity - values.count) * step
        return values.enumerated().map { index, value in
            CGPoint(
                x: offset + CGFloat(index) * step,
                y: size.height * (1 - CGFloat(min(max(value, 0), 1)))
            )
        }
    }
}
```

<!-- file: Sources/MacClean/Views/Processes/ProcessTableView.swift -->
```swift
import SwiftUI
import AppKit
import MacCleanKit

/// Column widths shared by the header and the rows. Name takes the rest.
enum ProcessColumns {
    static let pid: CGFloat = 62
    static let user: CGFloat = 86
    static let cpu: CGFloat = 68
    static let memory: CGFloat = 84
    static let runtime: CGFloat = 84
    static let actions: CGFloat = 64
    static let rowHeight: CGFloat = 30
}

/// Sortable header plus the rows: one per process in List mode, one per app
/// (expandable) in By app mode.
struct ProcessTableView: View {
    @Bindable var model: ProcessesViewModel
    let onQuit: (ProcessSnapshot) -> Void

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.mode == .list {
                        ForEach(model.visibleProcesses) { process in
                            row(for: process, indent: 0)
                        }
                    } else {
                        ForEach(model.visibleGroups) { group in
                            ProcessGroupRowView(
                                group: group,
                                isExpanded: model.expandedGroups.contains(group.id),
                                ability: ProcessListPolicy.quitAbility(for: group, ownPID: ownPID),
                                onToggle: { model.toggleGroup(group.id) },
                                onQuit: {
                                    if let main = group.members.first(where: { $0.pid == group.mainPID }) {
                                        onQuit(main)
                                    }
                                }
                            )
                            if model.expandedGroups.contains(group.id) {
                                ForEach(ProcessListPolicy.sorted(group.members, by: model.sortKey, ascending: model.ascending)) { process in
                                    row(for: process, indent: 26)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(for process: ProcessSnapshot, indent: CGFloat) -> some View {
        ProcessRowView(
            process: process,
            indent: indent,
            ability: ProcessListPolicy.quitAbility(for: process, ownPID: ownPID),
            onQuit: { onQuit(process) }
        )
    }

    private var header: some View {
        HStack(spacing: 0) {
            sortButton(L10n.tr("进程名称", "Process Name", "Процесс"), .name, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortButton("PID", .pid).frame(width: ProcessColumns.pid, alignment: .trailing)
            sortButton(L10n.tr("用户", "User", "Пользователь"), .user).frame(width: ProcessColumns.user, alignment: .trailing)
            sortButton("CPU %", .cpu).frame(width: ProcessColumns.cpu, alignment: .trailing)
            sortButton(L10n.tr("内存", "Memory", "Память"), .memory).frame(width: ProcessColumns.memory, alignment: .trailing)
            sortButton(L10n.tr("运行时间", "Run Time", "Время работы"), .runtime).frame(width: ProcessColumns.runtime, alignment: .trailing)
            Text(L10n.tr("操作", "Actions", "Действия"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.6))
                .frame(width: ProcessColumns.actions, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    private func sortButton(_ title: String, _ key: ProcessSortKey, alignment: Alignment = .trailing) -> some View {
        Button {
            model.toggleSort(key)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if model.sortKey == key {
                    Image(systemName: model.ascending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(model.sortKey == key ? Color.accentColor : Color.primary.opacity(0.6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ProcessIcon: View {
    let executablePath: String

    var body: some View {
        if let image = ProcessIconCache.shared.icon(forExecutable: executablePath) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)
        }
    }
}

private struct NumberCell: View {
    let text: String
    let width: CGFloat
    var emphasized = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: emphasized ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(emphasized ? Color.primary : Color.primary.opacity(0.7))
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}

private struct QuitControl: View {
    let ability: QuitAbility
    let onQuit: () -> Void

    var body: some View {
        switch ability {
        case .allowed:
            Button(action: onQuit) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.red.opacity(0.9))
            }
            .buttonStyle(.plain)
            .help(L10n.tr("退出…", "Quit…", "Завершить…"))
        case .protected:
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help(L10n.tr("受保护，无法退出", "Protected. Cannot be quit.", "Защищён. Завершить нельзя."))
        case .notOwned:
            Image(systemName: "lock")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
                .help(L10n.tr("系统进程，需要管理员权限", "System process. Quitting it needs admin rights.", "Системный процесс. Нужны права администратора."))
        }
    }
}

private struct ProcessRowView: View {
    let process: ProcessSnapshot
    let indent: CGFloat
    let ability: QuitAbility
    let onQuit: () -> Void

    @State private var showInfo = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                ProcessIcon(executablePath: process.executablePath)
                Text(process.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, indent)
            .frame(maxWidth: .infinity, alignment: .leading)

            NumberCell(text: String(process.pid), width: ProcessColumns.pid)
            NumberCell(text: ProcessFormat.userName(process.uid), width: ProcessColumns.user)
            NumberCell(text: ProcessFormat.cpu(process.cpuPercent), width: ProcessColumns.cpu, emphasized: process.cpuPercent >= 50)
            NumberCell(text: FileSizeFormatter.format(process.memoryBytes), width: ProcessColumns.memory)
            NumberCell(text: ProcessFormat.runtime(process.elapsedSeconds), width: ProcessColumns.runtime)

            HStack(spacing: 10) {
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showInfo, arrowEdge: .trailing) { info }
                QuitControl(ability: ability, onQuit: onQuit)
            }
            .frame(width: ProcessColumns.actions, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: ProcessColumns.rowHeight)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(L10n.tr("在访达中显示", "Reveal in Finder", "Показать в Finder")) { reveal() }
            Button(L10n.tr("拷贝路径", "Copy Path", "Скопировать путь")) { copyPath() }
            if ability == .allowed {
                Divider()
                Button(L10n.tr("退出…", "Quit…", "Завершить…"), action: onQuit)
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(process.name).font(.system(size: 13, weight: .semibold))
            infoLine("PID", String(process.pid))
            infoLine(L10n.tr("父进程", "Parent PID", "Родитель"), String(process.ppid))
            infoLine(L10n.tr("用户", "User", "Пользователь"), ProcessFormat.userName(process.uid))
            infoLine(L10n.tr("运行时间", "Run Time", "Время работы"), ProcessFormat.runtime(process.elapsedSeconds))
            Text(process.executablePath)
                .font(.system(size: 10).monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.tr("在访达中显示", "Reveal in Finder", "Показать в Finder")) { reveal() }
                Button(L10n.tr("拷贝路径", "Copy Path", "Скопировать путь")) { copyPath() }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    private func infoLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11))
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: process.executablePath)])
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(process.executablePath, forType: .string)
    }
}

private struct ProcessGroupRowView: View {
    let group: ProcessGroup
    let isExpanded: Bool
    let ability: QuitAbility
    let onToggle: () -> Void
    let onQuit: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                icon
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text("\(group.members.count)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            NumberCell(text: "", width: ProcessColumns.pid)
            NumberCell(text: "", width: ProcessColumns.user)
            NumberCell(text: ProcessFormat.cpu(group.cpuPercent), width: ProcessColumns.cpu, emphasized: group.cpuPercent >= 50)
            NumberCell(text: FileSizeFormatter.format(group.memoryBytes), width: ProcessColumns.memory, emphasized: true)
            NumberCell(text: "", width: ProcessColumns.runtime)

            HStack(spacing: 10) {
                if group.kind == .app {
                    QuitControl(ability: ability, onQuit: onQuit)
                }
            }
            .frame(width: ProcessColumns.actions, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: ProcessColumns.rowHeight)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovering = $0 }
    }

    private var title: String {
        switch group.kind {
        case .app: group.name
        case .background: L10n.tr("后台进程", "Background", "Фоновые")
        case .system: L10n.tr("系统", "System", "Система")
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let bundle = group.bundlePath {
            ProcessIcon(executablePath: bundle + "/")
        } else {
            Image(systemName: group.kind == .system ? "gearshape.2" : "square.stack.3d.up")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)
        }
    }
}
```

<!-- file: Sources/MacClean/Views/Processes/ProcessesView.swift -->
```swift
import SwiftUI
import MacCleanKit

/// The Processes dashboard: the app's first page. Live cards over a
/// searchable, sortable process table with Quit and Force Quit.
struct ProcessesView: View {
    @Environment(AppState.self) private var appState
    @State private var model = ProcessesViewModel()
    @State private var pendingQuit: ProcessSnapshot?
    @State private var showQuitConfirm = false
    @State private var statusMessage: String?
    @State private var showStatus = false

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            ProcessStatCards(
                cards: model.cards,
                cpuHistory: model.cpuHistory,
                memoryHistory: model.memoryHistory,
                networkHistory: model.networkHistory
            )
            .padding(.horizontal, 24)
            toolbar
            content
            footer
        }
        // The page stays alive while another page is shown, so sampling
        // follows the sidebar selection rather than onAppear/onDisappear.
        .onChange(of: appState.selectedSidebarItem == .processes, initial: true) { _, isVisible in
            if isVisible {
                model.start()
            } else {
                model.stop()
            }
        }
        .alert(
            L10n.tr(
                "退出“\(pendingQuit?.name ?? "")”？",
                "Quit “\(pendingQuit?.name ?? "")”?",
                "Завершить «\(pendingQuit?.name ?? "")»?"
            ),
            isPresented: $showQuitConfirm,
            presenting: pendingQuit
        ) { process in
            Button(L10n.tr("取消", "Cancel", "Отмена"), role: .cancel) {}
            Button(L10n.tr("退出", "Quit", "Завершить")) { quit(process, force: false) }
            Button(L10n.tr("强制退出", "Force Quit", "Завершить принудительно"), role: .destructive) { quit(process, force: true) }
        } message: { process in
            Text(L10n.tr(
                "PID \(process.pid)。“退出”会让它自行关闭；“强制退出”会立即结束它，未保存的工作可能会丢失。",
                "PID \(process.pid). Quit asks it to close. Force Quit ends it at once, and unsaved work may be lost.",
                "PID \(process.pid). «Завершить» просит процесс закрыться. Принудительное завершение останавливает его сразу, несохранённая работа может быть потеряна."
            ))
        }
        .alert(statusMessage ?? "", isPresented: $showStatus) {
            Button("OK") {}
        }
    }

    private var titleBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("进程", "Processes", "Процессы"))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
                Text(L10n.tr(
                    "查看正在运行的程序，并退出占用资源的进程",
                    "See what is running and quit what is using too much",
                    "Смотрите, что запущено, и завершайте то, что потребляет слишком много"
                ))
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.6))
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isPaused ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
                Text(model.isPaused
                     ? L10n.tr("已暂停", "Paused", "Пауза")
                     : L10n.tr("实时 · 2 秒", "Live · 2s", "Онлайн · 2 с"))
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.7))
            }
            Button {
                model.isPaused.toggle()
            } label: {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
            }
            .help(model.isPaused
                  ? L10n.tr("继续", "Resume", "Продолжить")
                  : L10n.tr("暂停", "Pause", "Пауза"))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(L10n.tr("进程", "Processes", "Процессы"))
                .font(.system(size: 13, weight: .semibold))
            Text("\(model.processes.count)")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(
                    L10n.tr("搜索名称或 PID，用逗号分隔", "Search name or PID, comma separated", "Имя или PID, через запятую"),
                    text: $model.searchText
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: 320)
            .frame(height: 28)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Picker(L10n.tr("筛选", "Filter", "Фильтр"), selection: $model.filter) {
                Text(L10n.tr("全部", "All", "Все")).tag(ProcessFilter.all)
                Text(L10n.tr("我的", "Mine", "Мои")).tag(ProcessFilter.mine)
                Text(L10n.tr("应用", "Apps", "Приложения")).tag(ProcessFilter.apps)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)

            Spacer()

            Picker(L10n.tr("视图", "View", "Вид"), selection: $model.mode) {
                Text(L10n.tr("列表", "List", "Список")).tag(ProcessesViewModel.Mode.list)
                Text(L10n.tr("按应用", "By app", "По приложениям")).tag(ProcessesViewModel.Mode.byApp)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            VStack(spacing: 12) {
                Spacer()
                ProgressView().controlSize(.large).tint(.primary)
                Text(L10n.tr("正在读取进程…", "Reading processes…", "Чтение процессов…"))
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.6))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ProcessTableView(model: model) { process in
                pendingQuit = process
                showQuitConfirm = true
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 24)
        }
    }

    private var footer: some View {
        HStack {
            Text(footerText)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.6))
            Spacer()
            if model.readFailed {
                Label(
                    L10n.tr("无法读取进程列表，显示的是上一次的结果", "Could not read the process list. Showing the last result.", "Не удалось прочитать список процессов. Показан прошлый результат."),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var footerText: String {
        let total = model.processes.count
        let shown = model.mode == .list
            ? model.visibleProcesses.count
            : model.visibleGroups.reduce(0) { $0 + $1.members.count }
        return L10n.tr(
            "显示 \(shown) / \(total) 个进程",
            "Showing \(shown) of \(total) processes",
            "Показано \(shown) из \(total) процессов"
        )
    }

    private func quit(_ process: ProcessSnapshot, force: Bool) {
        Task {
            let outcome = await ProcessTerminator.terminate(process, force: force, sampler: model.sampler)
            switch outcome {
            case .sent:
                try? await Task.sleep(for: .milliseconds(700))
                await model.refreshNow()
            case .gone:
                show(L10n.tr("该进程已不再运行。", "That process is no longer running.", "Этот процесс больше не запущен."))
                await model.refreshNow()
            case .protected:
                show(L10n.tr("无法退出受保护的进程。", "That process is protected and cannot be quit.", "Этот процесс защищён и его нельзя завершить."))
            case .failed(let reason):
                show(L10n.tr("无法退出：\(reason)", "Could not quit: \(reason)", "Не удалось завершить: \(reason)"))
            }
        }
    }

    private func show(_ message: String) {
        statusMessage = message
        showStatus = true
    }
}
```

- [ ] **Step 2: Edit `Sources/MacClean/Views/Sidebar/SidebarView.swift`**

Add the case as the first one in the enum, above `case smartScan`:

```swift
    // Main
    case processes = "进程"
    case smartScan = "智能扫描"
```

Add one line to each of the four switches (`deepLinkID`, `icon`, `theme`, `section`):

```swift
        case .processes: "processes"                 // deepLinkID
        case .processes: "list.bullet.rectangle"     // icon
        case .processes: .performance                // theme
        case .processes: .main                       // section
```

- [ ] **Step 3: Edit `Sources/MacClean/App/ContentView.swift`**, in `moduleView(for:)`, above `case .smartScan:`

```swift
        case .processes:
            ProcessesView()
```

- [ ] **Step 4: Edit `Sources/MacClean/App/AppState.swift`**

```swift
    var selectedSidebarItem: SidebarItem? = .processes
```

- [ ] **Step 5: Edit `Sources/MacCleanKit/Localization.swift`**, first entry of `englishFallbacks`

```swift
    private static let englishFallbacks: [String: String] = [
        "进程": "Processes",
        "智能扫描": "Smart Scan",
```

`grep -c '"进程":' Sources/MacCleanKit/Localization.swift` printed 0 before the edit, so the key is new. A duplicate key in a dictionary literal crashes at launch.

- [ ] **Step 6: Build**

Run: `swift build --product MacClean 2>&1 | grep -E "error|warning: var|Compiling|Build" | tail -20`
Expected: `Build of product 'MacClean' complete!`. Fix any `switch must be exhaustive` error by adding a `.processes` case that returns the same value as `.optimization`.

- [ ] **Step 7: Run it from the build folder and look at it**

Run: `./scripts/build-dmg.sh --app-only` then `open ".build/dmg/Mac Sai.app"` (after quitting the installed copy). Expected: the app opens on Processes, the cards fill within 4 seconds, the list scrolls, sorting and both view modes work.

- [ ] **Step 8: Commit**

```bash
git add Sources/MacClean Sources/MacCleanKit/Localization.swift
git commit -m "Add the Processes dashboard and open the app on it"
```

---

### Task 4: Top processes in the menu bar dropdown

**Files:**
- Modify: `Sources/MacCleanMenu/MenuStatsModel.swift`, `Sources/MacCleanMenu/MacCleanMenuApp.swift`

**Interfaces:**
- Consumes: `ProcessSampler.sample()`, `ProcessListPolicy.topConsumers(_:limit:)`, `ProcessGroup`, `TipAction.open(moduleID:)`.

- [ ] **Step 1: `MenuStatsModel.swift`** — add the property next to `tips`, the sampler next to `healthMonitor`, and the step inside `run()` right after the network step:

```swift
    private(set) var topProcesses: [ProcessGroup] = []
```

```swift
    private let processSampler = ProcessSampler()
```

```swift
            if let sampled = await timed("processes", budget: .seconds(2), { await self.processSampler.sample() }),
               let list = sampled {
                topProcesses = ProcessListPolicy.topConsumers(list, limit: 5)
            }
```

- [ ] **Step 2: `MacCleanMenuApp.swift`** — pass the list at the call site and declare it on `MenuContentView`:

```swift
                tips: model.tips,
                topProcesses: model.topProcesses,
                onDismissTip: { model.dismissTip(id: $0) }
```

```swift
    let tips: [TipsEngine.Tip]
    let topProcesses: [ProcessGroup]
    let onDismissTip: (String) -> Void
```

Show the card right after `networkCard(stats)` in `body`:

```swift
                    networkCard(stats)
                    if !topProcesses.isEmpty { topProcessesCard }
```

Add the card next to `networkCard`:

```swift
    // MARK: Top processes

    private var topProcessesCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionHeader(
                    icon: "list.bullet.rectangle",
                    title: L10n.tr("占用最高的进程", "Top processes", "Топ процессов"),
                    tint: MenuPalette.teal
                )
                Text("CPU · RAM")
                    .font(.system(size: 9))
                    .foregroundStyle(MenuPalette.textSecondary)
            }
            ForEach(topProcesses) { entry in
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 11))
                        .foregroundStyle(MenuPalette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(String(format: "%.1f%%", entry.cpuPercent))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(MenuPalette.textPrimary)
                        .frame(width: 50, alignment: .trailing)
                    Text(FileSizeFormatter.format(entry.memoryBytes))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(MenuPalette.textSecondary)
                        .frame(width: 66, alignment: .trailing)
                }
            }
            Button {
                TipAction.open(moduleID: "processes")
            } label: {
                Text(L10n.tr("打开进程", "Open Processes", "Открыть процессы"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MenuPalette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(11)
        .glassCard()
    }
```

- [ ] **Step 3: Build**

Run: `swift build --product MacCleanMenu 2>&1 | tail -5`
Expected: `Build of product 'MacCleanMenu' complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/MacCleanMenu
git commit -m "Show the top five processes in the menu bar dropdown"
```

---

### Task 5: Fork build and install

**Files:**
- Modify: `Sources/MacCleanKit/Constants.swift`, `Sources/MacCleanKit/UpdateChecker.swift`
- Create: `scripts/fork-install.sh`

- [ ] **Step 1: `Constants.swift`** — next to `latestReleaseAPI`:

```swift
    /// This build is a private fork. An update from upstream would replace it
    /// with the official app, so update checks are off.
    public static let isForkBuild = true
```

- [ ] **Step 2: `UpdateChecker.swift`** — first line of `check(currentVersion:session:isHomebrew:)`:

```swift
        if MCConstants.isForkBuild { return .upToDate }
```

Sparkle needs no change: it is only active when the bundle has an `SUFeedURL`, which `build-dmg.sh` writes only when `SPARKLE_FEED_URL` is set.

- [ ] **Step 3: Write the install script**

<!-- file: scripts/fork-install.sh -->
```bash
#!/bin/bash
# Build this fork and install it to /Applications, signed with a local
# code-signing identity so macOS keeps the Full Disk Access grant across
# rebuilds (an ad-hoc signature changes on every build).
#
# Usage: ./scripts/fork-install.sh

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Mac Sai"
APP_BUNDLE=".build/dmg/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')
if [ -z "${IDENTITY}" ]; then
    echo "No code-signing identity found; the build will be ad-hoc signed and"
    echo "macOS will ask for Full Disk Access again after every install."
    BUILD_ARCHS="--arch $(uname -m)" ./scripts/build-dmg.sh --app-only
else
    echo "Signing with a local identity from the keychain."
    BUILD_ARCHS="--arch $(uname -m)" LOCAL_SIGNING_IDENTITY="${IDENTITY}" ./scripts/build-dmg.sh --app-only
fi

codesign --verify --deep --strict "${APP_BUNDLE}"

osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
pkill -x MacCleanMenu 2>/dev/null || true
pkill -x MacClean 2>/dev/null || true
sleep 1

echo "Installing to ${DEST}..."
rm -rf "${DEST}"
ditto "${APP_BUNDLE}" "${DEST}"
open "${DEST}"
echo "Installed. To return to the official app: brew install --cask mac-sai"
```

- [ ] **Step 4: Run all checks, then install**

```bash
chmod +x scripts/fork-install.sh
swift run ProcessSelfCheck
brew uninstall --cask mac-sai
./scripts/fork-install.sh
```

Expected: `ALL CHECKS PASSED`, then `Installed.` and the app opens on Processes.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacCleanKit/Constants.swift Sources/MacCleanKit/UpdateChecker.swift scripts/fork-install.sh
git commit -m "Mark the fork build, turn off update checks, add an install script"
```

---

### Task 6: Verify the installed app

- [ ] **Step 1:** `codesign -dv "/Applications/Mac Sai.app" 2>&1 | grep -E "Authority|TeamIdentifier"` shows the local identity.
- [ ] **Step 2:** The app opens on Processes. Screenshot it.
- [ ] **Step 3:** The footer total is within 5 of `ps -ax | wc -l`.
- [ ] **Step 4:** `yes > /dev/null &` appears near 100% CPU within 4 seconds when searching `yes`. Quit it from the row; `pgrep -x yes` then prints nothing.
- [ ] **Step 5:** Finder, Dock and WindowServer rows show a lock, not a Quit button.
- [ ] **Step 6:** By app mode shows one row per app with summed memory; expanding shows the helpers.
- [ ] **Step 7:** The menu bar dropdown shows Top processes with five rows; Open Processes brings the main window to the Processes page.
- [ ] **Step 8:** Smart Scan and the cleanup pages still open.
