import SwiftUI

/// "用量" — a contribution-graph style heat-map built from the history
/// database, plus a summary line underneath.
struct UsagePage: View {
    @Bindable var model: AppModel

    @State private var counts: [Date: Int] = [:]
    @State private var total = 0
    @State private var busiestDay: (Date, Int)?

    private let weeks = 26

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsPageMetrics.sectionSpacing) {
                header
                heatmapCard
                summary
                breakdown
            }
            .padding(.horizontal, 22)
            .padding(.top, SettingsPageMetrics.headerTopPadding)
            .padding(.bottom, 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { load() }
        .onChange(of: model.totalCount) { _, _ in load() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: SettingsPageMetrics.headerTitleSpacing) {
                Text("用量")
                    .font(.system(size: 26, weight: .bold))
            }
            Spacer()
            // A bare `Button` is AppKit's white pill, which reads as a foreign
            // control next to the glass card below it; the page's one action
            // wears the same capsule as every settings row.
            NeutralCapsuleButton(
                title: "刷新",
                symbol: "arrow.clockwise",
                help: "重新统计用量数据"
            ) {
                load()
            }
        }
    }

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("每日用量")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                legend
            }
            Heatmap(counts: counts, weeks: weeks)
        }
        .padding(14)
        .glassSurface(cornerRadius: 12)
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("少").font(.system(size: 10)).foregroundStyle(.tertiary)
            ForEach([0, 1, 3, 6, 10], id: \.self) { level in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Heatmap.color(for: level))
                    .frame(width: 11, height: 11)
            }
            Text("多").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var summary: some View {
        if total > 0 {
            HStack(spacing: 6) {
                Text("🎉").font(.system(size: 13))
                Text("累计收录 **\(total)** 条")
                    .font(.system(size: 12))
                if let busiestDay {
                    Text("· 最忙的一天是 \(busiestDay.0.formatted(.dateTime.month().day()))（\(busiestDay.1) 条）")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader("最近 7 天")
            GroupSlab {
                ForEach(Array(recentDays.enumerated()), id: \.element.date) { index, entry in
                    if index > 0 { GroupDivider() }
                    GroupRow(
                        symbol: entry.count > 0 ? "square.fill" : "square.dashed",
                        color: entry.count > 0 ? .blue : .gray,
                        title: entry.date.formatted(.dateTime.month().day().weekday(.wide)),
                        value: "\(entry.count) 条"
                    )
                }
            }
        }
    }

    private struct DayEntry: Hashable {
        let date: Date
        let count: Int
    }

    private var recentDays: [DayEntry] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayEntry(date: date, count: counts[date] ?? 0)
        }
    }

    private func load() {
        let fetched = model.dailyCounts(days: weeks * 7)
        counts = fetched
        total = fetched.values.reduce(0, +)
        busiestDay = fetched.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
}

/// GitHub-style contribution grid: one column per week, one row per weekday.
struct Heatmap: View {
    let counts: [Date: Int]
    let weeks: Int

    private let cell: CGFloat = 11
    private let spacing: CGFloat = 3

    static func color(for count: Int) -> Color {
        switch count {
        case 0: return Color.primary.opacity(0.07)
        case 1...2: return Color.accentColor.opacity(0.28)
        case 3...5: return Color.accentColor.opacity(0.5)
        case 6...9: return Color.accentColor.opacity(0.72)
        default: return Color.accentColor
        }
    }

    /// Columns of 7 days, oldest first, aligned so the last column is this week.
    private var grid: [[Date?]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // Walk back to the Sunday that starts the earliest column.
        let weekday = calendar.component(.weekday, from: today) - 1
        guard let lastSunday = calendar.date(byAdding: .day, value: -weekday, to: today),
              let firstSunday = calendar.date(byAdding: .day, value: -(weeks - 1) * 7, to: lastSunday)
        else { return [] }

        return (0..<weeks).map { week in
            (0..<7).map { day -> Date? in
                guard let date = calendar.date(byAdding: .day, value: week * 7 + day, to: firstSunday),
                      date <= today else { return nil }
                return date
            }
        }
    }

    var body: some View {
        let columns = grid
        HStack(alignment: .top, spacing: spacing) {
            // Weekday gutter
            VStack(alignment: .trailing, spacing: spacing) {
                ForEach(0..<7, id: \.self) { row in
                    Text(["日", "", "二", "", "四", "", "六"][row])
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12, height: cell)
                }
            }

            ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                VStack(spacing: spacing) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        if let day {
                            let count = counts[day] ?? 0
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(Self.color(for: count))
                                .frame(width: cell, height: cell)
                                .help("\(day.formatted(.dateTime.year().month().day()))：\(count) 条")
                        } else {
                            Color.clear.frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
        .fixedSize()
    }
}
