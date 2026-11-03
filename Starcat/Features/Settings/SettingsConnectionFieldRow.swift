//
//  SettingsConnectionFieldRow.swift
//  Starcat
//
//  设置页连接字段的列布局。长标签换行，输入列填充可用空间，行尾操作始终保留位置。
//

import SwiftUI

/// 不持有草稿、不保存凭据；不同页面可以继续使用原来的 SwiftUI 或 AppKit 输入控件。
struct SettingsConnectionFieldRow<Field: View, Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let field: () -> Field
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .frame(width: 150, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            field()
                .frame(minWidth: 0, maxWidth: .infinity)
            trailing()
                .frame(width: SettingsIconMetrics.actionFrameSize)
        }
        .frame(maxWidth: .infinity)
    }
}
