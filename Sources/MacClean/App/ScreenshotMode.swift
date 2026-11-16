import AppKit
import SwiftUI
import MacCleanKit

/// Renders the README screenshots off-screen with sample data.
///
///     TM_SCREENSHOT_DIR=assets/screenshots .build/release/MacClean
///
/// Nothing shows on a display, no real process or user name is in the
/// pictures, and the program exits when the files are written.
/// `scripts/readme-screenshots.sh` runs it.
@MainActor
enum ScreenshotMode {
    static let isOn = ProcessInfo.processInfo.environment["TM_SCREENSHOT_DIR"] != nil

    static func runAndExit() -> Never {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TM_SCREENSHOT_DIR"] ?? ".")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        shot(.processes, to: dir.appendingPathComponent("processes.png"))
        shot(.smartScan, to: dir.appendingPathComponent("smart-scan.png"))
        exit(0)
    }

    private static func shot(_ item: SidebarItem, to url: URL) {
        let state = AppState()
        state.selectedSidebarItem = item
        // The neutral look, and a plain HStack instead of the app's split view:
        // the system sidebar material does not draw into an off-screen bitmap.
        UserDefaults.standard.set(true, forKey: "removeBackgroundColors")
        let page = HStack(spacing: 0) {
            SidebarView(selection: .constant(item))
                .frame(width: 236)
                .background(Color(red: 0.10, green: 0.10, blue: 0.12))
            ZStack {
                GradientBackgroundView(theme: item.theme)
                if item == .processes { ProcessesView() } else { SmartScanView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(state)
        .environment(\.colorScheme, .dark)

        let size = NSSize(width: 1280, height: 820)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -60000, y: -60000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: page)
        window.contentView = host
        window.setContentSize(size)
        window.orderFront(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.close()
    }

    // MARK: Sample data

    static let userName = "alex"

    static var processes: [ProcessSnapshot] {
        // (name, program path, CPU %, memory MB, minutes running, owned by the user)
        let rows: [(String, String, Double, UInt64, Int, Bool)] = [
            ("Xcode", "/Applications/Xcode.app/Contents/MacOS/Xcode", 41.8, 3120, 312, true),
            ("Safari", "/Applications/Safari.app/Contents/MacOS/Safari", 18.4, 1460, 845, true),
            ("WindowServer", "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", 12.7, 310, 5210, false),
            ("Music", "/System/Applications/Music.app/Contents/MacOS/Music", 6.3, 420, 126, true),
            ("Mail", "/System/Applications/Mail.app/Contents/MacOS/Mail", 4.9, 688, 2210, true),
            ("Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", 3.2, 164, 402, true),
            ("Photos", "/System/Applications/Photos.app/Contents/MacOS/Photos", 2.6, 912, 58, true),
            ("mds_stores", "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support/mds_stores", 2.1, 205, 5208, false),
            ("Notes", "/System/Applications/Notes.app/Contents/MacOS/Notes", 1.4, 233, 1530, true),
            ("Finder", "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", 1.1, 286, 5209, true),
            ("Preview", "/System/Applications/Preview.app/Contents/MacOS/Preview", 0.8, 141, 37, true),
            ("Calendar", "/System/Applications/Calendar.app/Contents/MacOS/Calendar", 0.6, 178, 2980, true),
            ("launchd", "/sbin/launchd", 0.4, 22, 5212, false),
            ("Maps", "/System/Applications/Maps.app/Contents/MacOS/Maps", 0.3, 356, 96, true),
            ("TextEdit", "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit", 0.1, 74, 610, true),
            ("Dock", "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock", 0.1, 98, 5209, true),
            ("Calculator", "/System/Applications/Calculator.app/Contents/MacOS/Calculator", 0.0, 61, 15, true),
            ("cfprefsd", "/usr/sbin/cfprefsd", 0.0, 9, 5211, false),
        ]
        return rows.enumerated().map { index, row in
            ProcessSnapshot(
                pid: Int32(412 + index * 137), ppid: 1, uid: row.5 ? 501 : 0,
                name: row.0, executablePath: row.1, cpuPercent: row.2,
                memoryBytes: row.3 * 1_048_576, elapsedSeconds: row.4 * 60,
                isOwnedByCurrentUser: row.5)
        }
    }

    static var cards: SystemCardsSnapshot {
        let page: UInt64 = 16_384
        let gb: UInt64 = 1_073_741_824
        return SystemCardsSnapshot(
            cpuFraction: 0.34,
            perCoreFractions: [0.62, 0.48, 0.41, 0.37, 0.22, 0.18, 0.12, 0.09],
            memory: MemoryUsage(
                physicalTotal: 16 * gb,
                vmStats: VMStatistics(
                    activeCount: 6 * gb / page, inactiveCount: 3 * gb / page, wireCount: 3 * gb / page,
                    freeCount: 2 * gb / page, compressorPageCount: 2 * gb / page),
                pageSize: page, swapUsed: gb / 2),
            disk: DiskUsage(total: 494 * gb, free: 187 * gb),
            bytesInPerSecond: 2_400_000, bytesOutPerSecond: 310_000)
    }

    /// A smooth made-up curve for the card graphs.
    static func history(base: Double, swing: Double) -> [Double] {
        (0..<ProcessesViewModel.historyLength).map { i in
            let x = Double(i)
            return max(0, base + swing * sin(x / 4.5) + swing * 0.5 * sin(x / 1.7 + 1))
        }
    }
}
