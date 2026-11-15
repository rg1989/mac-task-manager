import SwiftUI
import MacCleanKit

/// The row of live cards above the process table: CPU, Memory, Storage, Network.
struct ProcessStatCards: View {
    let cards: SystemCardsSnapshot?
    let cpuHistory: [Double]
    let memoryHistory: [Double]
    let networkHistory: [Double]

    private let cpuTint = Color(red: 0.45, green: 0.62, blue: 1.0)
    private let memoryTint = Color(red: 1.0, green: 0.62, blue: 0.38)
    private let storageTint = Color(red: 0.70, green: 0.66, blue: 1.0)
    private let networkTint = Color(red: 0.40, green: 0.85, blue: 0.75)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            cpuCard
            memoryCard
            storageCard
            networkCard
        }
    }

    private var cpuCard: some View {
        card(icon: "cpu", title: "CPU", tint: cpuTint) {
            bigValue(cards.map { String(format: "%.1f%%", $0.cpuFraction * 100) } ?? "--")
            caption(L10n.tr(
                "\(cards?.perCoreFractions.count ?? 0) 个核心的平均值",
                "Average of \(cards?.perCoreFractions.count ?? 0) cores",
                "Среднее по \(cards?.perCoreFractions.count ?? 0) ядрам"
            ))
            Spacer(minLength: 4)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array((cards?.perCoreFractions ?? []).enumerated()), id: \.offset) { _, fraction in
                    CoreBar(fraction: fraction, tint: cpuTint)
                }
            }
            .frame(height: 18)
            Sparkline(values: cpuHistory, tint: cpuTint).frame(height: 22)
        }
    }

    private var memoryCard: some View {
        card(icon: "memorychip", title: L10n.tr("内存", "Memory", "Память"), tint: memoryTint) {
            bigValue(cards.map { ProcessMemoryFormatter.format($0.memory.used) } ?? "--")
            caption(cards.map {
                L10n.tr(
                    "共 \(ProcessMemoryFormatter.format($0.memory.total))",
                    "used of \(ProcessMemoryFormatter.format($0.memory.total))",
                    "из \(ProcessMemoryFormatter.format($0.memory.total))"
                )
            } ?? " ")
            Spacer(minLength: 4)
            detailLine(
                L10n.tr("交换", "Swap", "Подкачка"),
                cards.map { ProcessMemoryFormatter.format($0.memory.swapUsed) } ?? "--"
            )
            Sparkline(values: memoryHistory, tint: memoryTint).frame(height: 22)
        }
    }

    private var storageCard: some View {
        card(icon: "internaldrive", title: L10n.tr("存储", "Storage", "Диск"), tint: storageTint) {
            bigValue(cards.map { FileSizeFormatter.format($0.disk.free) } ?? "--")
            caption(cards.map {
                L10n.tr(
                    "可用，共 \(FileSizeFormatter.format($0.disk.total))",
                    "free of \(FileSizeFormatter.format($0.disk.total))",
                    "свободно из \(FileSizeFormatter.format($0.disk.total))"
                )
            } ?? " ")
            Spacer(minLength: 4)
            detailLine(
                L10n.tr("已用", "Used", "Занято"),
                cards.map { String(format: "%.0f%%", $0.disk.usedFraction * 100) } ?? "--"
            )
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(storageTint)
                        .frame(width: proxy.size.width * CGFloat(min(max(cards?.disk.usedFraction ?? 0, 0), 1)))
                }
            }
            .frame(height: 6)
            .padding(.vertical, 8)
        }
    }

    private var networkCard: some View {
        let peak = max(networkHistory.max() ?? 0, 1)
        return card(icon: "network", title: L10n.tr("网络", "Network", "Сеть"), tint: networkTint) {
            bigValue(cards.map { ProcessFormat.rate($0.bytesInPerSecond) } ?? "--")
            caption(L10n.tr("↓ 下载", "↓ Received", "↓ Получено"))
            Spacer(minLength: 4)
            detailLine(
                L10n.tr("↑ 上传", "↑ Sent", "↑ Отправлено"),
                cards.map { ProcessFormat.rate($0.bytesOutPerSecond) } ?? "--"
            )
            Sparkline(values: networkHistory.map { $0 / peak }, tint: networkTint).frame(height: 22)
        }
    }

    // MARK: Pieces

    private func card<Content: View>(
        icon: String,
        title: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 138, maxHeight: 138, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
    }

    private func bigValue(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .bold).monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.primary.opacity(0.6))
            .lineLimit(1)
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 10))
        .foregroundStyle(.primary.opacity(0.7))
    }
}

private struct CoreBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.10))
                RoundedRectangle(cornerRadius: 2).fill(tint)
                    .frame(height: max(2, proxy.size.height * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(maxWidth: 10)
    }
}

/// A filled line graph of values in 0…1. New values enter on the right, so a
/// short history starts part-way along.
struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let points = self.points(in: proxy.size)
            if let first = points.first, let last = points.last, points.count > 1 {
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: proxy.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: last.x, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(tint.opacity(0.18))
                    Path { path in
                        path.move(to: first)
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(tint, lineWidth: 1.5)
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let capacity = ProcessesViewModel.historyLength
        guard values.count > 1, capacity > 1 else { return [] }
        let step = size.width / CGFloat(capacity - 1)
        let offset = CGFloat(capacity - values.count) * step
        return values.enumerated().map { index, value in
            CGPoint(
                x: offset + CGFloat(index) * step,
                y: size.height * (1 - CGFloat(min(max(value, 0), 1)))
            )
        }
    }
}
