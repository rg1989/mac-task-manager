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
