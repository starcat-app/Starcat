//
//  SettingsSectionHeader.swift
//  Starcat
//
//  macOS 设置页 Form 分组标题：在分组名左侧补 SF Symbol。
//
//  设计约束：
//  - `.prominent` 对齐设置页规范：分组名称与行 Label 同为 13pt，仅用 semibold 区分；
//    图标为 13pt，布局框为 20pt。
//  - `.compact` 保留尚未逐页收口的既有设置页观感；迁移时必须显式切到 `.prominent`。
//  - 只用于 `Section { } header: { }` 外挂标题，不替代行内 Label 或 DisclosureGroup 正文图标。
//

import SwiftUI

/// 设置页分组标题（图标 + 文案）。
struct SettingsSectionHeader: View {

    /// 分组标题在逐页收口期间的视觉层级。
    ///
    /// 不能直接改默认样式：Settings 的其他 Tab 仍处于审查前状态，避免一个共享组件
    /// 的改动越过当前页面的 UI 改造边界。
    enum Style {
        case compact
        case prominent
    }

    private let title: Text
    private let systemImage: String
    private let style: Style

    init(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        style: Style = .compact
    ) {
        self.title = Text(titleKey)
        self.systemImage = systemImage
        self.style = style
    }

    init(
        verbatim title: String,
        systemImage: String,
        style: Style = .compact
    ) {
        self.title = Text(verbatim: title)
        self.systemImage = systemImage
        self.style = style
    }

    var body: some View {
        HStack(spacing: style == .prominent ? 6 : 5) {
            Image(systemName: systemImage)
                .font(style == .prominent
                      ? .system(size: 13, weight: .medium)
                      : .system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(
                    width: style == .prominent ? 20 : 14,
                    height: style == .prominent ? 20 : 14
                )

            if style == .prominent {
                title
                    // 分组名称（如「外观」）和行 Label（如「主题」）同字号，
                    // 仅靠字重表达分组边界，避免在紧凑的 macOS Form 中形成伪页面标题。
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            } else {
                title
            }
        }
    }
}
