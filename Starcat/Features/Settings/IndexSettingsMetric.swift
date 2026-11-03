//
//  IndexSettingsMetric.swift
//  Starcat
//
//  索引卡片的双列统计单元：数字在上、含义在下，计数单位与总量使用较弱层级。
//

import SwiftUI

/// 仓库数、失败数与文本分片数共享排版，不将它们合并成同一种覆盖率。
struct IndexSettingsMetric: View {
    let value: Int
    var total: Int?
    let unit: LocalizedStringKey
    let caption: LocalizedStringKey
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value, format: .number.locale(locale))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize()
                Group {
                    if let total {
                        Text(verbatim: "/ \(total.formatted(.number.locale(locale))) ") + Text(unit)
                    } else {
                        Text(unit)
                    }
                }
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
