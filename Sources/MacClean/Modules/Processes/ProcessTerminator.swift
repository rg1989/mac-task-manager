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

    /// Quits an app through its main process, waits for it to exit, then
    /// opens the bundle again. Uses a plain Quit so the app can save its state.
    @MainActor
    static func restart(_ main: ProcessSnapshot, bundlePath: String, sampler: ProcessSampler) async -> Outcome {
        let outcome = await terminate(main, force: false, sampler: sampler)
        guard outcome == .sent else { return outcome }
        var hasExited = false
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            if kill(main.pid, 0) != 0 {
                hasExited = true
                break
            }
        }
        guard hasExited else {
            return .failed(L10n.tr(
                "应用没有退出，可能在等待你保存",
                "the app did not quit; it may be waiting for you to save",
                "приложение не закрылось; возможно, оно ждёт сохранения"
            ))
        }
        let error: String? = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: bundlePath),
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }
        return error.map { .failed($0) } ?? .sent
    }
}
