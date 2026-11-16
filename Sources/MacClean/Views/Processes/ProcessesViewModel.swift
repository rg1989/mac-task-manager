import SwiftUI
import AppKit
import MacCleanKit

/// State for the Processes page: the live list, the card numbers and their
/// short history, and the user's search, filter, sort and view mode.
@MainActor
@Observable
final class ProcessesViewModel {
    enum Mode: String, CaseIterable {
        case list, byApp, leftovers
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
    /// Headless browsers and dev servers, true leftovers first.
    private(set) var leftovers: [LeftoverItem] = []
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
    private let contextSampler = ProcessContextSampler()
    private var ticksSinceContext = Int.max
    private var loop: Task<Void, Never>?

    var visibleProcesses: [ProcessSnapshot] {
        ProcessListPolicy.sorted(
            ProcessListPolicy.filtered(processes, filter: filter, search: searchText),
            by: sortKey,
            ascending: ascending
        )
    }

    /// Items nothing owns any more: the number on the Leftovers tab.
    var leftoverCount: Int {
        leftovers.filter(\.isLeftover).count
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
        if ScreenshotMode.isOn {   // sample data, no sampling loop
            processes = ScreenshotMode.processes
            let sample = ScreenshotMode.cards
            cards = sample
            cpuHistory = ScreenshotMode.history(base: 0.3, swing: 0.12)
            memoryHistory = ScreenshotMode.history(base: 0.66, swing: 0.04)
            networkHistory = ScreenshotMode.history(base: 1_800_000, swing: 900_000)
            hasLoaded = true
            return
        }
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
            await refreshLeftovers(from: list)
        } else {
            readFailed = true
        }
        hasLoaded = true
    }

    /// The extra queries run on every tick while the Leftovers tab is open,
    /// and every fifth tick (10 s) otherwise, to keep the tab's count fresh.
    private func refreshLeftovers(from list: [ProcessSnapshot]) async {
        ticksSinceContext = ticksSinceContext == Int.max ? Int.max : ticksSinceContext + 1
        guard mode == .leftovers || ticksSinceContext >= 5 else { return }
        ticksSinceContext = 0
        let context = await contextSampler.sample(for: list)
        leftovers = LeftoverDetector.detect(list, context: context)
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
        if ScreenshotMode.isOn { return uid == 0 ? "root" : ScreenshotMode.userName }
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

    // The dashboard cards and the details window share these tints.
    static let cpuTint = Color(red: 0.45, green: 0.62, blue: 1.0)
    static let memoryTint = Color(red: 1.0, green: 0.62, blue: 0.38)
    static let timeTint = Color(red: 0.40, green: 0.85, blue: 0.75)
    static let identityTint = Color(red: 0.70, green: 0.66, blue: 1.0)

    /// Plain until a process is busy: orange from half a core, red from
    /// about a full core.
    static func cpuColor(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 50 { return .orange }
        return .primary
    }

    /// Plain until a process is large: orange from 1.5 GB, red from 4 GB.
    static func memoryColor(_ bytes: UInt64) -> Color {
        if bytes >= 4 * 1_073_741_824 { return .red }
        if bytes >= 3 * 536_870_912 { return .orange }
        return .primary
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
