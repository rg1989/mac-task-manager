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
            NumberCell(text: ProcessMemoryFormatter.format(process.memoryBytes), width: ProcessColumns.memory)
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
            NumberCell(text: ProcessMemoryFormatter.format(group.memoryBytes), width: ProcessColumns.memory, emphasized: true)
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
