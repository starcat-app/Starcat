//
//  DailyRadarEditionCalendarPicker.swift
//  Starcat
//
//  日报历史期次的日期选择器。收起态始终显示当前期次，Popover 只呈现一个月，
//  历史规模增长不会把菜单拉长。
//

import SwiftUI

struct DailyRadarEditionCalendarPicker: View {
    /// 服务端 `/dates` 返回的真实出刊日。空集时保持控件可用但所有日期置灰。
    let availableDates: Set<String>
    /// nil 表示“本期精选”，即当前筛选下的最新可用期次。
    let selectedDate: String?
    let latestDate: String?
    let onSelectLatest: () -> Void
    let onSelect: (String) -> Void

    @State private var isPresented = false
    @State private var displayedMonth: Date?
    @State private var showsYearMonthPicker = false
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var scale

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if let previousDate { onSelect(previousDate) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(scale.font(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(previousDate == nil)
            .help("dailyRadar.previousEdition")
            .accessibilityLabel(Text("dailyRadar.previousEdition"))

            Button {
                isPresented.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(scale.font(size: 12))
                        .foregroundStyle(.secondary)
                    Text(verbatim: displayDate)
                        .font(scale.font(size: 12))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(Text("dailyRadar.selectDate"))

            Button {
                if let nextDate { onSelect(nextDate) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(scale.font(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(nextDate == nil)
            .help("dailyRadar.nextEdition")
            .accessibilityLabel(Text("dailyRadar.nextEdition"))
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popover
                .appLocaleEnvironment()
        }
    }

    private var popover: some View {
        VStack(spacing: 0) {
            Button {
                onSelectLatest()
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle")
                        .foregroundStyle(Color.accentColor)
                    Text("dailyRadar.featured")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .padding(.horizontal, 14)
            .frame(height: 38)

            Divider()
                .padding(.horizontal, 8)

            // 月历与年月选择保留两棵视图，只切换可见性，避免在同一个
            // Popover host 中结构性替换根内容并反复更新 AppKit 约束。
            ZStack {
                monthCalendar
                    .opacity(showsYearMonthPicker ? 0 : 1)
                    .allowsHitTesting(!showsYearMonthPicker)
                yearMonthPicker
                    .opacity(showsYearMonthPicker ? 1 : 0)
                    .allowsHitTesting(showsYearMonthPicker)
            }

            Divider()
                .padding(.horizontal, 8)
            Text("dailyRadar.unavailableDateHint")
                .font(scale.font(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 284, height: 352)
        .clipped()
        .onAppear {
            if displayedMonth == nil {
                displayedMonth = anchorDate
            }
        }
        .onChange(of: isPresented) { _, isShown in
            guard isShown else { return }
            // 打开时一次性定位，不在打开期间跟随外部日期变化重置 Popover 状态。
            displayedMonth = anchorDate
            showsYearMonthPicker = false
        }
    }

    private var monthCalendar: some View {
        let calendar = businessCalendar
        let month = displayedMonth ?? anchorDate
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return AnyView(EmptyView()) }
        let leading = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: leading)
        var cursor = interval.start
        while cursor < interval.end {
            days.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? interval.end
        }
        return AnyView(VStack(spacing: 10) {
            monthHeader(title: monthTitle(month), month: month)
            weekdayHeader
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayButton(day)
                    } else {
                        Color.clear.frame(height: 26)
                    }
                }
            }
        }
        .padding(14))
    }

    private var yearMonthPicker: some View {
        let calendar = businessCalendar
        let anchor = displayedMonth ?? anchorDate
        let year = calendar.component(.year, from: anchor)
        let symbols = calendar.standaloneMonthSymbols
        return VStack(spacing: 10) {
            HStack {
                Button {
                    moveYear(-1)
                } label: {
                    Image(systemName: "chevron.left").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                Spacer()
                Text(verbatim: String(year))
                    .font(scale.font(size: 13, weight: .semibold))
                Spacer()
                Button {
                    moveYear(1)
                } label: {
                    Image(systemName: "chevron.right").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                    monthPickerButton(year: year, month: index + 1, title: symbol)
                }
            }
        }
        .padding(14)
    }

    private func monthHeader(title: String, month: Date) -> some View {
        HStack {
            Button {
                moveMonth(-1)
            } label: {
                Image(systemName: "chevron.left").frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(hasEarlierMonth(after: month) == false)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showsYearMonthPicker = true }
            } label: {
                HStack(spacing: 3) {
                    Text(verbatim: title)
                        .font(scale.font(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(scale.font(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(Text("dailyRadar.selectMonth"))
            Spacer()
            Button {
                moveMonth(1)
            } label: {
                Image(systemName: "chevron.right").frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(hasLaterMonth(before: month) == false)
        }
    }

    private var weekdayHeader: some View {
        let calendar = businessCalendar
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let startIndex = calendar.firstWeekday - 1
        let ordered = (0..<7).map { symbols[(startIndex + $0) % symbols.count] }
        return HStack(spacing: 2) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(verbatim: symbol)
                    .font(scale.font(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayButton(_ date: Date) -> some View {
        let key = DailyRadarDateFormatting.businessDate(from: date, calendar: businessCalendar)
        let isAvailable = availableDates.contains(key)
        let isSelected = key == selectedDate || (selectedDate == nil && key == latestDate)
        return Button {
            onSelect(key)
            dismiss()
        } label: {
            Text(verbatim: String(businessCalendar.component(.day, from: date)))
                .font(scale.font(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : (isAvailable ? Color.primary : Color.secondary))
                .frame(maxWidth: .infinity, minHeight: 26)
                .background {
                    if isSelected {
                        Circle().fill(Color.accentColor)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!isAvailable)
        .accessibilityValue(Text(isAvailable
                                 ? "dailyRadar.dateAvailable"
                                 : "dailyRadar.dateUnavailable"))
    }

    private func monthPickerButton(year: Int, month: Int, title: String) -> some View {
        let date = businessCalendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? anchorDate
        let isAvailable = monthHasAvailableContent(date)
        let isSelected = businessCalendar.isDate(displayedMonth ?? anchorDate, equalTo: date, toGranularity: .month)
        return Button {
            displayedMonth = date
            withAnimation(.easeInOut(duration: 0.15)) { showsYearMonthPicker = false }
        } label: {
            Text(verbatim: title)
                .font(scale.font(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isAvailable ? Color.primary : Color.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!isAvailable)
    }

    private var displayDate: String {
        guard let date = selectedDate ?? latestDate else { return String.l10n("dailyRadar.featured") }
        return DailyRadarDateFormatting.label(date, locale: locale)
    }

    private var anchorDate: Date {
        DailyRadarDateFormatting.date(fromBusinessDate: selectedDate ?? latestDate ?? "") ?? Date()
    }

    private var businessCalendar: Calendar {
        DailyRadarDateFormatting.calendar(for: locale)
    }

    private var previousDate: String? {
        sortedDates.last(where: { $0 < currentDate })
    }

    private var nextDate: String? {
        sortedDates.first(where: { $0 > currentDate })
    }

    private var currentDate: String {
        selectedDate ?? latestDate ?? ""
    }

    private var sortedDates: [String] {
        availableDates.sorted()
    }

    private func monthTitle(_ month: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = businessCalendar
        formatter.timeZone = businessCalendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter.string(from: month)
    }

    /// 选择会触发父级数据和 Popover 内容同时更新；关闭放到下一个 runloop，
    /// 避免选择、状态重置与关闭在同一个 AppKit 布局事务里竞争。
    private func dismiss() {
        Task { @MainActor in
            isPresented = false
        }
    }

    private func moveMonth(_ direction: Int) {
        move(anchor: displayedMonth ?? anchorDate, component: .month, value: direction)
    }

    private func moveYear(_ direction: Int) {
        move(anchor: displayedMonth ?? anchorDate, component: .year, value: direction)
    }

    private func move(anchor: Date, component: Calendar.Component, value: Int) {
        guard let target = businessCalendar.date(byAdding: component, value: value, to: anchor) else { return }
        displayedMonth = target
    }

    private func hasEarlierMonth(after month: Date) -> Bool {
        guard let first = sortedDates.first,
              let date = DailyRadarDateFormatting.date(fromBusinessDate: first) else { return false }
        return businessCalendar.compare(date, to: businessCalendar.startOfDay(for: month), toGranularity: .month) == .orderedAscending
    }

    private func hasLaterMonth(before month: Date) -> Bool {
        guard let last = sortedDates.last,
              let date = DailyRadarDateFormatting.date(fromBusinessDate: last) else { return false }
        return businessCalendar.compare(date, to: businessCalendar.startOfDay(for: month), toGranularity: .month) == .orderedDescending
    }

    private func monthHasAvailableContent(_ month: Date) -> Bool {
        sortedDates.contains { date in
            guard let parsed = DailyRadarDateFormatting.date(fromBusinessDate: date) else { return false }
            return businessCalendar.isDate(parsed, equalTo: month, toGranularity: .month)
        }
    }
}
