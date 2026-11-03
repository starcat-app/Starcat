//
//  SettingsSliderRow.swift
//  Starcat
//
//  主设置页共用的滑条行。标题可换行，轨道与读数使用同一列宽；窄容器同步收缩轨道。
//

import SwiftUI

/// 紧凑的模型参数 popover 不使用此组件；这里保持与设置页原生 Slider 相同的控件样式。
struct SettingsSliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let readout: String
    var description: LocalizedStringKey? = nil
    @State private var availableWidth: CGFloat = 0

    private var trackWidth: CGFloat {
        // 只根据容器计算，不受各行标题长度影响；长翻译通过换行让出轨道空间。
        availableWidth > 0 ? min(200, max(80, (availableWidth - 96) / 2)) : 200
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Slider(value: $value, in: range, step: step) { Text(title) }
                .labelsHidden()
                .frame(width: trackWidth)
            Text(verbatim: readout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }
}
