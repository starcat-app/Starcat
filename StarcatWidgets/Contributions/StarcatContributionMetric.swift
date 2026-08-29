//
//  StarcatContributionMetric.swift
//  StarcatWidgets
//
//  贡献 Widget 共用的数字指标视图。
//

import SwiftUI

/// 用稳定的两级字号呈现贡献指标，长数字允许缩放但不改变卡片布局。
struct StarcatContributionMetric: View {
    let value: Int
    let titleKey: LocalizedStringKey
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(prominent ? .title.bold() : .title3.bold())
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.65)
                .lineLimit(1)
            Text(titleKey)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
