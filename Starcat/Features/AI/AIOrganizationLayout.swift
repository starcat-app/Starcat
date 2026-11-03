//
//  AIOrganizationLayout.swift
//  Starcat
//
//  仓库分组、标签整理及词表确认共用的紧凑画布和概览样式。
//  AppKit 与 SwiftUI 必须读取同一份尺寸，避免缩小窗口后内容仍按旧画布布局。
//

import SwiftUI

/// 固定工作区的尺寸所有权仍在 AppKit；内容只在已知 bounds 内排版，不反向协商窗口大小。
enum AIOrganizationLayout {
    static let windowSize = CGSize(width: 840, height: 560)
    static let headerHeight: CGFloat = 56
    static let footerHeight: CGFloat = 48
    static let contentHeight = windowSize.height - headerHeight - footerHeight - 2
    static let padding: CGFloat = 12
    static let gap: CGFloat = 10
    static let innerWidth = windowSize.width - padding * 2
    static let summaryHeight: CGFloat = 56
    static let summaryCardWidth = (innerWidth - 8 * 3) / 4
    static let panelHeight = contentHeight - padding * 2 - summaryHeight - gap
    static let leadingPanelWidth: CGFloat = 536
    static let sessionPanelWidth = innerWidth - leadingPanelWidth - gap
}

/// 设计图中的功能身份色块；图形使用标准 token，色块不随窗口放大成为主视觉。
struct AIOrganizationIconBadge: View {
    let symbol: String
    let tint: Color
    var typography: StarcatTypography = .iconMedium

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        Image(systemName: symbol)
            .font(interfaceScale.font(typography))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}

/// 四列概览卡保持同高；比例来自现有快照，长翻译截断并保留完整提示。
struct AIOrganizationSummaryCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    var proportion: String? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 8) {
            AIOrganizationIconBadge(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                Text(verbatim: value)
                    .font(interfaceScale.font(.panelTitle).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let proportion {
                Text(verbatim: proportion)
                    .font(interfaceScale.font(.captionStrong).monospacedDigit())
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.12), in: Capsule())
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(width: AIOrganizationLayout.summaryCardWidth, height: AIOrganizationLayout.summaryHeight)
        .background(
            tint.opacity(colorScheme == .dark ? 0.16 : 0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.36 : 0.24))
        }
        .help(Text(verbatim: "\(title): \(value)"))
    }
}
