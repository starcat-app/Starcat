//
//  SettingsPageIntroduction.swift
//  Starcat
//
//  设置页顶部说明卡片：统一页面标题、用途与连接约束的呈现。
//  由原生 grouped Form 提供卡片表面，不嵌套背景或持有任何配置状态。
//

import SwiftUI

/// 扩展与连接各页共用的说明入口，长语言按内容自然增高，不占用额外弹性高度。
struct SettingsPageIntroduction: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: LocalizedStringKey
    let context: LocalizedStringKey

    var body: some View {
        Section {
            HStack(spacing: 16) {
                // 页面身份卡片沿用现有通用、翻译页的强调图标，区别于普通分组标题。
                Image(systemName: systemImage)
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)

                Divider()
                    .frame(height: 48)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(Text(title))
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(context)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }
}
