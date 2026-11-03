//
//  SettingsSectionHeader.swift
//  Starcat
//
//  macOS 设置页 Form 分组标题：在分组名左侧补 SF Symbol。
//
//  设计约束：
//  - 对齐设置页规范（docs/5-规范/UI-设置页规范.md §3）：分组名称与行 Label 同为
//    13pt，仅用 semibold 区分；图标为 13pt medium，布局框为 20pt。
//  - 只用于 `Section { } header: { }` 外挂标题，不替代行内 Label 或 DisclosureGroup 正文图标。
//  - 历史上的 `.compact` 双档样式已随设置页逐页收口完成删除（2026-09-13），
//    全部调用点均为本档口径；不要再引入第二套分组标题层级。
//

import SwiftUI

/// 设置页分组标题（图标 + 文案）。
struct SettingsSectionHeader<Icon: View>: View {

    private let title: Text
    private let icon: Icon

    /// 服务商等已有专属标识可直接复用，标题和图标列仍遵循统一设置页规格。
    init(verbatim title: String, @ViewBuilder icon: () -> Icon) {
        self.title = Text(verbatim: title)
        self.icon = icon()
    }

    var body: some View {
        HStack(spacing: 6) {
            icon
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)

            title
                // 分组名称（如「外观」）和行 Label（如「主题」）同字号，
                // 仅靠字重表达分组边界，避免在紧凑的 macOS Form 中形成伪页面标题。
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }
}

extension SettingsSectionHeader where Icon == BusinessIcon {
    init(
        _ titleKey: LocalizedStringKey,
        systemImage: String
    ) {
        self.title = Text(titleKey)
        self.icon = BusinessIcon(systemImage: systemImage, pointSize: 13, weight: .medium)
    }

    init(
        verbatim title: String,
        systemImage: String
    ) {
        self.title = Text(verbatim: title)
        self.icon = BusinessIcon(systemImage: systemImage, pointSize: 13, weight: .medium)
    }

    /// 补充矢量图仍占用原来的 20pt 图标列，不另起一套分组标题规格。
    init(_ titleKey: LocalizedStringKey, businessIcon: BusinessIcon.Symbol) {
        self.init(titleKey, iconSource: .business(businessIcon))
    }

    /// 动态服务分类也允许补充资源；字号按原有 SF / 矢量规则选择，外层占位不变。
    init(_ titleKey: LocalizedStringKey, iconSource: BusinessIcon.Source) {
        self.title = Text(titleKey)
        self.icon = BusinessIcon(source: iconSource, pointSize: iconSource.isAsset ? 16 : 13, weight: .medium)
    }
}
