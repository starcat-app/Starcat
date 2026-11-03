//
//  LocalToolIntegerField.swift
//  Starcat
//
//  本地工具的有界数字输入。编辑草稿与已持久化的合法值分离，避免输入 100 时先被钳成 40。
//

import SwiftUI

/// 合法数字立即写回原设置；空值或越界草稿在提交、失焦时恢复或钳制。
struct LocalToolIntegerField: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    let range: ClosedRange<Int>

    @State private var draft = ""
    @FocusState private var isFocused: Bool
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.body.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: interfaceScale.scaled(100))
            .focused($isFocused)
            .accessibilityLabel(Text(title))
            .onAppear { draft = String(value) }
            .onChange(of: draft) { _, newValue in
                let filtered = String(newValue.filter(\.isNumber).prefix(6))
                if filtered != newValue { draft = filtered }
                if let number = Int(filtered), range.contains(number) { value = number }
            }
            .onChange(of: value) { _, newValue in
                if !isFocused { draft = String(newValue) }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onSubmit(commit)
    }

    /// 编辑过程允许暂时低于下限，结束编辑时才应用边界，保留正常逐位输入能力。
    private func commit() {
        value = min(max(Int(draft) ?? value, range.lowerBound), range.upperBound)
        draft = String(value)
    }
}
