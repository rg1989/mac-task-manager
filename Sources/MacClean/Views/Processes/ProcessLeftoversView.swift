import SwiftUI
import MacCleanKit

/// Headless browsers and dev servers, with who still owns each one. Coding
/// agents and test tools start these and do not always stop them.
struct ProcessLeftoversView: View {
    let model: ProcessesViewModel
    let onSelect: (ProcessSnapshot) -> Void
    let onQuit: (LeftoverItem) -> Void
    let onQuitAll: () -> Void

    var body: some View {
        if model.leftovers.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(.green.opacity(0.8))
                Text(L10n.tr("没有遗留的进程", "Nothing left behind", "Ничего не осталось"))
                    .font(.system(size: 15, weight: .semibold))
                Text(L10n.tr(
                    "没有发现无头浏览器或开发服务器。",
                    "No headless browsers or dev servers are running.",
                    "Безголовых браузеров и серверов разработки не найдено."
                ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.leftovers) { item in
                            LeftoverRowView(
                                item: item,
                                onSelect: { onSelect(item.root) },
                                onQuit: { onQuit(item) }
                            )
                            Divider().opacity(0.25)
                        }
                    }
                }
                if model.leftoverCount > 0 {
                    Divider().opacity(0.4)
                    HStack {
                        Text(L10n.tr(
                            "“遗留”表示启动它的程序已经退出，没有任何东西在使用它。",
                            "Leftover means whatever started it has exited and nothing is using it.",
                            "«Остаток» означает, что запустившая программа завершилась и процесс никем не используется."
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive, action: onQuitAll) {
                            Label(
                                L10n.tr(
                                    "退出全部遗留进程（\(model.leftoverCount)）",
                                    "Quit all leftovers (\(model.leftoverCount))",
                                    "Завершить все остатки (\(model.leftoverCount))"
                                ),
                                systemImage: "xmark.circle"
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
    }
}

private struct LeftoverRowView: View {
    let item: LeftoverItem
    let onSelect: () -> Void
    let onQuit: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            statusPill
            Image(systemName: item.kind == .headlessBrowser ? "globe" : "server.rack")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if item.members.count > 1 {
                        Text(L10n.tr(
                            "\(item.members.count) 个进程",
                            "\(item.members.count) processes",
                            "процессов: \(item.members.count)"
                        ))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    ForEach(item.ports.prefix(4), id: \.self) { port in
                        Text(":\(String(port))")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(ProcessFormat.runtime(item.root.elapsedSeconds))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.7))
                .frame(width: 70, alignment: .trailing)
            Text(ProcessMemoryFormatter.format(item.memoryBytes))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 78, alignment: .trailing)

            Button(action: onQuit) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.red.opacity(0.9))
            }
            .buttonStyle(.plain)
            .help(L10n.tr("退出…", "Quit…", "Завершить…"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(isHovering ? Color.primary.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(item.commandLine)
    }

    private var statusPill: some View {
        Text(item.isLeftover
             ? L10n.tr("遗留", "LEFTOVER", "ОСТАТОК")
             : L10n.tr("使用中", "IN USE", "В РАБОТЕ"))
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(item.isLeftover ? Color.orange : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(width: 74)
            .background(
                (item.isLeftover ? Color.orange : Color.primary).opacity(item.isLeftover ? 0.18 : 0.08),
                in: Capsule()
            )
    }

    private var subtitle: String {
        let owner: String
        switch item.ownership {
        case .leftover:
            owner = L10n.tr("启动它的程序已退出", "launcher has exited", "запустившая программа завершилась")
        case .ownedBy(let name):
            owner = L10n.tr("由 \(name) 启动", "started by \(name)", "запущено: \(name)")
        case .terminal:
            owner = L10n.tr("在终端中运行", "running in a terminal", "работает в терминале")
        case .service:
            owner = L10n.tr("由 macOS 作为服务管理", "kept running by macOS as a service", "служба под управлением macOS")
        }
        guard let folder = item.workingDirectory, folder != "/" else { return owner }
        let home = NSHomeDirectory()
        let shown = folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
        return "\(owner) · \(shown)"
    }
}
