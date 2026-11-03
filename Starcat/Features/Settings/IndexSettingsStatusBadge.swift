//
//  IndexSettingsStatusBadge.swift
//  Starcat
//
//  两类索引卡片共用的行内状态：圆点只作视觉提示，文字提供完整语义。
//

import SwiftUI

/// 状态保持在卡片右上方；颜色只表达运行结果，不改变卡片表面。
struct IndexSettingsStatusBadge: View {
    let status: SearchIndexStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(status.titleKey))
                .font(.caption)
                .foregroundStyle(tint)
        }
        .fixedSize()
    }

    private var tint: Color {
        switch status {
        case .completed, .upToDate, .textReady: RAGBackendTestStatus.successTint
        case .failed: RAGBackendTestStatus.dangerTint
        case .paused, .partialFailure, .needsUpdate: RAGBackendTestStatus.warningTint
        case .running, .building: .accentColor
        case .idle, .noModel: .secondary
        }
    }
}
