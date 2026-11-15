import SwiftUI
import AppKit
import MacCleanKit

/// Details for one process, opened by clicking its row. The numbers stay live
/// while the sheet is open, and the actions live here in full size: Quit,
/// Force Quit and, for apps, Restart.
struct ProcessDetailSheet: View {
    let model: ProcessesViewModel
    /// The row as it was when the user clicked it.
    let selected: ProcessSnapshot

    @Environment(\.dismiss) private var dismiss
    @State private var confirmForceQuit = false
    @State private var isWorking = false
    @State private var message: String?

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// The same process in the newest sample; nil once it has ended.
    private var live: ProcessSnapshot? {
        model.processes.first { $0.pid == selected.pid && $0.executablePath == selected.executablePath }
    }

    private var current: ProcessSnapshot { live ?? selected }
    private var hasEnded: Bool { live == nil }

    private var ability: QuitAbility {
        ProcessListPolicy.quitAbility(for: current, ownPID: ownPID)
    }

    /// The app this process belongs to, with all of its processes.
    private var appGroup: ProcessGroup? {
        guard let bundle = ProcessListPolicy.appBundlePath(forExecutable: selected.executablePath) else { return nil }
        return ProcessListPolicy.grouped(model.processes).first { $0.bundlePath == bundle }
    }

