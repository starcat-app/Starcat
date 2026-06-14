//
//  AIChatInputView.swift
//  Starcat
//
//  AI 助手窗口底部固定的输入条（HOM-150 / Y9 增强）。
//
//  设计要点：
//  - 单行 TextField + 圆角"发送"按钮，Return 直接发送（`.onSubmit`）；
//  - 发送过程禁用，避免并发触发 stream；
//  - 输入为空或正在发送时按钮 disabled，按钮的颜色 / 透明度由 SwiftUI 系统行为提供
//    视觉反馈，不需要手写额外样式；
//  - 不做多行输入：第一版定位是"轻量追问"，多行编辑器（TextEditor）会显著增加
//    布局调试成本，留到后续根据真实使用反馈再决定是否升级。
//
//  Y9（2026-06-14，决议 C=c3+disabled）：TextField 与 send 之间新增 ellipsis.circle
//  Menu，两个 Toggle 直接绑 settings 的 `aiRepoContextEnabled` /
//  `aiExternalContextEnabled`。Settings 是 `@MainActor @Observable`，菜单与 Settings
//  页面双向同步零 race。AnySearch Toggle 在 `anySearchEnabled = false` 时 disabled
//  + 副标题引导去 Settings 启用——避免在快捷菜单诱导用户配置 API Key 这种带成本的
//  能力（详见 grill-me 决议 C 节点）。
//

import SwiftUI

struct AIChatInputView: View {

    @Binding var text: String
    let isSending: Bool
    let onSend: () -> Void

    /// Y9：上下文快捷菜单需要直接读写 settings 的开关字段。
    /// 用 `@Environment(AppSettings.self)` + body 内 `@Bindable` 提取 binding，是
    /// `@Observable` 模式下 SwiftUI 标准做法（Swift 5.9+）。
    @Environment(AppSettings.self) private var settings

    var body: some View {
        // 把 @Observable settings 转成可 binding 的形式，让 Menu 内 Toggle 能直接
        // `$settings.aiRepoContextEnabled` 写回 settings.didSet 持久化。
        @Bindable var settings = settings

        HStack(alignment: .center, spacing: 8) {
            TextField("ai.assistant.input.placeholder", text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.gray.opacity(0.25), lineWidth: 1)
                )
                .onSubmit(trySend)
                .disabled(isSending)

            contextMenu(settings: $settings)

            sendButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Y9（2026-06-14）：上下文配置快捷菜单（决议 C=c3+disabled）。
    ///
    /// 两个 Toggle：
    ///   1. **代码上下文** → `aiRepoContextEnabled`（默认 ON）
    ///      影响 RepoContextPacker 是否被调用 + Code XML 是否进 AI prompt。
    ///   2. **外部材料 (AnySearch)** → `aiExternalContextEnabled`（默认 OFF）
    ///      影响 AnySearch markdown 是否注入摘要 / 对话 prompt。
    ///      当 `anySearchEnabled = false` 时整项 disabled，菜单内追加 caption 引导
    ///      用户去 Settings 启用 AnySearch（带 API Key 配置成本，不在此快捷翻转）。
    ///
    /// 私仓开关 `aiExternalContextAllowPrivateRepos` 不进本菜单——它是边界条件，
    /// 不是日常切换的诉求。
    ///
    /// Settings 字段同时被 Settings 页面用同一份绑定方式编辑，本菜单与 Settings 页面
    /// 双向同步无需额外通信（@Observable didSet 自然驱动 UI 刷新）。
    @ViewBuilder
    private func contextMenu(settings: Bindable<AppSettings>) -> some View {
        Menu {
            Toggle(isOn: settings.aiRepoContextEnabled) {
                Label(
                    "ai.assistant.input.contextMenu.codeContext",
                    systemImage: "doc.text.magnifyingglass"
                )
            }

            Toggle(isOn: settings.aiExternalContextEnabled) {
                Label(
                    "ai.assistant.input.contextMenu.anySearch",
                    systemImage: "globe"
                )
            }
            .disabled(!settings.wrappedValue.anySearchEnabled)

            // AnySearch 总开关关闭时追加 caption 引导用户：菜单里的 Text 在 macOS
            // SwiftUI 上以 secondary 字色 + 较小字号呈现，刚好作为"为什么禁用"的提示。
            if !settings.wrappedValue.anySearchEnabled {
                Divider()
                Text("ai.assistant.input.contextMenu.anySearch.disabledHint")
            }
        } label: {
            // 视觉对齐 sendButton：右侧发送按钮是 32×32 实心圆 + 14pt bold 箭头，
            // 这里 ellipsis.circle 走描边圆 + secondary 灰，font 22pt 让圆形 symbol
            // 的实际直径接近 ~26pt，frame 与 sendButton 同步成 32×32 让两个按钮
            // 在 HStack 中等高对齐。圆体略小于发送按钮，保留"次级操作 < 主操作"
            // 的视觉层级（不抢戏，但不再"小一圈"）。
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 32)
        .focusEffectDisabled()
        .help("ai.assistant.input.contextMenu.help")
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
        .help(isSending ? "ai.assistant.input.sending.help" : "ai.assistant.input.send.help")
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
        .environment(AppSettings.shared)
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
