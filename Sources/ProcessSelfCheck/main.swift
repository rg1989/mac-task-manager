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
