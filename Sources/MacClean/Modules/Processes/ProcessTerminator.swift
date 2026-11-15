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
