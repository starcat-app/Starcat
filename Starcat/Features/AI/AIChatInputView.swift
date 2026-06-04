//
//  AIChatInputView.swift
//  Starcat
//
//  AI 助手窗口底部固定的输入条（HOM-150）。
//
//  设计要点：
//  - 单行 TextField + 圆角"发送"按钮，Return 直接发送（`.onSubmit`）；
//  - 发送过程禁用，避免并发触发 stream；
//  - 输入为空或正在发送时按钮 disabled，按钮的颜色 / 透明度由 SwiftUI 系统行为提供
//    视觉反馈，不需要手写额外样式；
//  - 不做多行输入：第一版定位是"轻量追问"，多行编辑器（TextEditor）会显著增加
//    布局调试成本，留到后续根据真实使用反馈再决定是否升级。
//

import SwiftUI

struct AIChatInputView: View {

    @Binding var text: String
    let isSending: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            TextField("问问关于这个仓库的问题…", text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.gray.opacity(0.25), lineWidth: 1)
                )
                .onSubmit(trySend)
                .disabled(isSending)

            sendButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var sendButton: some View {
        Button(action: trySend) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.purple.opacity(0.85), .blue.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)

                if isSending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        // 输入为空 / 发送中 → 禁用；SwiftUI 自动把按钮置灰，无需手写 opacity。
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        .help(isSending ? "正在发送…" : "发送（Return）")
    }

    private func trySend() {
        guard !isSending else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend()
    }
}

#Preview("AIChatInputView") {
    StatefulPreview()
        .frame(width: 720)
}

/// 预览容器：把 `@State` 包一层，避免 #Preview 里写 binding 样板。
private struct StatefulPreview: View {
    @State private var text: String = ""
    @State private var sending: Bool = false

    var body: some View {
        VStack {
            AIChatInputView(text: $text, isSending: sending) {
                sending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    sending = false
                    text = ""
                }
            }
        }
    }
}
