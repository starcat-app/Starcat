//
//  AITagSuggestionCountRangeControl.swift
//  Starcat
//
//  每仓库 AI 标签推荐数量区间的共享控件（设置「标签分类」+ 批量整理右侧面板）。
//
//  为什么自研：
//  - 系统 `TextField(..., format: .number)` 在 macOS 上挡不住 IME / 字母；
//  - 禁止 SwiftUI `Stepper`（见 UI-禁止Stepper-规范）；
//  - 窄侧栏放不下「双组 ± + 数字」长胶囊（会挤掉左侧文案），因此行内只显示短芯片，
//    编辑放进 popover（交互对齐搜索筛选的 DateField：Button + popover）。
//
//  关键约束：
//  - 行内宽度只服务展示 `1–3` 量级文本，不承载 ±；
//  - 只接受数字字符，位数不超过 `allowedRange.upperBound` 的十进制长度；
//  - 失焦 / 回车 / 关闭 popover 一律经 `AITagSuggestionCountPolicy.clamp`，保证 1…8 且 min ≤ max；
//  - 空草稿提交时回退到当前已提交值，避免写成 0。
//

import SwiftUI

/// 短芯片展示区间，点击后在 popover 内编辑最少 / 最多。
struct AITagSuggestionCountRangeControl: View {
    let minimum: Int
    let maximum: Int
    var style: Style = .regular
    /// 两端一起提交，避免先后改 Binding 产生中间态。
    let onApply: (_ minimum: Int, _ maximum: Int) -> Void

    enum Style {
        /// 设置页：芯片略松一点。
        case regular
        /// 批量整理窄侧栏：更紧凑。
        case compact
    }

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    @State private var isPresented = false
    @State private var minDraft = ""
    @State private var maxDraft = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case minimum
        case maximum
    }

    private var allowedRange: ClosedRange<Int> { AITagSuggestionCountPolicy.allowedRange }
    private var maxDigitCount: Int { String(allowedRange.upperBound).count }

    private var displayText: String {
        AITagSuggestionCountPolicy.displayRange(minimum: minimum, maximum: maximum)
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: displayText)
                    .font(interfaceScale.font(.caption).weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: style == .compact ? 8 : 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, style == .compact ? 8 : 10)
            .padding(.vertical, style == .compact ? 4 : 5)
            .background(chipFill, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        Color.secondary.opacity(colorScheme == .dark ? 0.30 : 0.18),
                        lineWidth: 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .help("settings.autoTidy.tagSuggestionCount")
        .accessibilityLabel(Text("settings.autoTidy.tagSuggestionCount"))
        .accessibilityValue(Text(verbatim: displayText))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            editorPopover
                .appLocaleEnvironment()
        }
        .onChange(of: isPresented) { _, presented in
            if presented {
                syncDraftsFromValues(force: true)
            } else {
                commitAll()
            }
        }
    }

    // MARK: - Popover

    private var editorPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            editorRow(
                titleKey: "settings.autoTidy.tagSuggestionCount.min",
                draft: $minDraft,
                field: .minimum
            )
            editorRow(
                titleKey: "settings.autoTidy.tagSuggestionCount.max",
                draft: $maxDraft,
                field: .maximum
            )
        }
        .padding(12)
        .frame(width: 168)
        .onChange(of: focusedField) { previous, current in
            if previous == .minimum, current != .minimum {
                commit(field: .minimum)
            }
            if previous == .maximum, current != .maximum {
                commit(field: .maximum)
            }
        }
    }

    private func editorRow(
        titleKey: LocalizedStringKey,
        draft: Binding<String>,
        field: Field
    ) -> some View {
        HStack(spacing: 8) {
            Text(titleKey)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            TextField("", text: draft)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(interfaceScale.font(.body).monospacedDigit())
                .frame(maxWidth: .infinity)
                .focused($focusedField, equals: field)
                .onSubmit { commit(field: field) }
                .onChange(of: draft.wrappedValue) { _, newValue in
                    let filtered = String(newValue.filter(\.isNumber).prefix(maxDigitCount))
                    if filtered != newValue {
                        draft.wrappedValue = filtered
                    }
                }
                .accessibilityLabel(titleKey)
        }
    }

    // MARK: - Logic

    private var chipFill: Color {
        colorScheme == .dark
            ? Color.primary.opacity(0.10)
            : Color.primary.opacity(0.05)
    }

    private func syncDraftsFromValues(force: Bool = false) {
        let clamped = AITagSuggestionCountPolicy.clamp(minimum: minimum, maximum: maximum)
        if force || focusedField != .minimum {
            minDraft = String(clamped.minimum)
        }
        if force || focusedField != .maximum {
            maxDraft = String(clamped.maximum)
        }
    }

    private func commit(field: Field) {
        let draft = field == .minimum ? minDraft : maxDraft
        let fallback = field == .minimum ? minimum : maximum
        let parsed = Int(draft) ?? fallback
        switch field {
        case .minimum:
            apply(minimum: parsed, maximum: maximum)
        case .maximum:
            apply(minimum: minimum, maximum: parsed)
        }
    }

    private func commitAll() {
        focusedField = nil
        let lo = Int(minDraft) ?? minimum
        let hi = Int(maxDraft) ?? maximum
        apply(minimum: lo, maximum: hi)
    }

    private func apply(minimum lo: Int, maximum hi: Int) {
        let clamped = AITagSuggestionCountPolicy.clamp(minimum: lo, maximum: hi)
        minDraft = String(clamped.minimum)
        maxDraft = String(clamped.maximum)
        onApply(clamped.minimum, clamped.maximum)
    }
}
