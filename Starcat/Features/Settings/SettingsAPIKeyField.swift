//
//  SettingsAPIKeyField.swift
//  Starcat
//
//  设置页的密码输入与显示/隐藏操作。切换安全控件时恢复输入焦点，草稿始终由调用方持有。
//

import SwiftUI

/// 共享标签列和行尾按钮，不参与凭据测试、清除或保存。
struct SettingsAPIKeyField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    var prompt: Text? = nil
    @State private var isRevealed = false
    @FocusState private var isFocused: Bool

    var body: some View {
        SettingsConnectionFieldRow(title: title) {
            Group {
                if isRevealed {
                    TextField("", text: $text, prompt: prompt)
                } else {
                    SecureField("", text: $text, prompt: prompt)
                }
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .accessibilityLabel(Text(title))
        } trailing: {
            SettingsActionIconButton(
                title: isRevealed ? "settings.services.apiKey.hide" : "settings.services.apiKey.reveal",
                systemImage: isRevealed ? "eye.slash" : "eye"
            ) {
                isRevealed.toggle()
                isFocused = true
            }
        }
    }
}