    /// The process a Restart goes to: the app's main process, if it may be quit.
    private var restartTarget: (main: ProcessSnapshot, bundlePath: String, appName: String)? {
        guard let group = appGroup,
              let bundle = group.bundlePath,
              let main = group.members.first(where: { $0.pid == group.mainPID }),
              ProcessListPolicy.quitAbility(for: main, ownPID: ownPID) == .allowed else { return nil }
        return (main, bundle, group.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statsGrid
            if let group = appGroup, group.members.count > 1 {
                appSummary(group)
            }
            pathBlock
            if let message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            Divider()
            actions
        }
        .padding(22)
        .frame(width: 540)
        .confirmationDialog(
            L10n.tr(
                "强制退出“\(current.name)”？",
                "Force Quit “\(current.name)”?",
                "Принудительно завершить «\(current.name)»?"
            ),
            isPresented: $confirmForceQuit
        ) {
            Button(L10n.tr("强制退出", "Force Quit", "Завершить принудительно"), role: .destructive) {
                quit(force: true)
            }
            Button(L10n.tr("取消", "Cancel", "Отмена"), role: .cancel) {}
        } message: {
            Text(L10n.tr(
                "它会立即结束，未保存的工作可能会丢失。",
                "It ends at once, and unsaved work may be lost.",
                "Процесс остановится сразу, несохранённая работа может быть потеряна."
            ))
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(current.name)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(hasEnded ? Color.orange : Color.secondary)
            }
            Spacer()
        }
    }

    private var subtitle: String {
        if hasEnded {
            return L10n.tr("该进程已结束", "This process has ended", "Процесс завершён")
        }
        switch ability {
        case .allowed:
            if let group = appGroup, group.mainPID != current.pid {
                return L10n.tr("属于 \(group.name)", "Part of \(group.name)", "Часть \(group.name)")
            }
            return L10n.tr("正在运行", "Running", "Работает")
        case .protected:
            return L10n.tr("受保护，无法退出", "Protected. Cannot be quit.", "Защищён. Завершить нельзя.")
        case .notOwned:
            return L10n.tr("系统进程，需要管理员权限才能退出", "System process. Quitting it needs admin rights.", "Системный процесс. Нужны права администратора.")
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let image = ProcessIconCache.shared.icon(forExecutable: selected.executablePath) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 44, height: 44)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            stat("CPU", ProcessFormat.cpu(current.cpuPercent))
            stat(L10n.tr("内存", "Memory", "Память"), ProcessMemoryFormatter.format(current.memoryBytes))
            stat(L10n.tr("运行时间", "Run Time", "Время работы"), ProcessFormat.runtime(current.elapsedSeconds))
            stat("PID", String(current.pid))
            stat(L10n.tr("父进程", "Parent PID", "Родитель"), parentText)
            stat(L10n.tr("用户", "User", "Пользователь"), ProcessFormat.userName(current.uid))
        }
    }

    private var parentText: String {
        if let parent = model.processes.first(where: { $0.pid == current.ppid }) {
            return "\(current.ppid) · \(parent.name)"
        }
        return String(current.ppid)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func appSummary(_ group: ProcessGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
            Text(L10n.tr(
                "\(group.name) 共 \(group.members.count) 个进程：CPU \(ProcessFormat.cpu(group.cpuPercent))，内存 \(ProcessMemoryFormatter.format(group.memoryBytes))",
                "\(group.name) in total: \(group.members.count) processes, \(ProcessFormat.cpu(group.cpuPercent)) CPU, \(ProcessMemoryFormatter.format(group.memoryBytes)) memory",
                "\(group.name) всего: процессов \(group.members.count), CPU \(ProcessFormat.cpu(group.cpuPercent)), память \(ProcessMemoryFormatter.format(group.memoryBytes))"
            ))
        }
        .font(.system(size: 12))
    }

    private var pathBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("位置", "Location", "Расположение"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(selected.executablePath)
                .font(.system(size: 11).monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(L10n.tr("在访达中显示", "Reveal in Finder", "Показать в Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selected.executablePath)])
                }
                Button(L10n.tr("拷贝路径", "Copy Path", "Скопировать путь")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selected.executablePath, forType: .string)
                }
            }
            .controlSize(.small)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            let canQuit = ability == .allowed && !hasEnded && !isWorking
            Button {
                quit(force: false)
            } label: {
                Label(L10n.tr("退出", "Quit", "Завершить"), systemImage: "xmark.circle")
            }
            .disabled(!canQuit)

            Button(role: .destructive) {
                confirmForceQuit = true
            } label: {
                Label(L10n.tr("强制退出", "Force Quit", "Завершить принудительно"), systemImage: "bolt.circle")
            }
            .disabled(!canQuit)

            if let target = restartTarget {
                Button {
                    restart(target.main, bundlePath: target.bundlePath)
                } label: {
                    Label(
                        L10n.tr("重新启动 \(target.appName)", "Restart \(target.appName)", "Перезапустить \(target.appName)"),
                        systemImage: "arrow.clockwise.circle"
                    )
                }
                .disabled(hasEnded || isWorking)
            }

            Spacer()
            if isWorking {
                ProgressView().controlSize(.small)
            }
            Button(L10n.tr("关闭", "Close", "Закрыть")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .controlSize(.large)
    }

    // MARK: Actions

    private func quit(force: Bool) {
        isWorking = true
        message = nil
        Task {
            let outcome = await ProcessTerminator.terminate(current, force: force, sampler: model.sampler)
            await finish(outcome)
        }
    }

    private func restart(_ main: ProcessSnapshot, bundlePath: String) {
        isWorking = true
        message = nil
        Task {
            let outcome = await ProcessTerminator.restart(main, bundlePath: bundlePath, sampler: model.sampler)
            await finish(outcome)
        }
    }

    private func finish(_ outcome: ProcessTerminator.Outcome) async {
        switch outcome {
        case .sent:
            try? await Task.sleep(for: .milliseconds(700))
            await model.refreshNow()
            isWorking = false
            dismiss()
            return
        case .gone:
            await model.refreshNow()
            message = L10n.tr("该进程已不再运行。", "That process is no longer running.", "Этот процесс больше не запущен.")
        case .protected:
            message = L10n.tr("无法退出受保护的进程。", "That process is protected and cannot be quit.", "Этот процесс защищён и его нельзя завершить.")
        case .failed(let reason):
            message = L10n.tr("操作失败：\(reason)", "That did not work: \(reason)", "Не удалось: \(reason)")
        }
        isWorking = false
    }
}
