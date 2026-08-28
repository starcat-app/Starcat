//
//  RepoAIGenerationOptionsSection.swift
//  Starcat
//
//  单仓 AI 摘要生成前的本次选项：代码上下文 / 外部搜索。
//
//  为什么单独成页而不是两个裸 Toggle：
//  - dong4j 要求空态必须说明每个开关做什么，而不是只放控件；
//  - macOS 26 系统 Switch 在窄浮层里视觉过重（批量整理 OptionCard 已踩过同样的坑）；
//  - 这两个值只覆盖「下一次生成」，卡片必须看起来像本次选择，而不是设置页里的全局开关。
//
//  关键约束：
//  - Binding 只写 ViewModel，禁止绑定 `AppSettings`；
//  - 私有仓库外搜仍受「允许私有仓库」门控，卡片禁用而不是让用户点了却被静默丢掉；
//  - 没有可用 External Search Provider 时同样禁用，避免点开后空跑。
//

import SwiftUI

/// 摘要空态 / 重新生成前的本次上下文选项。
struct RepoAIGenerationOptionsSection: View {

    @Binding var includeCodeContext: Bool
    @Binding var includeExternalSearch: Bool

    let isDisabled: Bool
    let canPrepareCodeContext: Bool
    let repoIsPrivate: Bool
    let allowPrivateExternalSearch: Bool
    let hasUsableExternalSearchProvider: Bool

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ai.assistant.summary.options.section")
                    .font(interfaceScale.font(.captionStrong))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text("ai.assistant.summary.options.footnote")
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                RepoAIGenerationOptionCard(
                    icon: "doc.text.magnifyingglass",
                    title: "ai.assistant.summary.options.codeContext.title",
                    subtitle: "ai.assistant.summary.options.codeContext.subtitle",
                    isSelected: includeCodeContext,
                    isDisabled: isDisabled || !canPrepareCodeContext
                ) {
                    includeCodeContext.toggle()
                }

                RepoAIGenerationOptionCard(
                    icon: "globe",
                    title: "ai.assistant.summary.options.externalSearch.title",
                    subtitle: externalSearchSubtitle,
                    isSelected: includeExternalSearch && !isExternalSearchBlocked,
                    isDisabled: isDisabled || isExternalSearchBlocked
                ) {
                    includeExternalSearch.toggle()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// 私仓门控或未配置 Provider 时，副标题改成「为什么不能开」，避免用户以为开关坏了。
    private var externalSearchSubtitle: LocalizedStringKey {
        if repoIsPrivate, !allowPrivateExternalSearch {
            return "ai.assistant.summary.options.externalSearch.privateBlocked"
        }
        if !hasUsableExternalSearchProvider {
            return "ai.assistant.summary.options.externalSearch.unavailable"
        }
        return "ai.assistant.summary.options.externalSearch.subtitle"
    }

    private var isExternalSearchBlocked: Bool {
        (repoIsPrivate && !allowPrivateExternalSearch) || !hasUsableExternalSearchProvider
    }
}

/// 可点击选项卡，视觉语言对齐批量整理 `OptionCard`：整卡切换 + 圆形勾选，不用系统 Switch。
private struct RepoAIGenerationOptionCard: View {

    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let isSelected: Bool
    var isDisabled: Bool = false
    let onToggle: () -> Void

    @State private var isHovered = false
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 12) {
                iconBadge
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(interfaceScale.font(.bodyEmphasis, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                checkmark
                    .padding(.top, 1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(cardBackground)
            .overlay(cardBorder)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
        .accessibilityAddTraits(.isToggle)
        .onHover { hovering in
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.12)) {
                isHovered = hovering && !isDisabled
            }
        }
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var checkmark: some View {
        if isSelected {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 18, height: 18)
            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
        } else {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1.2)
                .frame(width: 18, height: 18)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                isSelected
                    ? Color.accentColor.opacity(0.08)
                    : (isHovered ? Color.secondary.opacity(0.06) : Color.clear)
            )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                isSelected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18),
                lineWidth: 1
            )
    }
}
