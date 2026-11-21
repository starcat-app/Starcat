//
//  DiagnosticReportTimePicker.swift
//  Starcat
//
//  诊断报告专用时间选择：等宽分段按钮、自绘月历和数字时分输入。
//  不使用系统 DatePicker 或 Stepper，日期计算与报告草稿共用本地日历边界。
//

import SwiftUI

/// 控件始终填满表单的值列；选中背景移动，文字与点击区域保持原位。
struct DiagnosticReportTimePicker: View {
    @Binding var choice: DiagnosticReportDraft.TimeChoice
    @Binding var date: Date
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var scale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Namespace private var selectionSpace
    @State private var hoveredChoice: DiagnosticReportDraft.TimeChoice?
    @State private var showsCalendar = false
    @FocusState private var focusedChoice: DiagnosticReportDraft.TimeChoice?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(DiagnosticReportDraft.TimeChoice.allCases) { item in
                    Button { choice = item } label: {
                        Text(LocalizedStringKey(item.titleKey))
                            .font(scale.font(.body, weight: choice == item ? .medium : .regular))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background {
                                if choice == item {
                                    RoundedRectangle(cornerRadius: 5)
                                        // 紧凑分段沿用 macOS 的浅色选中面，避免整行大面积蓝底。
                                        .fill(Color.fromHex6(colorScheme == .dark ? 0x3A3A3C : 0xFFFFFF))
                                        .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                                        .matchedGeometryEffect(id: "diagnostics.time.selection", in: selectionSpace)
                                } else if hoveredChoice == item {
                                    RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05))
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .focused($focusedChoice, equals: item)
                    .accessibilityAddTraits(choice == item ? .isSelected : [])
                    .onHover { hoveredChoice = $0 ? item : nil }
                }
            }
            .padding(2)
            .onKeyPress(.leftArrow) { moveChoice(-1); return .handled }
            .onKeyPress(.rightArrow) { moveChoice(1); return .handled }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82), value: choice)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hoveredChoice)

            if choice == .custom {
                Button { showsCalendar = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar").foregroundStyle(.secondary)
                        Text(verbatim: dateTitle)
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down").font(scale.font(.caption)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel(Text("settings.diagnostics.capture.time"))
                .popover(isPresented: $showsCalendar) {
                    CalendarPopover(date: $date)
                        .appLocaleEnvironment()
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: choice == .custom)
    }

    private var dateTitle: String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// 方向键与鼠标共用同一选择，保持自绘分段控件的键盘操作语义。
    private func moveChoice(_ offset: Int) {
        let items = DiagnosticReportDraft.TimeChoice.allCases
        guard let index = items.firstIndex(of: focusedChoice ?? choice), items.indices.contains(index + offset) else { return }
        choice = items[index + offset]
        focusedChoice = choice
    }

    /// 月历只负责编辑本次问题发生时间；阶段日志和导出范围不随翻月改变。
    private struct CalendarPopover: View {
        @Binding var date: Date
        @Environment(\.dismiss) private var dismiss
        @Environment(\.locale) private var locale
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.starcatReduceMotion) private var reduceMotion
        @State private var displayedMonth = Date()
        @State private var hoveredDay: Date?
        @State private var hourText = ""
        @State private var minuteText = ""

        private var calendar: Calendar {
            var value = Calendar(identifier: .gregorian)
            value.locale = locale
            value.timeZone = .current
            return value
        }

        var body: some View {
            VStack(spacing: 14) {
                HStack {
                    monthButton(offset: -1, title: "diagnostics.report.calendar.previousMonth")
                    Spacer()
                    Text(verbatim: monthTitle).font(.body.weight(.semibold))
                    Spacer()
                    monthButton(offset: 1, title: "diagnostics.report.calendar.nextMonth")
                        .disabled(calendar.isDate(displayedMonth, equalTo: Date(), toGranularity: .month))
                }
                let symbols = calendar.veryShortStandaloneWeekdaySymbols
                HStack(spacing: 4) {
                    ForEach(0..<7) { index in
                        Text(verbatim: symbols[(calendar.firstWeekday - 1 + index) % 7])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    let days = DiagnosticReportDraft.monthDays(containing: displayedMonth, calendar: calendar)
                    ForEach(days.indices, id: \.self) { index in
                        if let day = days[index] { dayButton(day) }
                        else { Color.clear.frame(height: 28) }
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    Text("settings.diagnostics.capture.time").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    clockField(hour: true)
                    Text(verbatim: ":").foregroundStyle(.secondary)
                    clockField(hour: false)
                }
                HStack {
                    Spacer()
                    Button("general.close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .font(.body)
            .padding(16)
            .frame(width: 300)
            .onAppear {
                displayedMonth = date
                syncClockText()
            }
        }

        private var monthTitle: String {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.setLocalizedDateFormatFromTemplate("yMMMM")
            return formatter.string(from: displayedMonth)
        }

        private func monthButton(offset: Int, title: LocalizedStringKey) -> some View {
            Button {
                displayedMonth = calendar.date(byAdding: .month, value: offset, to: displayedMonth) ?? displayedMonth
            } label: {
                Image(systemName: offset < 0 ? "chevron.left" : "chevron.right")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(Text(title))
            .accessibilityLabel(Text(title))
        }

        private func dayButton(_ day: Date) -> some View {
            let selected = calendar.isDate(day, inSameDayAs: date)
            let future = calendar.startOfDay(for: day) > calendar.startOfDay(for: Date())
            return Button {
                date = DiagnosticReportDraft.updatingTime(date, day: day, calendar: calendar, maximum: Date())
                syncClockText()
            } label: {
                Text(verbatim: calendar.component(.day, from: day).formatted(.number.locale(locale)))
                    .font(.body.weight(selected ? .semibold : .regular))
                    .foregroundStyle(future ? .secondary : .primary)
                    .environment(\.colorScheme, selected ? .dark : colorScheme)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background {
                        if selected { Circle().fill(Color.accentColor) }
                        else if hoveredDay == day { Circle().fill(Color.primary.opacity(0.06)) }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(future)
            .accessibilityLabel(Text(day, format: .dateTime.year().month(.wide).day().locale(locale)))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .onHover { hoveredDay = $0 ? day : nil }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hoveredDay)
        }

        private func clockField(hour: Bool) -> some View {
            TextField("", text: Binding(
                get: { hour ? hourText : minuteText },
                set: { updateClock($0, hour: hour) }
            ))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .padding(.vertical, 6)
            .frame(width: 40)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(Text(LocalizedStringKey(hour ? "diagnostics.report.clock.hour" : "diagnostics.report.clock.minute")))
            .onSubmit { syncClockText() }
        }

        /// 输入时只保留两位数字，立即钳制；不在每次输入后补零，避免打断连续键入。
        private func updateClock(_ text: String, hour: Bool) {
            let digits = String(text.compactMap(\.wholeNumberValue).map(String.init).joined().prefix(2))
            let value = min(hour ? 23 : 59, max(0, Int(digits) ?? 0))
            date = DiagnosticReportDraft.updatingTime(date, hour: hour ? value : nil, minute: hour ? nil : value,
                                                     calendar: calendar, maximum: Date())
            let actual = calendar.component(hour ? .hour : .minute, from: date)
            let edited = digits.isEmpty ? "" : actual == value ? digits : String(actual)
            if hour {
                hourText = edited
                minuteText = String(format: "%02d", calendar.component(.minute, from: date))
            } else {
                minuteText = edited
                hourText = String(format: "%02d", calendar.component(.hour, from: date))
            }
        }

        private func syncClockText() {
            hourText = String(format: "%02d", calendar.component(.hour, from: date))
            minuteText = String(format: "%02d", calendar.component(.minute, from: date))
        }
    }
}
