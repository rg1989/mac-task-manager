import AppKit
import MacCleanKit

/// What the menu bar item can do besides showing stats. Shared by the
/// right-click menu on the item and the dropdown's own context menu.
@MainActor
enum MenuBarActions {
    static func openApp() {
        TipAction.open()
    }

    /// Hides the monitor only. The main app keeps running, and Settings turns
    /// the monitor back on.
    static func removeFromMenuBar() {
        MenuBarKeepAlive.setUserQuit(true, defaults: SharedAppState.defaults)
        NSApplication.shared.terminate(nil)
    }

    /// Quits the main app and this monitor. Opening the app again starts both.
    static func quitEverything() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: MCConstants.bundleIdentifier)
        apps.forEach { $0.terminate() }
        Task {
            // The main app relaunches a missing monitor, so let it exit first
            // (up to two seconds).
            for _ in 0..<20 where apps.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            NSApplication.shared.terminate(nil)
        }
    }
}

/// A right-click menu on the menu bar item. SwiftUI's `MenuBarExtra` opens
/// its window on either mouse button and offers no hook for a second menu,
/// so this catches the right click on the status bar window itself.
@MainActor
final class StatusItemMenu: NSObject {
    static let shared = StatusItemMenu()
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { event in
            // Local monitors run on the main thread.
            let handled = MainActor.assumeIsolated { StatusItemMenu.shared.showMenu(for: event) }
            return handled ? nil : event
        }
    }

    private func showMenu(for event: NSEvent) -> Bool {
        guard let window = event.window,
              window.className.contains("StatusBar"),
              let view = window.contentView else { return false }
        let below = view.isFlipped ? view.bounds.maxY + 4 : -4
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: view)
        return true
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(
            L10n.tr("打开 \(MCConstants.appName)", "Open \(MCConstants.appName)", "Открыть \(MCConstants.appName)"),
            #selector(openApp)
        ))
        menu.addItem(item(
            L10n.tr("从菜单栏移除", "Remove from Menu Bar", "Убрать из строки меню"),
            #selector(removeFromMenuBar)
        ))
        menu.addItem(.separator())
        menu.addItem(item(
            L10n.tr("退出 \(MCConstants.appName)", "Quit \(MCConstants.appName)", "Завершить \(MCConstants.appName)"),
            #selector(quitEverything)
        ))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openApp() { MenuBarActions.openApp() }
    @objc private func removeFromMenuBar() { MenuBarActions.removeFromMenuBar() }
    @objc private func quitEverything() { MenuBarActions.quitEverything() }
}
