//
//  UnifiedCompactRepoRow.swift
//  Starcat
//
//  仓库选择器使用的共享紧凑行。
//
//  与 `UnifiedRepoRow` 的完整卡片不同，本组件服务于高密度筛选 / 多选场景：
//  只保留仓库身份、语言、Stars 和调用方提供的少量场景元数据，不展示描述、
//  Forks、Health 等详情信息。交互外壳继续复用 `RepoRowSurface`，确保主窗口、
//  RAG 浏览器和选择弹层的 hover / highlight 视觉不会再次分叉。
//

import SwiftUI

/// 高密度仓库选择行；业务侧通过 `additionalMetadata` 注入分片等场景信号。
struct UnifiedCompactRepoRow<AdditionalMetadata: View>: View {
    let fullName: String
    let owner: String
    let ownerAvatarURL: String?
    let language: String?
    let starsCount: Int

    /// 多选语义：只控制左侧勾选，不等同于键盘当前高亮项。
    let isChecked: Bool

    /// 键盘 / 列表当前落点；复用 `RepoRowSurface` 的选中背景和描边。
    let isHighlighted: Bool

    /// 达到选择上限时降低未选项视觉，但仍由外层 Button 决定是否可点击。
    let isEnabled: Bool

    private let additionalMetadata: AdditionalMetadata

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    init(
        fullName: String,
        owner: String,
        ownerAvatarURL: String?,
        language: String?,
        starsCount: Int,
        isChecked: Bool,
        isHighlighted: Bool,
        isEnabled: Bool = true,
        @ViewBuilder additionalMetadata: () -> AdditionalMetadata
    ) {
        self.fullName = fullName
        self.owner = owner
        self.ownerAvatarURL = ownerAvatarURL
        self.language = language
        self.starsCount = starsCount
        self.isChecked = isChecked
        self.isHighlighted = isHighlighted
        self.isEnabled = isEnabled
        self.additionalMetadata = additionalMetadata()
    }

    var body: some View {
        // 紧凑选择器与完整仓库卡片共享语言色背景，让高密度列表仍能快速建立
        // 仓库的视觉辨识；左侧勾选继续使用系统 accent，单独表达多选状态。
        RepoRowSurface(isSelected: isHighlighted, accentColor: accentColor) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(interfaceScale.font(.caption, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isChecked ? 1 : 0)
                    .frame(width: 12, alignment: .center)
                    .accessibilityHidden(!isChecked)

                RemoteAvatar(
                    urlString: ownerAvatarURL ?? RepoAvatarURL.from(owner: owner),
                    size: 28,
                    showBorder: false
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(fullName)
                        .font(interfaceScale.font(.body, weight: isHighlighted ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)

                    HStack(spacing: 6) {
                        if let language = normalizedLanguage {
                            LanguageBadge(language: language, style: .compact)
                        }
                        StarsBadge(count: starsCount, style: .compact)
                        additionalMetadata
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }

    /// 空白语言不渲染占位，避免第二行出现只有图标间距的“假 chip”。
    private var normalizedLanguage: String? {
        guard let language else { return nil }
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    /// 与完整 `UnifiedRepoRow` 保持一致：有语言时使用语言色，无语言时回退系统 accent。
    private var accentColor: Color? {
        normalizedLanguage.map(LanguageColor.color(for:))
    }
}
