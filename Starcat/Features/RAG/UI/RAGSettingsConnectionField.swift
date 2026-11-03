//
//  RAGSettingsConnectionField.swift
//  Starcat
//
//  重排和索引存储共用的连接字段。标签使用统一宽度，输入框填充剩余空间，
//  不依赖外层 Grid 的跨列测量，不显示原生控件的第二份标签。
//

import SwiftUI

/// 只负责字段排版，绑定、密钥保存和连接测试仍由各自设置页管理。
struct RAGSettingsConnectionField: View {
    let titleKey: LocalizedStringKey
    @Binding var text: String
    var isSecure = false

    var body: some View {
        if isSecure {
            SettingsAPIKeyField(title: titleKey, text: $text)
        } else {
            SettingsConnectionFieldRow(title: titleKey) {
                TextField("", text: $text)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                    .accessibilityLabel(titleKey)
            } trailing: {
                // 与同组 API Key 的眼睛按钮共用尾槽，确保地址和模型输入列对齐。
                Color.clear.frame(height: SettingsIconMetrics.actionFrameSize)
                    .accessibilityHidden(true)
            }
        }
    }
}
