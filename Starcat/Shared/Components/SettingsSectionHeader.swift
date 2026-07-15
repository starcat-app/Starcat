//
//  SettingsSectionHeader.swift
//  Starcat
//
//  macOS 设置页 Form 分组标题：在分组名左侧补 SF Symbol，尺寸对齐系统 section header。
//
//  设计约束：
//  - 图标 11pt + `.secondary`，不抢正文层级；文案走 Form 默认 header 样式。
//  - 只用于 `Section { } header: { }` 外挂标题，不替代行内 Label 或 DisclosureGroup 正文图标。
//

import SwiftUI

/// 设置页分组标题（图标 + 文案）。
struct SettingsSectionHeader: View {

    private let title: Text
    private let systemImage: String

    init(_ titleKey: LocalizedStringKey, systemImage: String) {
        self.title = Text(titleKey)
        self.systemImage = systemImage
    }

    init(verbatim title: String, systemImage: String) {
        self.title = Text(verbatim: title)
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)

            title
        }
    }
}
