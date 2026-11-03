//
//  ProBenefitRow.swift
//  Starcat
//
//  Pro 权益说明的原生表单行；只负责展示与文档跳转，不参与权益判断。
//

import SwiftUI

/// 两行短文案配合行尾链接，避免多语言权益卡片产生高度差和大块留白。
struct ProBenefitRow: View {
    let titleKey: LocalizedStringKey
    let detailKey: LocalizedStringKey
    let destination: URL

    /// 整行保持链接语义；视觉截断不影响完整帮助提示与 VoiceOver 读取。
    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleKey)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(Text(titleKey))

                    Text(detailKey)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(Text(detailKey))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    Text("settings.pro.entitlements.details")
                    Image(systemName: "chevron.forward")
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            }
            // 两行短文案保留完整点击区域，同时收紧权益列表的纵向密度。
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}
