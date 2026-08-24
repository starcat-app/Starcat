//
//  GrowthShareCopyButton.swift
//  Starcat
//
//  洞察与健康统计共用的轻量复制分享入口。
//

import SwiftUI

/// 复制分享文案的 icon-only 按钮。
///
/// 视觉保持工具栏级别，不引入营销按钮；成功态复用项目统一的绿色反馈语义。
struct GrowthShareCopyButton: View {
    let providesContent: () -> String

    var body: some View {
        CopyFeedbackButton(
            providesContent: providesContent,
            tooltip: "growth.share.copy"
        ) { didCopy in
            Image(systemName: didCopy ? "checkmark.circle.fill" : "square.and.arrow.up")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(didCopy ? Color.green : Color.secondary)
                .frame(width: 24, height: 24)
        }
        .accessibilityLabel(Text("growth.share.copy"))
    }
}
