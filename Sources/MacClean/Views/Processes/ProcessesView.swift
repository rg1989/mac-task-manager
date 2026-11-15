import SwiftUI
import MacCleanKit

/// The Processes dashboard: the app's first page. Live cards over a
/// searchable, sortable process table with Quit and Force Quit.
struct ProcessesView: View {
    @Environment(AppState.self) private var appState
    @State private var model = ProcessesViewModel()
    @State private var selected: ProcessSnapshot?
    @State private var pendingQuit: ProcessSnapshot?
    @State private var showQuitConfirm = false
    @State private var pendingLeftover: LeftoverItem?
    @State private var showLeftoverConfirm = false
    @State private var showQuitAllConfirm = false
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
        .alert(
            L10n.tr(
                "退出“\(pendingLeftover?.title ?? "")”？",
                "Quit “\(pendingLeftover?.title ?? "")”?",
                "Завершить «\(pendingLeftover?.title ?? "")»?"
            ),
            isPresented: $showLeftoverConfirm,
            presenting: pendingLeftover
        ) { item in
            Button(L10n.tr("取消", "Cancel", "Отмена"), role: .cancel) {}
            Button(L10n.tr("退出", "Quit", "Завершить"), role: .destructive) { quitLeftovers([item]) }
        } message: { item in
            Text(leftoverWarning(for: item))
        }
        .alert(
            L10n.tr(
                "退出全部 \(model.leftoverCount) 个遗留进程？",
                "Quit all \(model.leftoverCount) leftovers?",
                "Завершить все остатки (\(model.leftoverCount))?"
            ),
            isPresented: $showQuitAllConfirm
        ) {
            Button(L10n.tr("取消", "Cancel", "Отмена"), role: .cancel) {}
            Button(L10n.tr("全部退出", "Quit All", "Завершить все"), role: .destructive) {
                quitLeftovers(model.leftovers.filter(\.isLeftover))
            }
        } message: {
            Text(L10n.tr(
                "只会退出启动程序已不存在的进程。仍被应用、编码助手或终端使用的不受影响。",
                "Only items whose launcher has exited are quit. Anything still used by an app, a coding agent or a terminal is left running.",
                "Будут завершены только процессы, чья запустившая программа уже закрыта. То, чем ещё пользуются приложение, агент или терминал, останется."
            ))
        }
        .sheet(item: $selected) { process in
            ProcessDetailSheet(model: model, selected: process)
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
                Text(leftoversTabTitle).tag(ProcessesViewModel.Mode.leftovers)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 290)
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
        } else if model.mode == .leftovers {
            ProcessLeftoversView(
                model: model,
                onSelect: { selected = $0 },
                onQuit: { item in
                    pendingLeftover = item
                    showLeftoverConfirm = true
                },
                onQuitAll: { showQuitAllConfirm = true }
            )
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 24)
        } else {
            ProcessTableView(
                model: model,
                onSelect: { selected = $0 },
                onQuit: { process in
                    pendingQuit = process
                    showQuitConfirm = true
                }
            )
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

    private var leftoversTabTitle: String {
        let title = L10n.tr("遗留", "Leftovers", "Остатки")
        return model.leftoverCount > 0 ? "\(title) \(model.leftoverCount)" : title
    }

    private func leftoverWarning(for item: LeftoverItem) -> String {
        let count = item.members.count
        switch item.ownership {
        case .leftover:
            return L10n.tr(
                "启动它的程序已经退出。将结束 \(count) 个进程。",
                "Whatever started it has exited. This ends \(count) process(es).",
                "Запустившая программа завершилась. Будет завершено процессов: \(count)."
            )
        case .ownedBy(let name):
            return L10n.tr(
                "\(name) 仍在运行，可能正在使用它。将结束 \(count) 个进程。",
                "\(name) is still running and may be using it. This ends \(count) process(es).",
                "\(name) ещё работает и может его использовать. Будет завершено процессов: \(count)."
            )
        case .terminal:
            return L10n.tr(
                "它在一个打开的终端中运行。将结束 \(count) 个进程。",
                "It is running in an open terminal. This ends \(count) process(es).",
                "Процесс работает в открытом терминале. Будет завершено процессов: \(count)."
            )
        case .service:
            return L10n.tr(
                "macOS 将它作为服务运行，退出后可能会自动重新启动。",
                "macOS runs it as a service, so it may start again by itself.",
                "macOS запускает его как службу, поэтому он может запуститься снова."
            )
        }
    }

    private func quitLeftovers(_ items: [LeftoverItem]) {
        Task {
            var failures: [String] = []
            for item in items {
                let outcome = await ProcessTerminator.terminateTree(root: item.root, members: item.members, sampler: model.sampler)
                if case .failed(let reason) = outcome { failures.append("\(item.title): \(reason)") }
                if outcome == .protected { failures.append(item.title) }
            }
            await model.refreshNow()
            if !failures.isEmpty {
                show(L10n.tr(
                    "无法退出：\(failures.joined(separator: "，"))",
                    "Could not quit: \(failures.joined(separator: ", "))",
                    "Не удалось завершить: \(failures.joined(separator: ", "))"
                ))
            }
        }
    }

    private var footerText: String {
        if model.mode == .leftovers {
            return L10n.tr(
                "发现 \(model.leftovers.count) 个，其中 \(model.leftoverCount) 个为遗留",
                "\(model.leftovers.count) found, \(model.leftoverCount) left behind",
                "Найдено: \(model.leftovers.count), остатков: \(model.leftoverCount)"
            )
        }
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
