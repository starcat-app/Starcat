//
//  CountedSegmentLabel.swift
//  Starcat
//
//  AI 整理 Tab 的稳定计数标签：用完整批次总数占位，当前计数不参与宽度测量。
//

import SwiftUI

/// 隐藏的总数保留数字及分组符所需空间，真实计数只在这个槽位内右对齐更新。
/// 调用方保证 count 不超过完整批次 totalCount；不能使用搜索后或当前 Tab 的数量作上限。
struct CountedSegmentLabel: View {
    let title: LocalizedStringKey
    let count: Int
    let totalCount: Int
    var symbol: String? = nil
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: symbol == nil ? 6 : 4) {
            if let symbol {
                Image(systemName: symbol)
            } else {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(verbatim: totalCount.formatted(.number.locale(locale)))
                .monospacedDigit()
                .fixedSize()
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(verbatim: count.formatted(.number.locale(locale)))
                        .monospacedDigit()
                        .fixedSize()
                        // 数字更新不能继承外层批量刷新动画，引起计数槽位内的额外跳动。
                        .transaction { $0.animation = nil }
                }
                .layoutPriority(1)
        }
        // 占位总数只用于布局，不能被读屏误当成当前状态数量。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: count.formatted(.number.locale(locale))))
    }
}
